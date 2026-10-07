defmodule Jido.Statechart.Plugin do
  @moduledoc """
  Owns the one committed statechart session in an Agent.

  The Plugin reducer is the only live write path for session state. Runtime
  proof secrets, process handles, and reconciliation resources stay in the
  supervised Plugin runtime and never enter this value.
  """

  use Jido.Plugin, vsn: 2

  alias Jido.Agent.Plugin.{Preparation, Reduction}
  alias Jido.AgentServer.Plugin.Admission
  alias Jido.Statechart.Agent
  alias Jido.Statechart.Model.Event
  alias Jido.Statechart.Plugin.{Commit, Persistence, Runtime}
  alias Jido.Statechart.{Diagnostic, Limits, Session}

  @state_format_version 1
  @default_duplicate_window 1_024
  @default_rescan_interval 1_000
  @allowed_state_keys [:format_version, :session, :recent_signal_ids]
  @immutable_session_fields [
    :schema_version,
    :runtime_protocol_version,
    :profile_version,
    :data_model_version,
    :registry_version,
    :limits_version,
    :id,
    :incarnation,
    :chart_fingerprint,
    :registry_digest,
    :limits_digest
  ]
  @immutable_operation_fields [
    :id,
    :identity_version,
    :session_incarnation,
    :kind,
    :target,
    :payload_digest,
    :due_at,
    :generation,
    :created_revision,
    :correlation
  ]

  @impl Jido.Plugin
  def state_spec(_opts) do
    schema =
      Zoi.any()
      |> Zoi.refine({__MODULE__, :validate_state, []})
      |> Zoi.default(state(nil))

    {:statechart, schema}
  end

  @impl Jido.Plugin
  def directives(_opts), do: [Commit]

  @impl Jido.Plugin
  def validate_options(opts) do
    with {:ok, _config} <- config(opts), do: :ok
  end

  @impl Jido.Plugin
  def prepare(%Preparation{} = preparation, opts) do
    with {:ok, config} <- config(opts),
         :ok <- validate_state(preparation.plugin_state, []),
         {:ok, prepared} <- prepare_signal(preparation, config) do
      {:ok, prepared}
    end
  end

  @impl Jido.Plugin
  def reduce(%Reduction{} = reduction, opts) do
    with {:ok, config} <- config(opts),
         :ok <- validate_state(reduction.plugin_state, []),
         commits = Enum.filter(reduction.directives, &match?(%Commit{}, &1)),
         {:ok, state} <- reduce_commits(reduction, commits, config) do
      {:ok, state}
    end
  end

  @impl Jido.Plugin
  def admit(runtime, %Admission{signal: signal} = admission, _opts) do
    if Agent.reserved_signal?(signal.type) do
      with :ok <- Runtime.verify(runtime, admission),
           do: {:ok, %{authenticated_reserved: true}}
    else
      {:ok, %{}}
    end
  end

  @impl Jido.Plugin
  def child_spec(init), do: Runtime.child_spec(init)

  @impl Jido.Plugin
  def await_ready(runtime, opts), do: Runtime.await_ready(runtime, opts)

  @impl Jido.Plugin
  def after_commit(runtime, commit, opts), do: Runtime.after_commit(runtime, commit, opts)

  @impl Jido.Plugin
  defdelegate dump(value, context, opts), to: Persistence

  @impl Jido.Plugin
  defdelegate load(value, context, opts), to: Persistence

  @doc "Returns one valid live Plugin state value."
  @spec state(Session.t() | nil, [String.t()]) :: map()
  def state(session, recent_signal_ids \\ []) do
    %{
      format_version: @state_format_version,
      session: session,
      recent_signal_ids: recent_signal_ids
    }
  end

  @doc false
  def checkpoint_version, do: Persistence.checkpoint_version()

  @doc false
  defdelegate migrate(value, opts), to: Persistence

  @doc false
  def validate_state(value, _refinement_opts) when is_map(value) and not is_struct(value) do
    unknown = Map.keys(value) -- @allowed_state_keys
    session = Map.get(value, :session)
    ids = Map.get(value, :recent_signal_ids)

    cond do
      unknown != [] ->
        {:error, "Statechart Plugin state contains unknown fields"}

      Map.get(value, :format_version) != @state_format_version ->
        {:error, "Statechart Plugin state version is invalid"}

      not is_nil(session) and not match?({:ok, %Session{}}, Session.new(session)) ->
        {:error, "Statechart Plugin session is invalid"}

      not is_list(ids) or ids != Enum.uniq(ids) or
          not Enum.all?(ids, &(is_binary(&1) and &1 != "" and String.valid?(&1))) ->
        {:error, "Statechart duplicate window is invalid"}

      Jido.PortableTerm.validate(value, [:statechart]) != :ok ->
        {:error, "Statechart Plugin state is not portable"}

      true ->
        :ok
    end
  end

  def validate_state(_value, _refinement_opts),
    do: {:error, "Statechart Plugin state must be a plain map"}

  @doc "Maps one Jido Signal to one external SCXML event."
  @spec event(Jido.Signal.t(), Session.t()) :: Event.t()
  def event(%Jido.Signal{} = signal, %Session{} = session) do
    Event.new!(%{
      name: signal.type,
      class: :external,
      data: signal.data,
      message_id: signal.id,
      send_id: Jido.Signal.get_context(signal, "jidoscsendid"),
      origin: signal.source,
      origin_type: Jido.Signal.get_context(signal, "jidoscorigintype"),
      invoke_id: Jido.Signal.get_context(signal, "jidoscinvokeid"),
      turn_id: Jido.Signal.get_context(signal, "jidoscturnid"),
      session_id: session.id
    })
  end

  @doc false
  def cleanup_complete?(%Session{} = session) do
    records = Map.values(session.operations) ++ Map.values(session.operation_tombstones)

    Enum.all?(records, fn record -> cleanup_record_complete?(record, records) end)
  end

  defp cleanup_record_complete?(%{kind: :child_start, state: :canceled}, _records), do: true

  defp cleanup_record_complete?(
         %{kind: :child_start, state: :confirmed_complete} = start,
         records
       ) do
    Enum.any?(records, fn
      %{kind: :child_stop, target: target, generation: generation, state: state} ->
        target == start.target and generation >= start.generation and
          state in [:confirmed_complete, :canceled]

      _record ->
        false
    end)
  end

  defp cleanup_record_complete?(%{kind: :child_start}, _records), do: false

  defp cleanup_record_complete?(%{state: state}, _records),
    do: state in [:confirmed_complete, :canceled]

  @doc false
  def session_id(agent_id) when is_binary(agent_id),
    do: "session_" <> String.slice(Diagnostic.digest(agent_id), 0, 32)

  @doc false
  def incarnation(agent_id, signal_id) when is_binary(agent_id) and is_binary(signal_id),
    do: "inc_" <> String.slice(Diagnostic.digest({agent_id, signal_id}), 0, 32)

  defp prepare_signal(
         %Preparation{signal: signal, plugin_state: plugin_state} = preparation,
         config
       ) do
    session = plugin_state.session

    cond do
      signal.type == Agent.initialization_signal_type() and is_nil(session) ->
        with {:ok, session} <- new_session(preparation.agent_id, signal.id, config) do
          {:ok,
           %{
             kind: :macrostep,
             operation: :initialize,
             chart: config.chart,
             session: session,
             event: nil,
             limits: config.limits,
             expected_revision: nil,
             signal_id: signal.id
           }}
        end

      signal.type == Agent.initialization_signal_type() ->
        {:ok, %{kind: :reserved_rejection, reason: :statechart_session_already_initialized}}

      signal.type == Agent.cleanup_signal_type() and match?(%Session{status: :completed}, session) ->
        {:ok,
         %{
           kind: :cleanup,
           operation: :cleanup,
           session: session,
           expected_revision: session.revision,
           signal_id: signal.id
         }}

      Agent.reserved_signal?(signal.type) ->
        {:ok, %{kind: :reserved_rejection, reason: :unsupported_statechart_runtime_signal}}

      signal.id in plugin_state.recent_signal_ids ->
        {:error, {:duplicate_signal, signal.id}}

      is_nil(session) ->
        {:error, :statechart_session_not_initialized}

      session.status == :active ->
        {:ok,
         %{
           kind: :macrostep,
           operation: :run,
           chart: config.chart,
           session: session,
           event: event(signal, session),
           limits: config.limits,
           expected_revision: session.revision,
           signal_id: signal.id
         }}

      session.status in [:completed, :cleaning, :stopped] ->
        {:error, :statechart_session_completed}

      true ->
        {:error, :invalid_statechart_session_status}
    end
  end

  defp new_session(agent_id, signal_id, config) do
    versions = Session.contract_versions()

    Session.new(
      Map.merge(versions, %{
        id: session_id(agent_id),
        incarnation: incarnation(agent_id, signal_id),
        chart_fingerprint: config.chart.chart().fingerprint,
        registry_version: config.chart.registry().version,
        registry_digest: config.chart.registry().digest,
        limits_digest: Limits.digest(config.limits),
        status: :new
      })
    )
  end

  defp reduce_commits(%Reduction{plugin_state: state}, [], _config), do: {:ok, state}

  defp reduce_commits(_reduction, [_first, _second | _rest], _config),
    do: {:error, :multiple_statechart_commits}

  defp reduce_commits(%Reduction{plugin_state: state} = reduction, [%Commit{} = commit], config) do
    with {:ok, commit} <- Commit.validate(commit),
         :ok <- validate_commit_provenance(reduction, commit),
         :ok <- preserve_session_identity(state.session, reduction.prepared_input, commit.session),
         :ok <- preserve_session_fences(state.session, reduction.prepared_input, commit.session),
         :ok <- preserve_ledger(state.session, commit.session),
         {:ok, commit} <- store_intents(state.session, commit),
         :ok <- compare_and_swap(state.session, commit),
         :ok <- Session.validate_contract(commit.session, config.chart.registry(), config.limits),
         :ok <- Session.validate_limits(commit.session, config.limits),
         true <- commit.session.chart_fingerprint == config.chart.chart().fingerprint do
      recent = append_fifo(state.recent_signal_ids, commit.signal_id, config.duplicate_window)
      {:ok, %{state | session: commit.session, recent_signal_ids: recent}}
    else
      false -> {:error, :statechart_chart_fingerprint_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp compare_and_swap(nil, %Commit{expected_revision: nil, session: %Session{revision: 1}}),
    do: :ok

  defp compare_and_swap(nil, %Commit{expected_revision: expected}),
    do: {:error, {:statechart_compare_and_swap, nil, expected}}

  defp compare_and_swap(%Session{revision: current}, %Commit{expected_revision: expected})
       when current != expected,
       do: {:error, {:statechart_compare_and_swap, current, expected}}

  defp compare_and_swap(%Session{revision: current}, %Commit{session: %Session{revision: next}})
       when next != current + 1,
       do: {:error, {:statechart_revision_jump, current, next}}

  defp compare_and_swap(%Session{}, %Commit{}), do: :ok

  defp validate_commit_provenance(
         %Reduction{signal: signal, prepared_input: prepared, plugin_state: state},
         %Commit{} = commit
       )
       when is_map(prepared) do
    with true <- commit.signal_id == signal.id,
         true <- commit.signal_id == Map.get(prepared, :signal_id),
         true <- commit.expected_revision == Map.get(prepared, :expected_revision),
         true <- commit.operation == Map.get(prepared, :operation),
         true <- valid_prepared_kind?(prepared, commit.operation),
         true <- valid_signal_operation?(signal.type, commit.operation),
         true <- valid_status_transition?(state.session, commit.session, commit.operation) do
      :ok
    else
      _other -> {:error, :invalid_statechart_commit_provenance}
    end
  end

  defp validate_commit_provenance(_reduction, _commit),
    do: {:error, :invalid_statechart_commit_provenance}

  defp valid_prepared_kind?(%{kind: :macrostep}, operation),
    do: operation in [:initialize, :run]

  defp valid_prepared_kind?(%{kind: :cleanup}, :cleanup), do: true
  defp valid_prepared_kind?(_prepared, _operation), do: false

  defp valid_signal_operation?(type, :initialize), do: type == Agent.initialization_signal_type()
  defp valid_signal_operation?(type, :cleanup), do: type == Agent.cleanup_signal_type()
  defp valid_signal_operation?(type, :run), do: not Agent.reserved_signal?(type)

  defp valid_status_transition?(nil, %Session{status: status}, :initialize),
    do: status in [:active, :completed]

  defp valid_status_transition?(%Session{status: :active}, %Session{status: status}, :run),
    do: status in [:active, :completed]

  defp valid_status_transition?(
         %Session{status: :completed},
         %Session{status: :stopped},
         :cleanup
       ),
       do: true

  defp valid_status_transition?(_current, _next, _operation), do: false

  defp preserve_session_identity(current, prepared, next) do
    source = if current, do: current, else: Map.get(prepared, :session)

    case source do
      %Session{} -> immutable_fields(source, next, @immutable_session_fields, :session)
      _other -> {:error, :invalid_statechart_commit_provenance}
    end
  end

  defp immutable_fields(left, right, fields, :session) do
    case Enum.find(fields, &(Map.fetch!(left, &1) != Map.fetch!(right, &1))) do
      nil -> :ok
      field -> {:error, {:statechart_immutable_session_field, field}}
    end
  end

  defp preserve_session_fences(current, prepared, next) do
    source = if current, do: current, else: Map.get(prepared, :session)

    cond do
      not match?(%Session{}, source) ->
        {:error, :invalid_statechart_commit_provenance}

      next.revision_fence < source.revision_fence ->
        {:error, :statechart_revision_fence_regression}

      next.generated_id_counter < source.generated_id_counter ->
        {:error, :statechart_generated_id_counter_regression}

      not MapSet.subset?(
        MapSet.new(source.initialized_data_state_ids),
        MapSet.new(next.initialized_data_state_ids)
      ) ->
        {:error, :statechart_initialized_data_regression}

      true ->
        :ok
    end
  end

  defp preserve_ledger(nil, %Session{operations: operations, operation_tombstones: tombstones}) do
    if operations == %{} and tombstones == %{},
      do: :ok,
      else: {:error, :statechart_initial_ledger_not_empty}
  end

  defp preserve_ledger(%Session{} = current, %Session{} = next) do
    with :ok <- preserve_tombstones(current.operation_tombstones, next.operation_tombstones),
         :ok <- preserve_operations(current.operations, next.operations) do
      :ok
    end
  end

  defp preserve_tombstones(current, next) do
    if current == next,
      do: :ok,
      else: {:error, :statechart_operation_tombstones_changed}
  end

  defp preserve_operations(current, next) do
    current_ids = Map.keys(current) |> MapSet.new()
    next_ids = Map.keys(next) |> MapSet.new()

    cond do
      deleted = MapSet.difference(current_ids, next_ids) |> Enum.at(0) ->
        {:error, {:statechart_operation_deleted, deleted}}

      added = MapSet.difference(next_ids, current_ids) |> Enum.at(0) ->
        {:error, {:statechart_operation_added_outside_intents, added}}

      true ->
        Enum.reduce_while(current, :ok, fn {id, operation}, :ok ->
          case valid_operation_transition(operation, Map.fetch!(next, id)) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
    end
  end

  defp valid_operation_transition(current, next) do
    with :ok <- immutable_operation(current, next),
         true <- next.attempt_count >= current.attempt_count,
         true <- result_fence_advances?(current, next),
         true <- legal_operation_state?(current, next) do
      :ok
    else
      _other -> {:error, {:statechart_operation_regression, current.id}}
    end
  end

  defp immutable_operation(current, next) do
    if Enum.all?(@immutable_operation_fields, &(Map.fetch!(current, &1) == Map.fetch!(next, &1))),
      do: :ok,
      else: {:error, :immutable_operation_changed}
  end

  defp result_fence_advances?(%{result_revision: nil}, _next), do: true

  defp result_fence_advances?(
         %{result_revision: current, state: state, result: result},
         %{result_revision: next, state: next_state, result: next_result}
       ) do
    is_integer(next) and
      (next > current or (next == current and state == next_state and result == next_result))
  end

  defp legal_operation_state?(current, next) do
    cond do
      Session.Operation.terminal?(current) ->
        Session.Operation.terminal?(next) and current.state == next.state and
          Session.Operation.outcome_digest(current) == Session.Operation.outcome_digest(next)

      current.state == next.state ->
        true

      next.state == :canceled ->
        current.state == :cancel_requested

      true ->
        current.state in [:not_started, :result_unknown, :retryable_failure, :cancel_requested]
    end
  end

  defp store_intents(current, %Commit{session: session, intents: intents} = commit) do
    first_generation = if current, do: current.operation_counter, else: 0
    expected_counter = first_generation + length(intents)
    generations = Enum.map(intents, & &1.generation)

    expected_generations =
      if intents == [], do: [], else: Enum.to_list(first_generation..(expected_counter - 1))

    cond do
      session.operation_counter != expected_counter ->
        {:error, {:statechart_operation_counter, expected_counter, session.operation_counter}}

      generations != expected_generations ->
        {:error, :statechart_operation_generation_mismatch}

      Enum.any?(intents, fn intent ->
        intent.session_incarnation != session.incarnation or
          intent.created_revision != session.revision or
          intent.state != :not_started or
            Map.has_key?(session.operation_tombstones, intent.id)
      end) ->
        {:error, :invalid_statechart_operation_intent}

      true ->
        with {:ok, operations} <- merge_intents(session.operations, intents),
             {:ok, session} <- Session.new(%{session | operations: operations}) do
          {:ok, %{commit | session: session}}
        end
    end
  end

  defp merge_intents(operations, intents) do
    Enum.reduce_while(intents, {:ok, operations}, fn intent, {:ok, acc} ->
      if Map.has_key?(acc, intent.id) do
        {:halt, {:error, {:duplicate_statechart_operation, intent.id}}}
      else
        {:cont, {:ok, Map.put(acc, intent.id, intent)}}
      end
    end)
  end

  defp append_fifo(ids, id, maximum) do
    ids
    |> Kernel.++([id])
    |> Enum.take(-maximum)
  end

  defp config(opts) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: do_config(opts),
      else: {:error, :invalid_statechart_plugin_options}
  end

  defp config(_opts), do: {:error, :invalid_statechart_plugin_options}

  defp do_config(opts) do
    chart = Keyword.get(opts, :chart)
    duplicate_window = Keyword.get(opts, :duplicate_window, @default_duplicate_window)
    stop_on_done = Keyword.get(opts, :stop_on_done, false)
    rescan_interval = Keyword.get(opts, :rescan_interval, @default_rescan_interval)
    supplied_limits = Keyword.get(opts, :limits, Limits.default())

    with true <- chart_module?(chart),
         true <- is_integer(duplicate_window) and duplicate_window in 1..100_000,
         true <- is_boolean(stop_on_done),
         true <- is_integer(rescan_interval) and rescan_interval in 10..60_000,
         {:ok, limits} <-
           Limits.new(
             if(is_struct(supplied_limits),
               do: Map.from_struct(supplied_limits),
               else: supplied_limits
             )
           ) do
      {:ok,
       %{
         chart: chart,
         duplicate_window: duplicate_window,
         stop_on_done: stop_on_done,
         rescan_interval: rescan_interval,
         limits: limits
       }}
    else
      _other -> {:error, :invalid_statechart_plugin_options}
    end
  end

  defp chart_module?(module) when is_atom(module) and not is_nil(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :chart, 0) and
      function_exported?(module, :registry, 0)
  end

  defp chart_module?(_module), do: false
end
