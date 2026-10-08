defmodule Jido.Statechart.Runtime.Invocation do
  @moduledoc "Materializes bounded local invocation lifecycle intent."

  alias Jido.Statechart.Runtime.Child
  alias Jido.Statechart.Session.Operation
  alias Jido.Statechart.Model.{Chart, Event, Executable}
  alias Jido.Statechart.{DataModel, Diagnostic, ExecutableContent, Limits, Registry, Session}

  @scxml_types ["scxml", "http://www.w3.org/TR/scxml/"]
  @jido_types ["jido", "urn:jido:agent"]

  @doc false
  def enter(%Chart{} = chart, state_id, workspace, options) do
    chart
    |> definitions(state_id)
    |> Enum.reduce_while({:ok, workspace}, fn definition, {:ok, current} ->
      case semantic_start(definition, current, options) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _diagnostic} = error -> {:halt, error}
      end
    end)
  end

  @doc false
  def exit(%Chart{} = chart, state_id, workspace, options) do
    chart
    |> definitions(state_id)
    |> Enum.reduce_while({:ok, workspace}, fn definition, {:ok, current} ->
      if active_semantic_invoke?(current, definition["invoke_id"]) do
        append_semantic(
          current,
          %{
            "kind" => "stop_invoke",
            "invoke_id" => definition["invoke_id"],
            "owner_state_id" => state_id
          },
          options
        )
        |> case do
          {:ok, next} -> {:cont, {:ok, next}}
          {:error, _diagnostic} = error -> {:halt, error}
        end
      else
        {:cont, {:ok, current}}
      end
    end)
  end

  @doc false
  def before_selection(%Chart{} = chart, workspace, %Event{} = event, options) do
    definitions = active_definitions(chart, workspace.active_state_ids)

    with {:ok, workspace} <- finalize(definitions, workspace, event, options),
         {:ok, workspace} <- autoforward(definitions, workspace, event, options) do
      {:ok, workspace}
    end
  end

  defp definitions(chart, state_id),
    do: chart.metadata |> Map.get("invocations", %{}) |> Map.get(state_id, [])

  defp active_definitions(chart, active_state_ids) do
    active_state_ids
    |> Enum.flat_map(&definitions(chart, &1))
    |> Enum.sort_by(&{Map.fetch!(chart.state_index, &1["state_id"]), &1["ordinal"]})
  end

  defp semantic_start(definition, workspace, options) do
    with {:ok, model} <- DataModel.resolve(Keyword.fetch!(options, :data_model)),
         {:ok, type} <- selected(definition, "type", "typeexpr", model, workspace, options),
         {:ok, capability} <-
           selected(definition, "capability", "srcexpr", model, workspace, options),
         {:ok, params} <- invocation_params(definition),
         {:ok, input} <-
           model.construct(
             %{
               "params" => params,
               "content" => definition["invoke_content"]
             },
             environment(workspace),
             options
           ),
         intent = %{
           "kind" => "invoke",
           "invoke_id" => definition["invoke_id"],
           "type" => type || "scxml",
           "capability" => capability,
           "input" => input || %{},
           "owner_state_id" => definition["state_id"],
           "autoforward" => definition["autoforward"] == true
         },
         {:ok, workspace} <- assign_idlocation(definition, workspace, model, options) do
      append_semantic(workspace, intent, options)
    end
  end

  defp invocation_params(definition) do
    namelist = get_in(definition, ["attributes", "namelist"])

    cond do
      is_nil(namelist) ->
        {:ok, definition["params"] || []}

      is_binary(namelist) and String.valid?(namelist) ->
        names = String.split(namelist, ~r/\s+/u, trim: true)
        params = Enum.map(names, &%{"name" => &1, "location" => &1})
        {:ok, params ++ (definition["params"] || [])}

      true ->
        invocation_error(:invalid_invocation, "Invocation namelist is invalid")
    end
  end

  defp selected(definition, static, expression, model, workspace, options) do
    attributes = definition["attributes"] || %{}

    case attributes[expression] do
      value when is_binary(value) -> model.value(value, environment(workspace), options)
      nil -> {:ok, definition[static]}
      _other -> invocation_error(:invalid_invocation, "Invocation selector is invalid")
    end
  end

  defp assign_idlocation(definition, workspace, model, options) do
    case get_in(definition, ["attributes", "idlocation"]) do
      nil ->
        {:ok, workspace}

      location ->
        case model.assign(location, definition["invoke_id"], workspace.data, options) do
          {:ok, data} -> {:ok, %{workspace | data: data}}
          {:error, _diagnostic} = error -> error
        end
    end
  end

  defp finalize(definitions, workspace, %Event{invoke_id: invoke_id}, options)
       when is_binary(invoke_id) do
    case Enum.find(definitions, &(&1["invoke_id"] == invoke_id)) do
      nil ->
        {:ok, workspace}

      definition ->
        commands = Enum.map(definition["finalize"] || [], &Executable.new!/1)
        ExecutableContent.run(commands, workspace, options)
    end
  end

  defp finalize(_definitions, workspace, _event, _options), do: {:ok, workspace}

  defp autoforward(definitions, workspace, event, options) do
    Enum.reduce_while(definitions, {:ok, workspace}, fn definition, {:ok, current} ->
      if definition["autoforward"] == true and
           active_semantic_invoke?(current, definition["invoke_id"]) do
        append_semantic(
          current,
          %{
            "kind" => "invoke_send",
            "invoke_id" => definition["invoke_id"],
            "event" => Event.dump(event)
          },
          options
        )
        |> case do
          {:ok, next} -> {:cont, {:ok, next}}
          {:error, _diagnostic} = error -> {:halt, error}
        end
      else
        {:cont, {:ok, current}}
      end
    end)
  end

  defp active_semantic_invoke?(workspace, invoke_id) do
    committed =
      workspace
      |> Map.get(:operations, %{})
      |> Map.values()
      |> Enum.any?(fn
        %Operation{kind: :invoke, state: state, correlation: correlation} ->
          state in [:not_started, :result_unknown] and correlation["invoke_id"] == invoke_id

        _other ->
          false
      end)

    authored =
      Enum.any?(workspace.intents, fn
        %{"kind" => "invoke", "invoke_id" => ^invoke_id} -> true
        _other -> false
      end)

    committed or authored
  end

  defp append_semantic(workspace, intent, options) do
    limits = Keyword.fetch!(options, :limits)

    if length(workspace.intents) < limits.external_intents do
      {:ok, %{workspace | intents: workspace.intents ++ [intent]}}
    else
      invocation_error(:external_intent_limit_exceeded, "External intent limit was reached")
    end
  end

  defp environment(workspace) do
    %{
      data: workspace.data,
      system: workspace.system,
      bindings: workspace.bindings,
      active_state_ids: workspace.active_state_ids
    }
  end

  @spec from_semantic(map(), Session.t(), Registry.t(), Limits.t(), term(), keyword()) ::
          {:ok, Operation.t()} | {:error, Diagnostic.t()}
  def from_semantic(value, session, registry, limits, _now, options \\ [])

  def from_semantic(
        %{} = value,
        %Session{} = session,
        %Registry{} = registry,
        %Limits{} = limits,
        _now,
        options
      )
      when not is_struct(value) and is_list(options) do
    generation = Keyword.get(options, :generation, session.operation_counter)
    revision = Keyword.get(options, :created_revision, session.revision)

    case Diagnostic.fetch(value, :kind) do
      kind when kind in [:invoke, "invoke"] ->
        start(value, session, registry, limits, generation, revision)

      kind when kind in [:stop_invoke, "stop_invoke"] ->
        stop(value, session, generation, revision, Keyword.get(options, :prior_operations, []))

      kind when kind in [:invoke_send, "invoke_send"] ->
        forward(value, session, generation, revision, Keyword.get(options, :prior_operations, []))

      _other ->
        {:error, Diagnostic.new(:invalid_invocation_kind, "Invocation intent kind is invalid")}
    end
  end

  def from_semantic(_value, _session, _registry, _limits, _now, _options),
    do: {:error, Diagnostic.new(:invalid_invocation, "Invocation intent is invalid")}

  @doc false
  @spec completion_stop(Operation.t(), Session.t()) ::
          {:ok, Operation.t(), Session.t()} | {:error, Diagnostic.t()}
  def completion_stop(%Operation{kind: :invoke} = invoke, %Session{} = session) do
    correlation = %{
      "kind" => "stop_invoke",
      "invoke_id" => invoke.correlation["invoke_id"],
      "invoke_operation_id" => invoke.id,
      "invoke_generation" => invoke.generation,
      "owner_state_id" => invoke.correlation["owner_state_id"],
      "child_tag" => invoke.target,
      "reason" => "completed"
    }

    with {:ok, operation} <-
           Operation.new(%{
             session_incarnation: session.incarnation,
             kind: :child_stop,
             target: invoke.target,
             key: "invoke-stop:" <> invoke.correlation["invoke_id"],
             payload_digest: Diagnostic.digest(correlation),
             generation: session.operation_counter,
             created_revision: session.revision,
             correlation: correlation
           }) do
      {:ok, operation, %{session | operation_counter: session.operation_counter + 1}}
    end
  end

  @doc "Resolves and validates one trusted invocation capability."
  @spec capability(Registry.t(), String.t(), String.t()) ::
          {:ok, Registry.Entry.t()} | {:error, Diagnostic.t()}
  def capability(%Registry{} = registry, name, type)
      when is_binary(name) and is_binary(type) do
    with {:ok, invocation_type} <- invocation_type(type),
         {:ok, entry} <- fetch_capability(registry, name),
         :ok <- capability_type(entry, invocation_type),
         :ok <- permissions(entry, invocation_type),
         :ok <- local_scope(entry),
         :ok <- invocation_handler(entry, invocation_type) do
      {:ok, entry}
    end
  end

  def capability(_registry, _name, _type),
    do: invocation_error(:invalid_invocation, "Invocation capability is invalid")

  @doc false
  def child_may_exist?(%{"reason" => reason})
      when reason in [
             "child_start_failed",
             "child_not_found",
             "child_exit",
             "child_stopped",
             "child_ownership_conflict"
           ],
      do: false

  def child_may_exist?(_result), do: true

  defp start(value, session, registry, limits, generation, revision) do
    invoke_id = Diagnostic.fetch(value, :invoke_id)
    type = Diagnostic.fetch(value, :type, "scxml")
    capability_name = Diagnostic.fetch(value, :capability)
    input = Diagnostic.fetch(value, :input, %{})
    owner = Diagnostic.fetch(value, :owner_state_id)
    autoforward = Diagnostic.fetch(value, :autoforward, false)

    with :ok <- Diagnostic.validate_id(invoke_id, [:invoke, :id]),
         :ok <- Diagnostic.validate_id(owner, [:invoke, :owner_state_id]),
         true <- is_boolean(autoforward),
         :ok <- Diagnostic.portable(input, [:invoke, :input]),
         {:ok, entry} <- capability(registry, capability_name, type),
         {:ok, context} <- invocation_context(value, session, entry, limits),
         tag = Child.tag(session.incarnation, invoke_id, generation),
         correlation = %{
           "kind" => "invoke",
           "invoke_id" => invoke_id,
           "type" => normalize_type(type),
           "capability" => capability_name,
           "input" => input,
           "owner_state_id" => owner,
           "autoforward" => autoforward,
           "child_tag" => tag,
           "child_restart" => "temporary",
           "ancestry" => context.ancestry,
           "depth" => context.depth,
           "remaining_descendants" => context.remaining_descendants,
           "reserved_descendants" => context.reserved_descendants
         },
         :ok <- Diagnostic.portable(correlation, [:invoke]) do
      Operation.new(%{
        session_incarnation: session.incarnation,
        kind: :invoke,
        target: tag,
        key: "invoke:" <> invoke_id,
        payload_digest: Diagnostic.digest(correlation),
        generation: generation,
        created_revision: revision,
        correlation: correlation
      })
    else
      false -> invocation_error(:invalid_invocation, "Invocation values are invalid")
      {:error, _diagnostic} = error -> error
    end
  end

  defp stop(value, session, generation, revision, prior) do
    invoke_id = Diagnostic.fetch(value, :invoke_id)
    owner = Diagnostic.fetch(value, :owner_state_id)

    with :ok <- Diagnostic.validate_id(invoke_id, [:invoke, :id]),
         {:ok, invoke} <- active_invoke(session, prior, invoke_id, owner),
         correlation = %{
           "kind" => "stop_invoke",
           "invoke_id" => invoke_id,
           "invoke_operation_id" => invoke.id,
           "invoke_generation" => invoke.generation,
           "owner_state_id" => owner,
           "child_tag" => invoke.target
         } do
      Operation.new(%{
        session_incarnation: session.incarnation,
        kind: :child_stop,
        target: invoke.target,
        key: "invoke-stop:" <> invoke_id,
        payload_digest: Diagnostic.digest(correlation),
        generation: generation,
        created_revision: revision,
        correlation: correlation
      })
    end
  end

  defp forward(value, session, generation, revision, prior) do
    invoke_id = Diagnostic.fetch(value, :invoke_id)
    event = Diagnostic.fetch(value, :event)

    with :ok <- Diagnostic.validate_id(invoke_id, [:invoke, :id]),
         :ok <- Diagnostic.portable(event, [:invoke, :event]),
         {:ok, invoke} <- active_invoke(session, prior, invoke_id, nil),
         correlation = %{
           "kind" => "invoke_send",
           "invoke_id" => invoke_id,
           "invoke_operation_id" => invoke.id,
           "invoke_generation" => invoke.generation,
           "child_tag" => invoke.target,
           "event" => event
         } do
      Operation.new(%{
        session_incarnation: session.incarnation,
        kind: :child_start,
        target: invoke.target,
        key: nil,
        payload_digest: Diagnostic.digest(correlation),
        generation: generation,
        created_revision: revision,
        correlation: correlation
      })
    end
  end

  defp active_invoke(session, prior, invoke_id, owner) do
    (Map.values(session.operations) ++ List.wrap(prior))
    |> Enum.filter(fn
      %Operation{kind: :invoke, correlation: correlation, state: state} ->
        correlation["invoke_id"] == invoke_id and state in [:not_started, :result_unknown] and
          (is_nil(owner) or correlation["owner_state_id"] == owner)

      _other ->
        false
    end)
    |> Enum.max_by(& &1.generation, fn -> nil end)
    |> case do
      %Operation{} = operation -> {:ok, operation}
      nil -> invocation_error(:inactive_invocation, "Invocation is not active")
    end
  end

  defp invocation_context(value, session, entry, limits) do
    supplied_ancestry = Diagnostic.fetch(value, :ancestry, session.invocation_ancestry)
    supplied_depth = Diagnostic.fetch(value, :depth, session.invocation_depth)

    supplied_remaining =
      Diagnostic.fetch(
        value,
        :remaining_descendants,
        session.invocation_remaining_descendants || limits.total_descendants
      )

    child_fingerprint = Map.get(entry.metadata, "chart_fingerprint")
    reserved = Diagnostic.fetch(value, :reserved_descendants)
    available = supplied_remaining - session.invocation_descendants_used

    cond do
      not is_list(supplied_ancestry) or
          not Enum.all?(supplied_ancestry, &(is_binary(&1) and &1 != "")) ->
        invocation_error(:invalid_invocation_ancestry, "Invocation ancestry is invalid")

      not is_integer(supplied_depth) or supplied_depth < 0 or
          supplied_depth >= limits.invocation_depth ->
        invocation_error(:invocation_depth_exceeded, "Invocation depth limit was reached")

      not is_integer(supplied_remaining) or supplied_remaining < 0 ->
        invocation_error(
          :invocation_descendant_limit_exceeded,
          "Invocation descendant budget was exhausted"
        )

      not is_nil(reserved) and (not is_integer(reserved) or reserved <= 0 or reserved > available) ->
        invocation_error(
          :invocation_descendant_limit_exceeded,
          "Invocation descendant reservation is invalid"
        )

      is_nil(reserved) and available <= 0 ->
        invocation_error(
          :invocation_descendant_limit_exceeded,
          "Invocation descendant budget was exhausted"
        )

      is_binary(child_fingerprint) and child_fingerprint in supplied_ancestry ->
        invocation_error(:invocation_recursion, "Invocation ancestry contains the child chart")

      true ->
        ancestry =
          if is_binary(child_fingerprint),
            do: supplied_ancestry ++ [child_fingerprint],
            else: supplied_ancestry

        reservation = reserved || available

        {:ok,
         %{
           ancestry: ancestry,
           depth: supplied_depth + 1,
           remaining_descendants: reservation - 1,
           reserved_descendants: reservation
         }}
    end
  end

  defp invocation_type(type) when type in @scxml_types, do: {:ok, :scxml}
  defp invocation_type(type) when type in @jido_types, do: {:ok, :jido}

  defp invocation_type(_type),
    do: invocation_error(:unsupported_invocation_type, "Invocation type is unsupported")

  defp normalize_type(type) when type in @scxml_types, do: "scxml"
  defp normalize_type(type) when type in @jido_types, do: "jido"
  defp normalize_type(type), do: type

  defp fetch_capability(registry, name) do
    case Registry.fetch(registry, :invocation, name) do
      {:ok, entry} ->
        {:ok, entry}

      :error ->
        invocation_error(
          :unknown_invocation_capability,
          "Invocation capability is not registered"
        )
    end
  end

  defp capability_type(entry, type) do
    expected = Atom.to_string(type)

    case Map.get(entry.metadata, "type") do
      ^expected ->
        :ok

      _other ->
        invocation_error(:invocation_type_mismatch, "Invocation capability type does not match")
    end
  end

  defp permissions(entry, type) do
    required = "invoke:" <> Atom.to_string(type)

    if required in entry.permissions,
      do: :ok,
      else: invocation_error(:invocation_permission_denied, "Invocation permission is missing")
  end

  defp local_scope(entry) do
    if "scope:local" in entry.permissions and Map.get(entry.metadata, "scope", "local") == "local",
      do: :ok,
      else: invocation_error(:invocation_scope_not_allowed, "Invocation must use local scope")
  end

  defp invocation_handler(entry, :jido), do: agent_handler(entry.handler)

  defp invocation_handler(entry, :scxml) do
    with :ok <- agent_handler(entry.handler),
         fingerprint when is_binary(fingerprint) <-
           Map.get(entry.metadata, "chart_fingerprint"),
         config when is_map(config) <- entry.handler.__agent_config__(),
         plugins when is_list(plugins) <- Map.get(config, :plugins),
         {:ok, options} <- statechart_plugin_options(plugins),
         chart when is_atom(chart) <- Keyword.get(options, :chart),
         true <- function_exported?(chart, :chart, 0),
         %{fingerprint: ^fingerprint} <- chart.chart() do
      :ok
    else
      _other ->
        invocation_error(
          :invalid_invocation_handler,
          "SCXML invocation handler does not own the registered child chart"
        )
    end
  rescue
    _error -> invocation_error(:invalid_invocation_handler, "Invocation handler is invalid")
  end

  defp statechart_plugin_options(plugins) do
    case Enum.find(plugins, fn
           {Jido.Statechart.Plugin, options} when is_list(options) -> true
           _other -> false
         end) do
      {Jido.Statechart.Plugin, options} -> {:ok, options}
      nil -> :error
    end
  end

  defp agent_handler(module) when is_atom(module) and not is_nil(module) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :__agent_config__, 0),
         config when is_map(config) <- module.__agent_config__() do
      :ok
    else
      _other ->
        invocation_error(:invalid_invocation_handler, "Invocation handler is not a Jido Agent")
    end
  rescue
    _error -> invocation_error(:invalid_invocation_handler, "Invocation handler is invalid")
  end

  defp agent_handler(_handler),
    do: invocation_error(:invalid_invocation_handler, "Invocation handler is not a Jido Agent")

  defp invocation_error(code, message),
    do: {:error, Diagnostic.new(code, message, path: [:invoke])}
end
