defmodule Jido.Statechart.Plugin.Runtime do
  @moduledoc false
  use GenServer

  alias Jido.AgentServer.Plugin.{Admission, Commit}
  alias Jido.Plugin.Init
  alias Jido.Statechart.Agent
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
    {:ok,
     %{
       agent_server: init.agent_server,
       agent_id: init.agent_id,
       init: init,
       options: options(init.options),
       secret: :crypto.strong_rand_bytes(32),
       epoch: random_epoch(),
       cleanup_request: nil,
       rescan_timer: nil
     }}
  end

  @impl true
  def handle_call(:await_ready, _from, state) do
    state = state |> maybe_cleanup(state.init.plugin_state) |> wake_rescan()
    {:reply, :ok, state}
  end

  def handle_call(:rotate, _from, state) do
    {:reply, :ok, %{state | secret: :crypto.strong_rand_bytes(32), epoch: random_epoch()}}
  end

  def handle_call({:sign, signal, operation, generation}, _from, state) do
    {:reply, sign(signal, operation, generation, state), state}
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
        {:ok, plugin_state} -> maybe_cleanup(state, plugin_state)
        {:error, _reason} -> state
      end

    {:noreply, schedule_rescan(state)}
  end

  defp maybe_cleanup(state, %{session: %Session{status: :completed} = session}) do
    if state.options.stop_on_done do
      cond do
        not Plugin.cleanup_complete?(session) ->
          state

        true ->
          case cleanup_request(state, session) do
            {:ok, signal, state} ->
              Jido.AgentServer.cast(state.agent_server, signal)
              state

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

  defp valid_reserved_coordinates(_signal, _operation, _generation, _plugin_state), do: false

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

    %{
      stop_on_done: Keyword.get(opts, :stop_on_done, false),
      rescan_interval: interval,
      rescan_timeout: min(interval, 1_000)
    }
  end
end
