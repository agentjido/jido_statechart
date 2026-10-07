defmodule Jido.Statechart.ExecutableContent do
  @moduledoc "Executes normalized SCXML content in authored order without dispatching effects."

  alias Jido.Statechart.{ActionRunner, DataModel, Diagnostic, Registry, Session}
  alias Jido.Statechart.Model.Executable
  alias Jido.Statechart.Runtime.Intent

  @fatal_codes [
    :action_output_too_large,
    :data_limit_exceeded,
    :executable_work_limit_exceeded,
    :expression_limit_exceeded,
    :external_intent_limit_exceeded,
    :internal_queue_limit_exceeded,
    :invalid_executable_content,
    :invalid_execution_state,
    :iteration_limit_exceeded,
    :trace_limit_exceeded
  ]

  @doc "Runs one executable block and converts authored failures to error.execution."
  @spec run([Executable.t()], map(), keyword()) ::
          {:ok, map()} | {:error, Diagnostic.t()}
  def run(commands, state, options)
      when is_list(commands) and is_map(state) and is_list(options) do
    if Keyword.keyword?(options) do
      with {:ok, model} <- data_model(options),
           {:ok, registry} <- registry(options),
           {:ok, limits} <- DataModel.limits(options) do
        case validate_commands(commands, model) do
          :ok ->
            with {:ok, state} <- prepare_state(state, model, limits) do
              context = %{model: model, registry: registry, limits: limits, options: options}

              case run_block(commands, state, context) do
                {:ok, next} ->
                  {:ok, next}

                {:execution_error, diagnostic, next} ->
                  add_execution_error(next, diagnostic, limits)

                {:error, diagnostic} ->
                  {:error, diagnostic}
              end
            end

          {:error, %Diagnostic{code: :null_action_forbidden} = diagnostic} ->
            with {:ok, state} <- prepare_state(state, model, limits) do
              add_execution_error(state, diagnostic, limits)
            end

          {:error, _diagnostic} = error ->
            error
        end
      end
    else
      {:error, Diagnostic.new(:invalid_executable_content, "Executable options are invalid")}
    end
  end

  def run(_commands, _state, _options) do
    {:error,
     Diagnostic.new(:invalid_executable_content, "Executable block is invalid",
       path: [:executable]
     )}
  end

  defp run_block([], state, _context), do: {:ok, state}

  defp run_block([%Executable{} = command | rest], state, context) do
    with {:ok, charged} <- charge_work(state, context.limits) do
      case execute(command, charged, context) do
        {:ok, next} ->
          with :ok <- ensure_model_invariant(next, context.model) do
            run_block(rest, next, context)
          end

        {:execution_error, _diagnostic, _next} = error ->
          error

        {:error, _diagnostic} = error ->
          error
      end
    end
  end

  defp run_block(_commands, _state, _context) do
    {:error,
     Diagnostic.new(:invalid_executable_content, "Executable command is not normalized",
       path: [:executable]
     )}
  end

  defp execute(%Executable{kind: :raise, data: data}, state, context) do
    with {:ok, event} <- required_string(Map.get(data, "event"), :event) do
      append_internal_event(state, event, nil, context.limits)
    else
      {:error, diagnostic} -> classify(diagnostic, state)
    end
  end

  defp execute(%Executable{kind: :if} = command, state, context) do
    with {:ok, branch} <- select_branch(command.data["branches"], state, context) do
      case branch do
        nil ->
          {:ok, state}

        %{"start" => start, "count" => count}
        when is_integer(start) and start >= 0 and is_integer(count) and count >= 0 ->
          command.children |> Enum.slice(start, count) |> run_block(state, context)

        _invalid ->
          {:error,
           Diagnostic.new(:invalid_executable_content, "Conditional branch range is invalid",
             path: [:executable, :if]
           )}
      end
    else
      {:error, diagnostic} -> classify(diagnostic, state)
    end
  end

  defp execute(%Executable{kind: :foreach} = command, state, context) do
    array = command.data["array"]
    item = command.data["item"]
    index = command.data["index"]

    with :ok <- binding_name(item, :item),
         :ok <- optional_binding_name(index, :index),
         {:ok, snapshot} <-
           context.model.iterate(array, environment(state), model_options(context)) do
      original_bindings = state.bindings
      run_iterations(snapshot, command.children, state, original_bindings, item, index, context)
    else
      {:error, diagnostic} -> classify(diagnostic, state)
    end
  end

  defp execute(%Executable{kind: :assign, data: data}, state, context) do
    with {:ok, location} <- required_string(Map.get(data, "location"), :location),
         {:ok, value} <- assignment_value(data, state, context),
         {:ok, next_data} <-
           context.model.assign(location, value, state.data, model_options(context)) do
      {:ok, %{state | data: next_data}}
    else
      {:error, diagnostic} -> classify(diagnostic, state)
    end
  end

  defp execute(%Executable{kind: :log, data: data}, state, context) do
    with {:ok, value} <- optional_expression(data["expr"], state, context),
         entry = %{"label" => data["label"], "value" => value},
         logs = state.logs ++ [entry],
         :ok <- DataModel.validate_value(logs, [limits: context.limits], [:logs]),
         :ok <- log_limit(state.logs, context.limits) do
      {:ok, %{state | logs: logs}}
    else
      {:error, diagnostic} -> classify(diagnostic, state)
    end
  end

  defp execute(%Executable{kind: :send, data: data}, state, context) do
    with {:ok, event} <-
           attribute(data, "event", "eventexpr", state, context, true),
         {:ok, target} <- attribute(data, "target", "targetexpr", state, context, false),
         {:ok, type} <- attribute(data, "type", "typeexpr", state, context, false),
         {:ok, delay} <- attribute(data, "delay", "delayexpr", state, context, false),
         {:ok, payload} <- construct_payload(data, state, context) do
      with {:ok, send_id, allocated} <- allocate_send_id(data, state),
           {:ok, assigned} <- assign_send_id(data, send_id, allocated, context) do
        if target == "#_internal" do
          with :ok <- Intent.validate_send_type(type),
               {:ok, event} <- required_string(event, :event) do
            append_internal_event(assigned, event, payload, context.limits, send_id)
          else
            {:error, diagnostic} -> classify(diagnostic, assigned)
          end
        else
          intent = %{
            "kind" => "send",
            "event" => event,
            "target" => target,
            "send_id" => send_id,
            "delay" => delay,
            "type" => type,
            "data" => payload
          }

          intent =
            case get_in(state.system, ["_event", "turn_id"]) do
              turn_id when is_binary(turn_id) and turn_id != "" ->
                Map.put(intent, "turn_id", turn_id)

              _other ->
                intent
            end

          intent =
            if is_nil(data["targetexpr"]),
              do: intent,
              else: Map.put(intent, "target_selected", true)

          with {:ok, _resolved} <- Intent.validate_send(intent, context.registry),
               {:ok, next} <- append_intent(assigned, intent, context.limits) do
            {:ok, next}
          else
            {:error, diagnostic} -> classify(diagnostic, assigned)
          end
        end
      else
        {:error, diagnostic, next} -> classify(diagnostic, next)
        {:error, diagnostic} -> classify(diagnostic, state)
      end
    else
      {:error, diagnostic} -> classify(diagnostic, state)
    end
  end

  defp execute(%Executable{kind: :cancel, data: data}, state, context) do
    with {:ok, send_id} <- attribute(data, "sendid", "sendidexpr", state, context, true) do
      append_intent(state, %{"kind" => "cancel", "send_id" => send_id}, context.limits)
    else
      {:error, diagnostic} -> classify(diagnostic, state)
    end
  end

  defp execute(%Executable{kind: :action, data: data}, state, context) do
    with {:ok, identifier} <- required_string(Map.get(data, "id"), :id),
         {:ok, params} <- action_params(Map.get(data, "params"), state, context),
         {:ok, output} <-
           ActionRunner.run(
             identifier,
             params,
             action_environment(state),
             action_options(context)
           ),
         true <- is_map(output) and not is_struct(output),
         :ok <- DataModel.validate_value(output, [limits: context.limits], [:action, :output]) do
      {:ok, %{state | data: output}}
    else
      false ->
        classify(
          Diagnostic.new(:invalid_action_data, "Statechart Action output must be a data map",
            path: [:action, :output]
          ),
          state
        )

      {:error, diagnostic} ->
        classify(diagnostic, state)
    end
  end

  defp execute(%Executable{kind: kind}, _state, _context) do
    {:error,
     Diagnostic.new(:invalid_executable_content, "Executable kind is not implemented",
       path: [:executable, kind]
     )}
  end

  defp select_branch(branches, state, context) when is_list(branches) do
    Enum.reduce_while(branches, {:ok, nil}, fn branch, _acc ->
      case branch do
        %{"kind" => "else"} ->
          {:halt, {:ok, branch}}

        %{"condition" => condition} when is_binary(condition) ->
          case context.model.condition(condition, environment(state), model_options(context)) do
            {:ok, true} -> {:halt, {:ok, branch}}
            {:ok, false} -> {:cont, {:ok, nil}}
            {:error, _} = error -> {:halt, error}
          end

        _invalid ->
          {:halt,
           {:error,
            Diagnostic.new(:invalid_executable_content, "Conditional branch is invalid",
              path: [:executable, :if]
            )}}
      end
    end)
  end

  defp select_branch(_branches, _state, _context) do
    {:error,
     Diagnostic.new(:invalid_executable_content, "Conditional branches must be a list",
       path: [:executable, :if]
     )}
  end

  defp run_iterations([], _commands, state, original, _item, _index, _context),
    do: {:ok, %{state | bindings: original}}

  defp run_iterations([{value, position} | rest], commands, state, original, item, index, context) do
    with {:ok, charged} <- charge_work(state, context.limits) do
      bindings = original |> Map.put(item, value) |> put_binding(index, position)

      case run_block(commands, %{charged | bindings: bindings}, context) do
        {:ok, next} ->
          run_iterations(
            rest,
            commands,
            %{next | bindings: original},
            original,
            item,
            index,
            context
          )

        {:execution_error, diagnostic, next} ->
          {:execution_error, diagnostic, %{next | bindings: original}}

        {:error, _diagnostic} = error ->
          error
      end
    end
  end

  defp put_binding(bindings, nil, _position), do: bindings
  defp put_binding(bindings, index, position), do: Map.put(bindings, index, position)

  defp assignment_value(data, state, context) do
    cond do
      is_binary(data["expr"]) ->
        context.model.value(data["expr"], environment(state), model_options(context))

      is_map(data["content"]) ->
        context.model.content(data["content"], environment(state), model_options(context))

      true ->
        {:error,
         Diagnostic.new(:invalid_assignment, "Assignment requires expression or content",
           path: [:assignment]
         )}
    end
  end

  defp optional_expression(nil, _state, _context), do: {:ok, nil}

  defp optional_expression(expression, state, context) when is_binary(expression),
    do: context.model.value(expression, environment(state), model_options(context))

  defp optional_expression(_expression, _state, _context) do
    {:error, Diagnostic.new(:invalid_expression_id, "Expression identifier must be a string")}
  end

  defp attribute(data, static_key, expression_key, state, context, required?) do
    static = Map.get(data, static_key)
    expression = Map.get(data, expression_key)

    result =
      cond do
        is_binary(expression) ->
          context.model.value(expression, environment(state), model_options(context))

        is_nil(expression) ->
          {:ok, static}

        true ->
          {:error,
           Diagnostic.new(:invalid_expression_id, "Expression identifier must be a string")}
      end

    with {:ok, value} <- result do
      if required?,
        do: required_string(value, static_key),
        else: optional_string(value, static_key)
    end
  end

  defp construct_payload(data, state, context) do
    with {:ok, namelist} <- namelist_params(Map.get(data, "namelist")) do
      container = %{
        "params" => namelist ++ Map.get(data, "params", []),
        "content" => Map.get(data, "content")
      }

      context.model.construct(container, environment(state), model_options(context))
    end
  end

  defp namelist_params(nil), do: {:ok, []}

  defp namelist_params(namelist) when is_binary(namelist) do
    if String.valid?(namelist) do
      {:ok,
       namelist
       |> String.split(~r/\s+/u, trim: true)
       |> Enum.map(&%{"name" => &1, "location" => &1})}
    else
      invalid_string(:namelist)
    end
  end

  defp namelist_params(_namelist), do: invalid_string(:namelist)

  defp allocate_send_id(data, state) do
    case optional_string(Map.get(data, "id"), :id) do
      {:ok, nil} ->
        generate_send_id(data, state)

      {:ok, send_id} ->
        {:ok, send_id, state}

      {:error, _} = error ->
        error
    end
  end

  # SCXML 1.0, section 6.2.3, requires generation only for idlocation.
  # If both id and idlocation are absent, the transport sendid stays empty.
  defp generate_send_id(%{"idlocation" => idlocation}, state) when not is_nil(idlocation) do
    session_id = Map.get(state.system, "_sessionid")

    case Session.generated_send_id(
           session_id,
           state.session_incarnation,
           state.generated_id_counter
         ) do
      {:ok, send_id} ->
        {:ok, send_id, %{state | generated_id_counter: state.generated_id_counter + 1}}

      {:error, diagnostic} ->
        {:error,
         %{diagnostic | code: :invalid_execution_state, message: "Generated ID state is invalid"}}
    end
  end

  defp generate_send_id(_data, state), do: {:ok, nil, state}

  defp assign_send_id(data, send_id, state, context) do
    case Map.get(data, "idlocation") do
      nil ->
        {:ok, state}

      location ->
        case context.model.assign(location, send_id, state.data, model_options(context)) do
          {:ok, data} -> {:ok, %{state | data: data}}
          {:error, diagnostic} -> {:error, diagnostic, state}
        end
    end
  end

  defp action_params(nil, _state, _context), do: {:ok, %{}}

  defp action_params(expression, state, context) when is_binary(expression) do
    case context.model.value(expression, environment(state), model_options(context)) do
      {:ok, params} when is_map(params) and not is_struct(params) ->
        {:ok, params}

      {:ok, _other} ->
        {:error,
         Diagnostic.new(:invalid_action_params, "Action parameters must be a map",
           path: [:action, :params]
         )}

      {:error, _} = error ->
        error
    end
  end

  defp action_params(_expression, _state, _context) do
    {:error,
     Diagnostic.new(:invalid_action_params, "Action parameter expression must be a string")}
  end

  defp append_internal_event(state, name, data, limits, send_id \\ nil) do
    event = %{
      "name" => name,
      "class" => "internal",
      "data" => data,
      "message_id" => nil,
      "send_id" => send_id,
      "origin" => nil,
      "origin_type" => nil,
      "invoke_id" => nil,
      "turn_id" => nil,
      "session_id" => Map.get(state.system, "_sessionid")
    }

    internal_queue = state.internal_queue ++ [event]

    with :ok <-
           DataModel.validate_value(internal_queue, [limits: limits], [:internal_queue]),
         :ok <- internal_queue_limit(state.internal_queue, limits) do
      {:ok, %{state | internal_queue: internal_queue}}
    end
  end

  defp append_intent(state, intent, limits) do
    intents = state.intents ++ [intent]

    with :ok <- DataModel.validate_value(intents, [limits: limits], [:intents]),
         :ok <- intent_limit(state.intents, limits) do
      {:ok, %{state | intents: intents}}
    end
  end

  defp internal_queue_limit(queue, limits) do
    if length(queue) < limits.internal_queue_events do
      :ok
    else
      {:error,
       Diagnostic.new(:internal_queue_limit_exceeded, "Internal event queue limit was reached",
         path: [:internal_queue]
       )}
    end
  end

  defp intent_limit(intents, limits) do
    if length(intents) < limits.external_intents do
      :ok
    else
      {:error,
       Diagnostic.new(:external_intent_limit_exceeded, "External intent limit was reached",
         path: [:intents]
       )}
    end
  end

  defp add_execution_error(state, diagnostic, limits) do
    data = %{"code" => Atom.to_string(diagnostic.code), "message" => diagnostic.message}

    case append_internal_event(state, "error.execution", data, limits) do
      {:ok, next} ->
        [last | prefix] = Enum.reverse(next.internal_queue)
        event = Map.put(last, "class", "platform")
        {:ok, %{next | internal_queue: Enum.reverse([event | prefix])}}

      {:error, _} = error ->
        error
    end
  end

  defp classify(%Diagnostic{code: code} = diagnostic, _state) when code in @fatal_codes,
    do: {:error, diagnostic}

  defp classify(%Diagnostic{} = diagnostic, state),
    do: {:execution_error, diagnostic, state}

  defp validate_commands(commands, model) when is_list(commands) do
    commands
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {command, index}, :ok ->
      case validate_command(command, model) do
        :ok -> {:cont, :ok}
        {:error, diagnostic} -> {:halt, {:error, Diagnostic.prefix(diagnostic, [index])}}
      end
    end)
  end

  defp validate_commands(_commands, _model), do: invalid_command(:block)

  defp validate_command(
         %Executable{kind: kind, ordinal: ordinal, data: data, children: children},
         model
       )
       when is_atom(kind) and is_integer(ordinal) and ordinal >= 0 and is_map(data) and
              not is_struct(data) and is_list(children) do
    validate_command_kind(kind, data, children, model)
  end

  defp validate_command(_command, _model), do: invalid_command(:command)

  defp validate_command_kind(:raise, data, [], _model) do
    valid_or_error(valid_string?(data["event"]), :raise)
  end

  defp validate_command_kind(:if, data, children, model) do
    branches = data["branches"]

    valid =
      is_list(branches) and branches != [] and
        valid_branches?(branches, length(children))

    with :ok <- valid_or_error(valid, :if),
         :ok <- validate_commands(children, model) do
      :ok
    end
  end

  defp validate_command_kind(:foreach, data, children, model) do
    valid =
      valid_string?(data["array"]) and valid_binding?(data["item"]) and
        optional_valid_binding?(data["index"])

    with :ok <- valid_or_error(valid, :foreach),
         :ok <- validate_commands(children, model) do
      :ok
    end
  end

  defp validate_command_kind(:assign, data, [], _model) do
    sources = Enum.count([data["expr"], data["content"]], &(not is_nil(&1)))

    valid =
      valid_location?(data["location"]) and sources == 1 and
        optional_valid_string?(data["expr"]) and optional_valid_content?(data["content"])

    valid_or_error(valid, :assign)
  end

  defp validate_command_kind(:log, data, [], _model) do
    valid_or_error(
      optional_valid_string?(data["label"]) and optional_valid_string?(data["expr"]),
      :log
    )
  end

  defp validate_command_kind(:send, data, [], _model) do
    params = Map.get(data, "params", [])
    namelist = data["namelist"]
    content = data["content"]
    event_source? = present?(data, "event") or present?(data, "eventexpr")
    content_source? = not is_nil(content)

    valid =
      valid_attribute_pair?(data, "event", "eventexpr") and
        valid_attribute_pair?(data, "target", "targetexpr") and
        valid_attribute_pair?(data, "type", "typeexpr") and
        valid_attribute_pair?(data, "delay", "delayexpr") and
        not (present?(data, "id") and present?(data, "idlocation")) and
        valid_authored_send_id?(data["id"]) and optional_valid_location?(data["idlocation"]) and
        optional_valid_string?(namelist) and valid_params?(params) and
        optional_valid_content?(content) and event_source? and
        not (content_source? and (params != [] or present?(data, "namelist")))

    valid_or_error(valid, :send)
  end

  defp validate_command_kind(:cancel, data, [], _model) do
    valid =
      valid_attribute_pair?(data, "sendid", "sendidexpr") and
        (present?(data, "sendid") or present?(data, "sendidexpr"))

    valid_or_error(valid, :cancel)
  end

  defp validate_command_kind(:action, _data, [], Jido.Statechart.DataModel.Null) do
    {:error,
     Diagnostic.new(:null_action_forbidden, "The null data model cannot execute Actions",
       path: [:action]
     )}
  end

  defp validate_command_kind(:action, data, [], _model) do
    valid_or_error(
      valid_string?(data["id"]) and optional_valid_string?(data["params"]),
      :action
    )
  end

  defp validate_command_kind(kind, _data, _children, _model), do: invalid_command(kind)

  defp valid_branches?(branches, child_count) do
    last_index = length(branches) - 1

    result =
      branches
      |> Enum.with_index()
      |> Enum.reduce_while(0, fn
        {%{"kind" => kind, "condition" => condition, "start" => start, "count" => count}, index},
        expected_start
        when kind in ["if", "elseif"] ->
          if index == 0 == (kind == "if") and valid_string?(condition) and
               start == expected_start and valid_range?(start, count, child_count) do
            {:cont, start + count}
          else
            {:halt, :invalid}
          end

        {%{"kind" => "else", "condition" => nil, "start" => start, "count" => count}, index},
        expected_start ->
          if index > 0 and index == last_index and start == expected_start and
               valid_range?(start, count, child_count) do
            {:cont, start + count}
          else
            {:halt, :invalid}
          end

        _branch, _expected_start ->
          {:halt, :invalid}
      end)

    result == child_count
  end

  defp valid_range?(start, count, child_count) do
    is_integer(start) and start >= 0 and is_integer(count) and count >= 0 and
      start + count <= child_count
  end

  defp valid_attribute_pair?(data, static, expression) do
    not (present?(data, static) and present?(data, expression)) and
      optional_valid_string?(data[static]) and optional_valid_string?(data[expression])
  end

  defp valid_params?(params) when is_list(params) do
    Enum.all?(params, fn
      %{} = param when not is_struct(param) ->
        sources = Enum.count([param["expr"], param["location"]], &(not is_nil(&1)))

        valid_string?(param["name"]) and sources == 1 and
          optional_valid_string?(param["expr"]) and optional_valid_location?(param["location"])

      _param ->
        false
    end)
  end

  defp valid_params?(_params), do: false

  defp optional_valid_content?(nil), do: true

  defp optional_valid_content?(content) when is_map(content) and not is_struct(content) do
    optional_valid_string?(content["expression"]) and is_list(Map.get(content, "items", []))
  end

  defp optional_valid_content?(_content), do: false

  defp valid_binding?(value) do
    valid_string?(value) and not DataModel.protected_location?(value) and
      match?([_single], String.split(value, "."))
  end

  defp optional_valid_binding?(nil), do: true
  defp optional_valid_binding?(value), do: valid_binding?(value)

  defp valid_location?(value) do
    case Jido.Statechart.Location.parse(value) do
      {:ok, _path} -> true
      {:error, _diagnostic} -> false
    end
  end

  defp optional_valid_location?(nil), do: true
  defp optional_valid_location?(value), do: valid_location?(value)

  defp valid_authored_send_id?(nil), do: true

  defp valid_authored_send_id?(value) do
    valid_string?(value) and not String.starts_with?(value, Session.generated_id_prefix())
  end

  defp valid_string?(value), do: is_binary(value) and value != "" and String.valid?(value)
  defp optional_valid_string?(nil), do: true
  defp optional_valid_string?(value), do: valid_string?(value)

  defp present?(data, key), do: Map.has_key?(data, key) and not is_nil(data[key])

  defp valid_or_error(true, _kind), do: :ok
  defp valid_or_error(false, kind), do: invalid_command(kind)

  defp invalid_command(kind) do
    {:error,
     Diagnostic.new(:invalid_executable_content, "Executable command is not normalized",
       path: [:executable, kind]
     )}
  end

  defp binding_name(value, field) do
    with {:ok, name} <- required_string(value, field),
         false <- DataModel.protected_location?(name),
         [^name] <- String.split(name, ".") do
      :ok
    else
      _other ->
        {:error,
         Diagnostic.new(:invalid_loop_binding, "Loop binding must be one unprotected string key",
           path: [:foreach, field]
         )}
    end
  end

  defp optional_binding_name(nil, _field), do: :ok
  defp optional_binding_name(value, field), do: binding_name(value, field)

  defp required_string(value, _field) when is_binary(value) and value != "" do
    if String.valid?(value), do: {:ok, value}, else: invalid_string()
  end

  defp required_string(_value, field), do: invalid_string(field)

  defp optional_string(nil, _field), do: {:ok, nil}
  defp optional_string(value, field), do: required_string(value, field)

  defp invalid_string(field \\ :value) do
    {:error,
     Diagnostic.new(:invalid_executable_value, "Executable value must be a UTF-8 string",
       path: [:executable, field]
     )}
  end

  defp log_limit(logs, limits) do
    if length(logs) < limits.trace_entries do
      :ok
    else
      {:error,
       Diagnostic.new(:trace_limit_exceeded, "Log and trace entry limit was reached",
         path: [:logs]
       )}
    end
  end

  defp data_model(options) do
    options |> Keyword.get(:data_model) |> DataModel.resolve()
  end

  defp registry(options) do
    case Keyword.get(options, :registry) do
      %Registry{} = registry -> {:ok, registry}
      _other -> {:error, Diagnostic.new(:invalid_registry, "A trusted Registry is required")}
    end
  end

  defp prepare_state(state, model, limits) do
    state =
      Map.merge(
        %{
          data: %{},
          system: %{},
          bindings: %{},
          active_state_ids: [],
          internal_queue: [],
          logs: [],
          intents: [],
          session_incarnation: nil,
          generated_id_counter: 0,
          work_count: 0
        },
        state
      )

    valid_shape? =
      is_map(state.data) and is_map(state.system) and is_map(state.bindings) and
        is_list(state.active_state_ids) and is_list(state.internal_queue) and
        is_list(state.logs) and is_list(state.intents) and
        (is_nil(state.session_incarnation) or
           (is_binary(state.session_incarnation) and state.session_incarnation != "" and
              String.valid?(state.session_incarnation))) and
        is_integer(state.generated_id_counter) and state.generated_id_counter >= 0 and
        is_integer(state.work_count) and state.work_count >= 0

    cond do
      not valid_shape? ->
        {:error,
         Diagnostic.new(:invalid_execution_state, "Executable state has an invalid shape")}

      length(state.internal_queue) > limits.internal_queue_events ->
        {:error,
         Diagnostic.new(
           :internal_queue_limit_exceeded,
           "Internal event queue is already oversized"
         )}

      length(state.intents) > limits.external_intents ->
        {:error,
         Diagnostic.new(:external_intent_limit_exceeded, "Intent list is already oversized")}

      length(state.logs) > limits.trace_entries ->
        {:error, Diagnostic.new(:trace_limit_exceeded, "Log list is already oversized")}

      state.work_count > limits.microsteps_per_macrostep ->
        {:error,
         Diagnostic.new(
           :executable_work_limit_exceeded,
           "Executable work count is already over its limit"
         )}

      model == Jido.Statechart.DataModel.Null and state.data != %{} ->
        {:error,
         Diagnostic.new(:invalid_execution_state, "Null data-model state cannot contain data")}

      true ->
        values = [
          {:data, state.data},
          {:system, state.system},
          {:bindings, state.bindings},
          {:active_state_ids, state.active_state_ids},
          {:internal_queue, state.internal_queue},
          {:logs, state.logs},
          {:intents, state.intents}
        ]

        with :ok <- validate_state_values(values, limits),
             :ok <- validate_active_state_ids(state.active_state_ids) do
          {:ok, state}
        else
          {:error, diagnostic} ->
            {:error, %{diagnostic | code: :invalid_execution_state}}
        end
    end
  end

  defp validate_state_values(values, limits) do
    Enum.reduce_while(values, :ok, fn {field, value}, :ok ->
      case DataModel.validate_value(value, [limits: limits], [field]) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_active_state_ids(active_state_ids) do
    active_state_ids
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {state_id, index}, :ok ->
      case Diagnostic.validate_id(state_id, [:active_state_ids, index]) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp charge_work(state, limits) do
    if state.work_count < limits.microsteps_per_macrostep do
      {:ok, %{state | work_count: state.work_count + 1}}
    else
      {:error,
       Diagnostic.new(
         :executable_work_limit_exceeded,
         "Executable work limit was reached",
         path: [:executable],
         correction: %{"maximum_operations" => limits.microsteps_per_macrostep}
       )}
    end
  end

  defp ensure_model_invariant(state, Jido.Statechart.DataModel.Null) do
    if state.data == %{} do
      :ok
    else
      {:error,
       Diagnostic.new(:invalid_execution_state, "Null data-model state cannot contain data")}
    end
  end

  defp ensure_model_invariant(_state, _model), do: :ok

  defp environment(state) do
    %{
      data: state.data,
      system: state.system,
      bindings: state.bindings,
      active_state_ids: state.active_state_ids
    }
  end

  defp action_environment(state) do
    %{
      session_id: Map.get(state.system, "_sessionid"),
      event: Map.get(state.system, "_event"),
      configuration: state.active_state_ids,
      turn_id: Map.get(state.system, "_turnid")
    }
  end

  defp model_options(context), do: [registry: context.registry, limits: context.limits]

  defp action_options(context) do
    base = [
      registry: context.registry,
      limits: context.limits,
      deadline: Keyword.get(context.options, :deadline, :infinity)
    ]

    case Keyword.fetch(context.options, :task_supervisor) do
      {:ok, supervisor} -> Keyword.put(base, :task_supervisor, supervisor)
      :error -> base
    end
  end
end
