defmodule Jido.Statechart.Semantics.Macrostep do
  @moduledoc "Pure SCXML initialization and run-to-completion macrosteps."

  alias Jido.Statechart.{DataModel, Diagnostic, Limits, Registry, Session}
  alias Jido.Statechart.Model.{Chart, Event}
  alias Jido.Statechart.Semantics.{Configuration, History, Microstep, Selection, Trace}

  @fatal_data_codes [
    :data_limit_exceeded,
    :expression_limit_exceeded,
    :internal_queue_limit_exceeded
  ]

  @type result :: %{
          session: Session.t(),
          intents: [map()],
          trace: [map()],
          work_count: non_neg_integer(),
          operation_counts: map()
        }

  @spec initialize(Chart.t(), Session.t(), keyword()) ::
          {:ok, result()} | {:error, Diagnostic.t()}
  def initialize(%Chart{} = chart, %Session{} = session, options) when is_list(options) do
    with {:ok, context} <- context(chart, session, options),
         :ok <- validate_session_boundary(chart, session, context.options),
         :ok <- new_session(session),
         {:ok, workspace} <- workspace(chart, session, context.options),
         {:ok, workspace} <- initialize_data(chart, workspace, context.options),
         {:ok, workspace} <- Microstep.initialize(chart, workspace, context.options),
         workspace = %{workspace | status: active_status(workspace.status)},
         {:ok, workspace} <- Trace.append(workspace, Trace.microstep(workspace), context.options),
         {:ok, workspace} <- stabilize(chart, workspace, context.options),
         {:ok, workspace} <- exit_interpreter(chart, workspace, context.options) do
      finish(chart, session, workspace, context.options)
    end
  end

  def initialize(_chart, _session, _options) do
    {:error, Diagnostic.new(:invalid_semantic_input, "initialization input is invalid")}
  end

  @spec run(Chart.t(), Session.t(), Event.t() | map(), keyword()) ::
          {:ok, result()} | {:error, Diagnostic.t()}
  def run(%Chart{} = chart, %Session{} = session, event, options) when is_list(options) do
    with {:ok, context} <- context(chart, session, options),
         :ok <- validate_session_boundary(chart, session, context.options),
         :ok <- runnable_session(session),
         :ok <- Configuration.validate(chart, session.configuration),
         {:ok, event} <- normalize_event(event, :external),
         :ok <- validate_event_boundary(event, context.options),
         {:ok, workspace} <- workspace(chart, session, context.options),
         {:ok, workspace} <- process_event(chart, workspace, event, context.options),
         {:ok, workspace} <- stabilize(chart, workspace, context.options),
         {:ok, workspace} <- exit_interpreter(chart, workspace, context.options) do
      finish(chart, session, workspace, context.options)
    end
  end

  def run(_chart, _session, _event, _options) do
    {:error, Diagnostic.new(:invalid_semantic_input, "macrostep input is invalid")}
  end

  defp context(chart, session, options) do
    if Keyword.keyword?(options) do
      with %Registry{} = registry <- Keyword.get(options, :registry),
           %Limits{} = supplied_limits <- Keyword.get(options, :limits, Limits.default()),
           {:ok, limits} <- Limits.new(Map.from_struct(supplied_limits)),
           :ok <- chart_session(chart, session),
           :ok <- Session.validate_contract(session, registry, limits) do
        enriched =
          options
          |> Keyword.put(:limits, limits)
          |> Keyword.put(:registry, registry)
          |> Keyword.put(:data_model, chart.datamodel)

        {:ok, %{registry: registry, limits: limits, options: enriched}}
      else
        nil ->
          {:error, Diagnostic.new(:invalid_registry, "A trusted Registry is required")}

        {:error, _diagnostic} = error ->
          error

        _other ->
          {:error, Diagnostic.new(:invalid_semantic_options, "Macrostep options are invalid")}
      end
    else
      {:error, Diagnostic.new(:invalid_semantic_options, "Macrostep options are invalid")}
    end
  end

  defp chart_session(chart, session) do
    if chart.fingerprint == session.chart_fingerprint,
      do: :ok,
      else: {:error, Diagnostic.new(:chart_fingerprint_mismatch, "session chart does not match")}
  end

  defp validate_session_boundary(chart, session, options) do
    with {:ok, limits} <- DataModel.limits(options),
         :ok <- History.validate(chart, session.history),
         :ok <- validate_initialized_data_states(chart, session),
         :ok <- DataModel.validate_value(session.data, options, [:session, :data]),
         :ok <- validate_completion_data(session.completion_data, options),
         :ok <- validate_queue(session.internal_queue, limits, options),
         :ok <- validate_trace(session.trace, limits, options),
         :ok <- validate_session_size(session, limits) do
      :ok
    end
  end

  defp validate_initialized_data_states(chart, session) do
    by_id = Configuration.state_map(chart)
    ids = session.initialized_data_state_ids

    valid? = is_list(ids) and initialized_data_states?(chart, ids, by_id)

    if valid? do
      :ok
    else
      {:error,
       Diagnostic.new(
         :invalid_initialized_data_states,
         "initialized data state identifiers are not valid for the chart binding",
         path: [:session, :initialized_data_state_ids]
       )}
    end
  end

  defp initialized_data_states?(chart, ids, by_id) do
    case chart.binding do
      "early" ->
        ids == []

      "late" ->
        data_states? =
          Enum.all?(ids, fn id ->
            case Map.get(by_id, id) do
              %{data: data} when is_map(data) -> map_size(data) > 0
              _other -> false
            end
          end)

        data_states? and ids == Enum.uniq(ids) and
          ids == Configuration.entry_order(chart, ids)
    end
  end

  defp validate_completion_data(nil, _options), do: :ok

  defp validate_completion_data(value, options),
    do: DataModel.validate_value(value, options, [:session, :completion_data])

  defp validate_queue(queue, limits, options) when is_list(queue) do
    if length(queue) <= limits.internal_queue_events do
      queue
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {event, index}, :ok ->
        with {:ok, event} <- normalize_event(event, :internal),
             :ok <-
               DataModel.validate_value(
                 Event.dump(event),
                 options,
                 [:session, :internal_queue, index]
               ) do
          {:cont, :ok}
        else
          {:error, _diagnostic} = error -> {:halt, error}
        end
      end)
    else
      {:error,
       Diagnostic.new(:internal_queue_limit_exceeded, "Internal event queue limit was reached",
         path: [:session, :internal_queue],
         correction: %{"maximum_events" => limits.internal_queue_events}
       )}
    end
  end

  defp validate_queue(_queue, _limits, _options),
    do: {:error, Diagnostic.new(:invalid_event_queue, "Internal event queue must be a list")}

  defp validate_trace(trace, limits, options) when is_list(trace) do
    cond do
      length(trace) > limits.trace_entries ->
        {:error,
         Diagnostic.new(:trace_limit_exceeded, "Trace entry limit was reached",
           path: [:session, :trace],
           correction: %{"maximum_entries" => limits.trace_entries}
         )}

      true ->
        DataModel.validate_value(trace, options, [:session, :trace])
    end
  end

  defp validate_trace(_trace, _limits, _options),
    do: {:error, Diagnostic.new(:invalid_trace, "Session trace must be a list")}

  defp validate_session_size(session, limits) do
    bytes = deterministic_bytes(Session.dump(session))

    if bytes <= limits.session_bytes do
      :ok
    else
      {:error,
       Diagnostic.new(:session_size_limit_exceeded, "Session exceeds the configured byte limit",
         path: [:session],
         correction: %{"maximum_bytes" => limits.session_bytes}
       )}
    end
  end

  defp validate_event_boundary(event, options) do
    DataModel.validate_value(Event.dump(event), options, [:event])
  end

  defp deterministic_bytes(value),
    do: value |> :erlang.term_to_binary([:deterministic]) |> byte_size()

  defp new_session(%Session{status: :new, configuration: []}), do: :ok

  defp new_session(_session) do
    {:error,
     Diagnostic.new(:invalid_session_status, "initialization requires a new empty session")}
  end

  defp runnable_session(%Session{status: :active}), do: :ok

  defp runnable_session(%Session{status: :completed}) do
    {:error, Diagnostic.new(:session_completed, "completed session cannot process events")}
  end

  defp runnable_session(_session) do
    {:error, Diagnostic.new(:invalid_session_status, "session is not active")}
  end

  defp workspace(chart, session, options) do
    with {:ok, limits} <- DataModel.limits(options),
         true <- length(session.internal_queue) <= limits.internal_queue_events,
         true <- length(session.trace) <= limits.trace_entries do
      {:ok,
       %{
         configuration: session.configuration,
         active_state_ids: Configuration.active_state_ids(chart, session.configuration),
         history: session.history,
         data: session.data,
         system: %{
           "_event" => nil,
           "_sessionid" => session.id,
           "_name" => chart.name || chart.id,
           "_ioprocessors" => %{},
           "_x" => %{}
         },
         bindings: %{},
         internal_queue: session.internal_queue,
         logs: [],
         intents: [],
         session_incarnation: session.incarnation,
         generated_id_counter: session.generated_id_counter,
         initialized_data_state_ids: session.initialized_data_state_ids,
         completion_data: session.completion_data,
         status: session.status,
         trace: session.trace,
         trace_start: length(session.trace),
         work_count: 0,
         last_microstep: nil
       }}
    else
      false -> {:error, Diagnostic.new(:limit_exceeded, "session exceeds a semantic limit")}
      {:error, _diagnostic} = error -> error
    end
  end

  defp initialize_data(chart, workspace, options) do
    with {:ok, model} <- DataModel.resolve(chart.datamodel),
         {:ok, workspace} <-
           initialize_declarations(
             model,
             Map.get(chart.metadata, "root_data", %{}),
             workspace,
             options
           ) do
      if chart.binding == "early" do
        Enum.reduce_while(chart.states, {:ok, workspace}, fn state, {:ok, current} ->
          case initialize_declarations(model, state.data, current, options) do
            {:ok, next} -> {:cont, {:ok, next}}
            {:error, _diagnostic} = error -> {:halt, error}
          end
        end)
      else
        {:ok, workspace}
      end
    end
  end

  defp initialize_declarations(model, declarations, workspace, options) do
    case model.initialize(declarations, environment(workspace), options) do
      {:ok, value} ->
        {:ok, %{workspace | data: Map.merge(workspace.data, value)}}

      {:error, %Diagnostic{code: code} = diagnostic} when code in @fatal_data_codes ->
        {:error, diagnostic}

      {:error, diagnostic} ->
        enqueue_execution_error(workspace, diagnostic, options)
    end
  end

  defp enqueue_execution_error(workspace, diagnostic, options) do
    with {:ok, limits} <- DataModel.limits(options) do
      if length(workspace.internal_queue) < limits.internal_queue_events do
        event = %{
          "name" => "error.execution",
          "class" => "platform",
          "data" => %{"code" => Atom.to_string(diagnostic.code), "message" => diagnostic.message},
          "message_id" => nil,
          "send_id" => nil,
          "origin" => nil,
          "origin_type" => nil,
          "invoke_id" => nil,
          "turn_id" => nil,
          "session_id" => workspace.system["_sessionid"]
        }

        {:ok, %{workspace | internal_queue: workspace.internal_queue ++ [event]}}
      else
        {:error,
         Diagnostic.new(:internal_queue_limit_exceeded, "Internal event queue limit was reached")}
      end
    end
  end

  defp process_event(chart, workspace, event, options) do
    event_map = Event.dump(event)

    with {:ok, transitions, workspace} <-
           Selection.select(chart, workspace.configuration, event, workspace, options) do
      workspace = put_event(workspace, event_map)

      case transitions do
        [] -> Trace.append(workspace, Trace.discarded(event_map), options)
        selected -> run_microstep(chart, workspace, selected, options)
      end
    end
  end

  defp stabilize(_chart, %{status: :completed} = workspace, _options), do: {:ok, workspace}

  defp stabilize(chart, workspace, options) do
    with {:ok, transitions, workspace} <-
           Selection.select(chart, workspace.configuration, nil, workspace, options) do
      cond do
        transitions != [] ->
          with {:ok, workspace} <- run_microstep(chart, workspace, transitions, options) do
            stabilize(chart, workspace, options)
          end

        workspace.internal_queue != [] ->
          [event | rest] = workspace.internal_queue
          workspace = %{workspace | internal_queue: rest}

          with {:ok, event} <- normalize_event(event, :internal),
               {:ok, workspace} <- process_event(chart, workspace, event, options) do
            stabilize(chart, workspace, options)
          end

        true ->
          {:ok, workspace}
      end
    end
  end

  defp run_microstep(chart, workspace, transitions, options) do
    with {:ok, workspace} <- Microstep.run(chart, workspace, transitions, options),
         {:ok, workspace} <- Trace.append(workspace, Trace.microstep(workspace), options) do
      {:ok, workspace}
    end
  end

  defp exit_interpreter(chart, %{status: :completed, configuration: [_ | _]} = workspace, options) do
    with {:ok, workspace} <- Microstep.exit_interpreter(chart, workspace, options),
         {:ok, workspace} <- Trace.append(workspace, Trace.terminal(workspace), options) do
      {:ok, workspace}
    end
  end

  defp exit_interpreter(_chart, workspace, _options), do: {:ok, workspace}

  defp normalize_event(%Event{} = event, _default_class), do: {:ok, event}

  defp normalize_event(event, default_class) when is_map(event) do
    attrs =
      if Map.has_key?(event, :class) or Map.has_key?(event, "class"),
        do: event,
        else: Map.put(event, :class, default_class)

    Event.new(attrs)
  end

  defp normalize_event(_event, _default_class) do
    {:error, Diagnostic.new(:invalid_event, "macrostep event is invalid")}
  end

  defp put_event(workspace, event),
    do: %{workspace | system: Map.put(workspace.system, "_event", event)}

  defp active_status(:new), do: :active
  defp active_status(status), do: status

  defp finish(chart, original, workspace, options) do
    session = %{
      original
      | status: workspace.status,
        generated_id_counter: workspace.generated_id_counter,
        initialized_data_state_ids: workspace.initialized_data_state_ids,
        configuration: workspace.configuration,
        history: workspace.history,
        data: workspace.data,
        internal_queue: workspace.internal_queue,
        completion_data: workspace.completion_data,
        trace: workspace.trace
    }

    with :ok <- validate_session_boundary(chart, session, options) do
      trace = Enum.drop(workspace.trace, workspace.trace_start)

      counts =
        workspace.intents
        |> Enum.frequencies_by(&Map.get(&1, "kind", "unknown"))
        |> Map.new(fn {kind, count} -> {kind, count} end)

      {:ok,
       %{
         session: session,
         intents: workspace.intents,
         trace: trace,
         work_count: workspace.work_count,
         operation_counts: counts
       }}
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
end
