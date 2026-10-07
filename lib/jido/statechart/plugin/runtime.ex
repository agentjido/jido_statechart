defmodule Jido.Statechart.Plugin.Runtime do
  @moduledoc false
  use GenServer

  alias Jido.AgentServer.Plugin.{Admission, Commit}
  alias Jido.Plugin.Init
  alias Jido.Statechart.Agent
  alias Jido.Statechart.Runtime.{Reconciler, Server, Timer}
  alias Jido.Statechart.{Diagnostic, Plugin, Session}

  @proof "jidoscproof"
  @epoch "jidoscepoch"
  @operation "jidoscop"
  @generation "jidoscgen"
  @payload_digest "jidoscdigest"
  @default_rescan_interval 1_000

  def start_link(%Init{} = init) do
    GenServer.start_link(__MODULE__, init, name: runtime_name(init.agent_server))
  end

  @doc false
  def child_spec(%Init{} = init) do
    %{
      id: Jido.Statechart.Plugin,
      start: {__MODULE__, :start_link, [init]},
      restart: :permanent,
      type: :worker
    }
  end

  @doc false
  def await_ready(runtime, opts) do
    GenServer.call(runtime, :await_ready, Keyword.get(opts, :runtime_timeout, 5_000))
  catch
    :exit, reason -> {:error, {:statechart_runtime_unavailable, reason}}
  end

  @doc false
  def after_commit(runtime, %Commit{}, _opts) do
    GenServer.cast(runtime, :rescan)
    :ok
  end

  @doc false
  def initialization_signal(server) do
    with {:ok, runtime} <- lookup(server),
         signal <-
           Jido.Signal.new!(Agent.initialization_signal_type(), %{},
             source: "/jido/statechart/runtime"
           ) do
      GenServer.call(runtime, {:sign, signal, "initialize", 0})
    end
  catch
    :exit, reason -> {:error, {:statechart_runtime_unavailable, reason}}
  end

  @doc false
  def rotate(server) do
    with {:ok, runtime} <- lookup(server), do: GenServer.call(runtime, :rotate)
  catch
    :exit, reason -> {:error, {:statechart_runtime_unavailable, reason}}
  end

  @doc false
  def verify(runtime, %Admission{} = admission) do
    GenServer.call(runtime, {:verify, admission})
  catch
    :exit, _reason -> {:error, :invalid_runtime_proof}
  end

  @impl true
  def init(%Init{} = init) do
    Process.flag(:trap_exit, true)
    {:ok, attempts_supervisor} = Task.Supervisor.start_link()

    {:ok,
     %{
       agent_server: init.agent_server,
       agent_id: init.agent_id,
       init: init,
       options: options(init.options),
       secret: :crypto.strong_rand_bytes(32),
       epoch: random_epoch(),
       attempts_supervisor: attempts_supervisor,
       cleanup_request: nil,
       attempts: %{},
       timers: %{},
       turn_times: [],
       rescan_timer: nil
     }}
  end

  @impl true
  def handle_call(:await_ready, _from, state) do
    state = state |> reconcile(state.init.plugin_state) |> wake_rescan()
    {:reply, :ok, state}
  end

  def handle_call(:rotate, _from, state) do
    state = stop_all_owned_attempts(state)
    {:reply, :ok, %{state | secret: :crypto.strong_rand_bytes(32), epoch: random_epoch()}}
  end

  def handle_call({:sign, signal, operation, generation}, _from, state) do
    case reserve_turn(state) do
      {:ok, state} -> {:reply, sign(signal, operation, generation, state), state}
      {:error, state} -> {:reply, {:error, :runtime_turn_rate_limited}, state}
    end
  end

  def handle_call({:verify, admission}, _from, state) do
    {:reply, verify_admission(admission, state), state}
  end

  @impl true
  def handle_cast(:rescan, state), do: {:noreply, wake_rescan(state)}

  @impl true
  def handle_info(:rescan, state) do
    state = %{state | rescan_timer: nil}

    state =
      case Jido.Plugin.state(state.init, state.options.rescan_timeout) do
        {:ok, plugin_state} -> reconcile(state, plugin_state)
        {:error, _reason} -> state
      end

    {:noreply, schedule_rescan(state)}
  end

  def handle_info({:timer_due, operation_id, generation, token}, state) do
    state =
      case Map.get(state.timers, operation_id) do
        %{generation: ^generation, token: ^token} ->
          %{state | timers: Map.delete(state.timers, operation_id)} |> wake_rescan()

        _stale ->
          state
      end

    {:noreply, state}
  end

  def handle_info(
        {:delivery_result, epoch, task_pid, operation, result_state, result},
        state
      ) do
    projection = Map.get(state.attempts, operation.id)

    if match?(
         %{
           status: :running,
           epoch: ^epoch,
           pid: ^task_pid,
           attempt_count: attempt_count
         }
         when attempt_count == operation.attempt_count,
         projection
       ) and epoch == state.epoch do
      Process.demonitor(projection.monitor, [:flush])
      state = %{state | attempts: Map.delete(state.attempts, operation.id)}
      finish_delivery_result(state, operation, result_state, result)
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    attempts =
      Map.reject(state.attempts, fn {_id, projection} ->
        projection.status == :running and Map.get(projection, :monitor) == monitor
      end)

    state = %{state | attempts: attempts}
    {:noreply, wake_rescan(state)}
  end

  def handle_info({:EXIT, pid, reason}, %{attempts_supervisor: pid} = state),
    do: {:stop, {:attempt_supervisor_exit, reason}, state}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  defp finish_delivery_result(state, operation, result_state, result) do
    data = %{
      "attempt" => operation.attempt_count,
      "generation" => operation.generation,
      "operation_id" => operation.id,
      "result" => result,
      "state" => Atom.to_string(result_state)
    }

    signal =
      Jido.Signal.new!(Agent.delivery_signal_type(), data,
        id: runtime_signal_id("result", operation.id, operation.attempt_count, result),
        source: "/jido/statechart/runtime"
      )

    state =
      case sign(signal, operation.id, operation.generation, state, operation.session_incarnation) do
        {:ok, signal} ->
          attempts =
            Map.put(state.attempts, operation.id, %{
              attempt_count: operation.attempt_count,
              signal: signal,
              status: :result_pending
            })

          %{state | attempts: attempts}
          |> maybe_send_result(operation.id)

        {:error, _reason} ->
          %{state | attempts: Map.delete(state.attempts, operation.id)}
      end

    {:noreply, wake_rescan(state)}
  end

  defp maybe_cleanup(state, %{session: %Session{status: :completed} = session}) do
    if state.options.stop_on_done do
      cond do
        not Plugin.cleanup_complete?(session) ->
          state

        true ->
          case cleanup_request(state, session) do
            {:ok, signal, state} ->
              maybe_send_cleanup(state, signal)

            {:error, _reason} ->
              state
          end
      end
    else
      state
    end
  end

  defp maybe_cleanup(state, %{session: %Session{}}), do: %{state | cleanup_request: nil}
  defp maybe_cleanup(state, _plugin_state), do: state

  defp reconcile(state, %{session: %Session{} = session} = plugin_state) do
    now = DateTime.utc_now()
    state = prune_projection(state, session)
    state = sync_timers(state, session, now)

    state =
      session
      |> Reconciler.plan(now, state.options.limits)
      |> Enum.reduce(state, fn action, current -> execute_action(current, session, action) end)

    maybe_cleanup(state, plugin_state)
  end

  defp reconcile(state, plugin_state), do: maybe_cleanup(state, plugin_state)

  defp execute_action(state, session, {:schedule, operation}) do
    data = %{
      "action" => "schedule",
      "attempt" => operation.attempt_count + 1,
      "generation" => operation.generation,
      "operation_id" => operation.id,
      "session_revision" => session.revision
    }

    cast_control(state, session, operation, data, "schedule")
  end

  defp execute_action(state, session, {:cancel_replaced, operation, replacement}) do
    data = %{
      "action" => "cancel_replaced",
      "generation" => operation.generation,
      "operation_id" => operation.id,
      "replacement_operation_id" => replacement.id,
      "target_operation_id" => operation.id
    }

    cast_control(state, session, operation, data, "cancel-replaced")
  end

  defp execute_action(state, session, {:cancel_stale, operation, high_water}) do
    data = %{
      "action" => "cancel_stale",
      "generation" => operation.generation,
      "high_water_generation" => high_water,
      "operation_id" => operation.id,
      "target_operation_id" => operation.id
    }

    cast_control(state, session, operation, data, "cancel-stale")
  end

  defp execute_action(state, session, {:cancel, operation, target}) do
    data = %{
      "action" => "cancel",
      "generation" => operation.generation,
      "operation_id" => operation.id,
      "target_operation_id" => target && target.id
    }

    cast_control(state, session, operation, data, "cancel")
  end

  defp execute_action(state, session, {:confirm_cancel, operation}) do
    state = stop_owned_attempt(state, operation.id)

    data = %{
      "action" => "confirm_cancel",
      "generation" => operation.generation,
      "operation_id" => operation.id,
      "target_operation_id" => operation.id
    }

    cast_control(state, session, operation, data, "confirm-cancel")
  end

  defp execute_action(state, session, {:complete_cancel, operation}) do
    data = %{
      "action" => "complete_cancel",
      "generation" => operation.generation,
      "operation_id" => operation.id,
      "target_operation_id" => operation.id
    }

    cast_control(state, session, operation, data, "complete-cancel")
  end

  defp execute_action(state, session, {:dispatch, operation}) do
    case Map.get(state.attempts, operation.id) do
      %{attempt_count: attempt, status: :running} when attempt == operation.attempt_count ->
        state

      %{attempt_count: attempt, status: status}
      when attempt == operation.attempt_count and status in [:result_pending, :result_sent] ->
        maybe_send_result(state, operation.id)

      _other ->
        if running_attempts(state) < state.options.limits.runtime_concurrency do
          case reserve_turn(state) do
            {:ok, state} -> start_dispatch(state, session, operation)
            {:error, state} -> state
          end
        else
          state
        end
    end
  end

  defp cast_control(state, session, operation, data, kind) do
    signal =
      Jido.Signal.new!(Agent.reconciliation_signal_type(), data,
        id: runtime_signal_id(kind, operation.id, operation.attempt_count, data),
        source: "/jido/statechart/runtime"
      )

    case reserve_turn(state) do
      {:ok, state} ->
        case sign(signal, operation.id, operation.generation, state, session.incarnation) do
          {:ok, signal} ->
            Jido.AgentServer.cast(state.agent_server, signal)
            state

          {:error, _reason} ->
            state
        end

      {:error, state} ->
        state
    end
  end

  defp start_dispatch(state, session, operation) do
    runtime = self()
    epoch = state.epoch
    registry = state.options.chart.registry()
    context = runtime_context(state, session, operation)

    options = [
      retry_limit: state.options.retry_limit,
      retry_backoff_ms: state.options.retry_backoff_ms
    ]

    {:ok, pid} =
      Task.Supervisor.start_child(
        state.attempts_supervisor,
        fn ->
          task_pid = self()
          {result_state, result} = Server.dispatch(operation, session, registry, context, options)

          send(
            runtime,
            {:delivery_result, epoch, task_pid, operation, result_state, result}
          )
        end
      )

    monitor = Process.monitor(pid)

    attempts =
      Map.put(state.attempts, operation.id, %{
        attempt_count: operation.attempt_count,
        epoch: epoch,
        generation: operation.generation,
        monitor: monitor,
        pid: pid,
        status: :running
      })

    %{state | attempts: attempts}
  end

  defp maybe_send_result(state, operation_id) do
    projection = Map.fetch!(state.attempts, operation_id)
    now = System.monotonic_time(:millisecond)
    minimum_retry = max(state.options.rescan_interval * 2, 50)

    if projection.status == :result_sent and now - projection.sent_at < minimum_retry do
      state
    else
      case reserve_turn(state) do
        {:ok, state} ->
          Jido.AgentServer.cast(state.agent_server, projection.signal)

          projection = %{projection | status: :result_sent} |> Map.put(:sent_at, now)
          %{state | attempts: Map.put(state.attempts, operation_id, projection)}

        {:error, state} ->
          state
      end
    end
  end

  defp prune_projection(state, session) do
    attempts =
      Map.filter(state.attempts, fn {id, projection} ->
        case Map.get(session.operations, id) do
          %{state: :result_unknown, attempt_count: attempt} ->
            attempt == projection.attempt_count

          _other ->
            false
        end
      end)

    %{state | attempts: attempts}
  end

  defp sync_timers(state, session, now) do
    wanted =
      session.operations
      |> Map.values()
      |> Enum.filter(fn operation ->
        operation.kind == :timer and operation.state in [:not_started, :retryable_failure] and
          not Timer.due?(operation.next_attempt_at || operation.due_at, now)
      end)
      |> Map.new(&{&1.id, &1})

    timers =
      Enum.reduce(state.timers, %{}, fn {id, timer}, acc ->
        case Map.get(wanted, id) do
          %{generation: generation} when generation == timer.generation ->
            Map.put(acc, id, timer)

          _other ->
            Process.cancel_timer(timer.ref)
            acc
        end
      end)

    timers =
      Enum.reduce(wanted, timers, fn {id, operation}, acc ->
        if Map.has_key?(acc, id) do
          acc
        else
          token = make_ref()
          due_at = operation.next_attempt_at || operation.due_at

          case Timer.milliseconds_until(due_at, now) do
            {:ok, delay} ->
              ref =
                Process.send_after(self(), {:timer_due, id, operation.generation, token}, delay)

              Map.put(acc, id, %{
                generation: operation.generation,
                token: token,
                ref: ref,
                due_at: due_at
              })

            {:error, _diagnostic} ->
              acc
          end
        end
      end)

    %{state | timers: timers}
  end

  defp running_attempts(state),
    do: Enum.count(state.attempts, fn {_id, value} -> value.status == :running end)

  defp reserve_turn(state) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - 60_000
    recent = Enum.filter(state.turn_times, &(&1 > cutoff))

    if length(recent) < state.options.limits.runtime_turns_per_minute do
      {:ok, %{state | turn_times: [now | recent]}}
    else
      {:error, %{state | turn_times: recent}}
    end
  end

  defp runtime_context(state, session, operation) do
    %{
      agent_id: state.agent_id,
      agent_server: state.agent_server,
      jido: state.init.jido,
      partition: state.init.partition,
      runtime_signer: fn signal ->
        sign(signal, operation.id, operation.generation, state, session.incarnation)
      end
    }
  end

  defp stop_owned_attempt(state, operation_id) do
    case Map.get(state.attempts, operation_id) do
      %{status: :running, pid: pid, monitor: monitor, epoch: epoch} when epoch == state.epoch ->
        _result = Task.Supervisor.terminate_child(state.attempts_supervisor, pid)
        Process.demonitor(monitor, [:flush])
        %{state | attempts: Map.delete(state.attempts, operation_id)}

      _other ->
        %{state | attempts: Map.delete(state.attempts, operation_id)}
    end
  end

  defp stop_all_owned_attempts(state) do
    Enum.reduce(Map.keys(state.attempts), state, &stop_owned_attempt(&2, &1))
  end

  defp cleanup_request(
         %{cleanup_request: %{revision: revision, incarnation: incarnation, signal: signal}} =
           state,
         %Session{revision: revision, incarnation: incarnation}
       ),
       do: {:ok, signal, state}

  defp cleanup_request(state, session) do
    signal =
      Jido.Signal.new!(
        Agent.cleanup_signal_type(),
        %{"session_id" => session.id, "session_revision" => session.revision},
        source: "/jido/statechart/runtime"
      )

    with {:ok, signal} <- sign(signal, "cleanup", session.revision, state, session.incarnation) do
      request = %{revision: session.revision, incarnation: session.incarnation, signal: signal}
      {:ok, signal, %{state | cleanup_request: request}}
    end
  end

  defp maybe_send_cleanup(state, signal) do
    now = System.monotonic_time(:millisecond)
    request = state.cleanup_request
    minimum_retry = max(state.options.rescan_interval * 2, 50)

    if is_integer(Map.get(request, :sent_at)) and now - request.sent_at < minimum_retry do
      state
    else
      case reserve_turn(state) do
        {:ok, state} ->
          Jido.AgentServer.cast(state.agent_server, signal)
          %{state | cleanup_request: Map.put(request, :sent_at, now)}

        {:error, state} ->
          state
      end
    end
  end

  defp wake_rescan(%{rescan_timer: :queued} = state), do: state

  defp wake_rescan(state) do
    if is_reference(state.rescan_timer), do: Process.cancel_timer(state.rescan_timer)
    send(self(), :rescan)
    %{state | rescan_timer: :queued}
  end

  defp schedule_rescan(%{rescan_timer: nil} = state) do
    timer = Process.send_after(self(), :rescan, state.options.rescan_interval)
    %{state | rescan_timer: timer}
  end

  defp schedule_rescan(state), do: state

  defp sign(signal, operation, generation, state, incarnation \\ nil)

  defp sign(%Jido.Signal{} = signal, operation, generation, state, supplied_incarnation) do
    payload_digest = Diagnostic.digest(signal.data)

    with {:ok, incarnation} <- signing_incarnation(signal, state.agent_id, supplied_incarnation),
         proof <- proof(state, incarnation, operation, generation, signal, payload_digest),
         {:ok, signal} <- Jido.Signal.put_context(signal, @epoch, state.epoch),
         {:ok, signal} <- Jido.Signal.put_context(signal, @operation, operation),
         {:ok, signal} <- Jido.Signal.put_context(signal, @generation, generation),
         {:ok, signal} <- Jido.Signal.put_context(signal, @payload_digest, payload_digest),
         {:ok, signal} <- Jido.Signal.put_context(signal, @proof, proof) do
      {:ok, signal}
    end
  end

  defp signing_incarnation(_signal, _agent_id, incarnation) when is_binary(incarnation),
    do: {:ok, incarnation}

  defp signing_incarnation(signal, agent_id, nil), do: incarnation(signal, agent_id, nil)

  defp verify_admission(
         %Admission{agent_id: agent_id, signal: signal, plugin_state: plugin_state},
         state
       )
       when agent_id == state.agent_id do
    operation = Jido.Signal.get_context(signal, @operation)
    generation = Jido.Signal.get_context(signal, @generation)
    payload_digest = Diagnostic.digest(signal.data)

    with true <- Jido.Signal.get_context(signal, @epoch) == state.epoch,
         true <- Jido.Signal.get_context(signal, @payload_digest) == payload_digest,
         true <- valid_reserved_coordinates(signal, operation, generation, plugin_state),
         {:ok, incarnation} <- incarnation(signal, agent_id, plugin_state),
         expected <- proof(state, incarnation, operation, generation, signal, payload_digest),
         supplied when is_binary(supplied) <- Jido.Signal.get_context(signal, @proof),
         true <- secure_equal?(expected, supplied) do
      :ok
    else
      _other -> {:error, :invalid_runtime_proof}
    end
  end

  defp verify_admission(_admission, _state), do: {:error, :invalid_runtime_proof}

  defp valid_reserved_coordinates(signal, "initialize", 0, %{session: nil}),
    do: signal.type == Agent.initialization_signal_type()

  defp valid_reserved_coordinates(
         signal,
         "cleanup",
         generation,
         %{session: %Session{status: :completed, revision: generation} = session}
       ) do
    signal.type == Agent.cleanup_signal_type() and
      signal.data == %{"session_id" => session.id, "session_revision" => session.revision} and
      Plugin.cleanup_complete?(session)
  end

  defp valid_reserved_coordinates(
         signal,
         operation_id,
         generation,
         %{session: %Session{} = session}
       ) do
    with %Session.Operation{generation: ^generation} = operation <-
           Map.get(session.operations, operation_id),
         true <- operation.session_incarnation == session.incarnation do
      cond do
        signal.type == operation.correlation["event"] and
          operation.state == :result_unknown and operation.kind in [:send, :timer] and
            operation.target in ["self", "#_self"] ->
          signal.id == operation.id and signal.data == operation.correlation["data"] and
            Jido.Signal.get_context(signal, "jidoscsessionid") == session.id

        signal.type == Agent.reconciliation_signal_type() ->
          runtime_coordinates?(signal, operation_id, generation) and
            signal.data["action"] in [
              "schedule",
              "cancel",
              "cancel_replaced",
              "cancel_stale",
              "confirm_cancel",
              "complete_cancel"
            ]

        signal.type == Agent.delivery_signal_type() ->
          runtime_coordinates?(signal, operation_id, generation) and
            signal.data["attempt"] == operation.attempt_count and
            signal.data["state"] in [
              "confirmed_complete",
              "result_unknown",
              "retryable_failure",
              "permanent_failure"
            ]

        true ->
          false
      end
    else
      _other -> false
    end
  end

  defp valid_reserved_coordinates(_signal, _operation, _generation, _plugin_state), do: false

  defp runtime_coordinates?(signal, operation_id, generation),
    do:
      is_map(signal.data) and signal.data["operation_id"] == operation_id and
        signal.data["generation"] == generation

  defp incarnation(signal, agent_id, nil) do
    if signal.type == Agent.initialization_signal_type(),
      do: {:ok, Plugin.incarnation(agent_id, signal.id)},
      else: {:error, :session_required}
  end

  defp incarnation(signal, agent_id, %{session: nil}), do: incarnation(signal, agent_id, nil)

  defp incarnation(_signal, _agent_id, %{session: %Session{incarnation: incarnation}}),
    do: {:ok, incarnation}

  defp incarnation(_signal, _agent_id, _plugin_state), do: {:error, :invalid_session}

  defp proof(state, incarnation, operation, generation, signal, payload_digest) do
    payload =
      :erlang.term_to_binary(
        {
          :jido_statechart_runtime_proof,
          1,
          state.agent_id,
          incarnation,
          operation,
          generation,
          signal.type,
          payload_digest,
          state.epoch
        },
        [:deterministic]
      )

    :crypto.mac(:hmac, :sha256, state.secret, payload)
    |> Base.url_encode64(padding: false)
  end

  defp secure_equal?(left, right) when byte_size(left) == byte_size(right) do
    :crypto.hash_equals(left, right)
  end

  defp secure_equal?(_left, _right), do: false

  defp lookup(server) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) ->
        case GenServer.whereis(runtime_name(pid)) do
          runtime when is_pid(runtime) -> {:ok, runtime}
          _other -> {:error, :statechart_runtime_not_found}
        end

      _other ->
        {:error, :statechart_agent_not_found}
    end
  end

  defp runtime_name(agent_server), do: {:global, {__MODULE__, agent_server}}

  defp random_epoch,
    do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp options(opts) do
    interval = Keyword.get(opts, :rescan_interval, @default_rescan_interval)
    supplied_limits = Keyword.get(opts, :limits, Jido.Statechart.Limits.default())

    limits =
      if is_struct(supplied_limits, Jido.Statechart.Limits) do
        supplied_limits
      else
        Jido.Statechart.Limits.new!(supplied_limits)
      end

    %{
      stop_on_done: Keyword.get(opts, :stop_on_done, false),
      chart: Keyword.get(opts, :chart),
      limits: limits,
      retry_limit: Keyword.get(opts, :retry_limit, 3),
      retry_backoff_ms: Keyword.get(opts, :retry_backoff_ms, 100),
      rescan_interval: interval,
      rescan_timeout: min(interval, 1_000)
    }
  end

  defp runtime_signal_id(kind, operation_id, attempt, data) do
    digest = Diagnostic.digest({kind, operation_id, attempt, data})
    "statechart-runtime-" <> String.slice(digest, 0, 32)
  end
end
