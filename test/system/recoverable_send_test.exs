defmodule Jido.Statechart.RecoverableSendTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Jido.AgentServer
  alias Jido.Statechart.Agent.Extension
  alias Jido.Statechart.Plugin.Runtime
  alias Jido.Statechart.{Agent, Chart, Plugin, Registry, SemanticFixture}

  defmodule SelfChart do
    @chart SemanticFixture.chart("""
           <state id="root">
             <transition event="emit">
               <send event="notice" target="#_self" id="work"/>
             </transition>
             <transition event="notice" target="done"/>
           </state>
           <final id="done"/>
           """)
    @registry SemanticFixture.registry()
    use Chart, chart: @chart, registry: @registry
  end

  defmodule SelfAgent do
    use Jido.Agent,
      name: "statechart_recoverable_self_agent",
      extensions: [Extension]

    agent do
      plugin(Plugin, config: [rescan_interval: 10])
    end

    routes do
      route("emit", statechart: SelfChart)
    end
  end

  defmodule TimerChart do
    @chart SemanticFixture.chart("""
           <state id="root">
             <transition event="schedule">
               <send event="notice" target="#_self" id="shared" delay="300ms"/>
             </transition>
             <transition event="cancel">
               <cancel sendid="shared"/>
             </transition>
             <transition event="notice" target="done"/>
           </state>
           <final id="done"/>
           """)
    @registry SemanticFixture.registry()
    use Chart, chart: @chart, registry: @registry
  end

  defmodule TimerAgent do
    use Jido.Agent,
      name: "statechart_recoverable_timer_agent",
      extensions: [Extension]

    agent do
      plugin(Plugin, config: [rescan_interval: 10])
    end

    routes do
      route("schedule", statechart: TimerChart)
    end
  end

  defmodule FailureChart do
    @chart SemanticFixture.chart("""
           <state id="root">
             <transition event="emit">
               <send event="notice" target="#_parent" id="work"/>
             </transition>
             <transition event="error.communication" target="done"/>
           </state>
           <final id="done"/>
           """)

    @registry Registry.new!(%{
                version: "parent-target-1",
                entries: [
                  %{
                    kind: :target,
                    alias: "parent",
                    permissions: [
                      "delivery:at_least_once",
                      "idempotency:operation_id",
                      "send:event"
                    ],
                    metadata: %{
                      "allowed_signal_types" => ["notice"],
                      "scope" => "local_agent"
                    },
                    handler: Jido.Statechart.RecoverableSendTest.PermanentAdapter
                  }
                ]
              })
    use Chart, chart: @chart, registry: @registry
  end

  defmodule PermanentAdapter do
    def idempotency, do: :operation_id
    def deliver(_signal, _operation_id, _context), do: {:error, {:permanent, :unavailable}}
  end

  defmodule FailureAgent do
    use Jido.Agent,
      name: "statechart_recoverable_failure_agent",
      extensions: [Extension]

    agent do
      plugin(Plugin, config: [rescan_interval: 10])
    end

    routes do
      route("emit", statechart: FailureChart)
    end
  end

  defmodule RetryAdapter do
    def idempotency, do: :operation_id
    def deliver(_signal, _operation_id, _context), do: {:error, {:retryable, :unavailable}}
  end

  defmodule RetryChart do
    @chart SemanticFixture.chart("""
           <state id="root">
             <transition event="emit">
               <send event="notice" target="agent:retry" id="work"/>
             </transition>
           </state>
           """)

    @registry Registry.new!(%{
                version: "retry-targets-1",
                entries: [
                  %{
                    kind: :target,
                    alias: "retry",
                    permissions: [
                      "delivery:at_least_once",
                      "idempotency:operation_id",
                      "send:event"
                    ],
                    metadata: %{
                      "allowed_signal_types" => ["notice"],
                      "scope" => "local_agent"
                    },
                    handler: RetryAdapter
                  }
                ]
              })

    use Chart, chart: @chart, registry: @registry
  end

  defmodule RetryAgent do
    use Jido.Agent,
      name: "statechart_recoverable_retry_agent",
      extensions: [Extension]

    agent do
      plugin(Plugin,
        config: [rescan_interval: 10, retry_limit: 2, retry_backoff_ms: 10]
      )
    end

    routes do
      route("emit", statechart: RetryChart)
    end
  end

  defmodule BlockingAdapter do
    def idempotency, do: :operation_id

    def deliver(_signal, operation_id, _context) do
      case :persistent_term.get({__MODULE__, :observer}, nil) do
        pid when is_pid(pid) -> send(pid, {:delivery_started, self(), operation_id})
        _other -> :ok
      end

      receive do
        :release -> :ok
      after
        10_000 -> {:error, {:uncertain, :blocked}}
      end
    end
  end

  defmodule BlockingChart do
    @chart SemanticFixture.chart("""
           <state id="root">
             <transition event="emit">
               <send event="notice" target="agent:blocking" id="work"/>
             </transition>
           </state>
           """)

    @registry Registry.new!(%{
                version: "blocking-target-1",
                entries: [
                  %{
                    kind: :target,
                    alias: "blocking",
                    permissions: [
                      "delivery:at_least_once",
                      "idempotency:operation_id",
                      "send:event"
                    ],
                    metadata: %{
                      "allowed_signal_types" => ["notice"],
                      "scope" => "local_agent"
                    },
                    handler: Jido.Statechart.RecoverableSendTest.BlockingAdapter
                  }
                ]
              })

    use Chart, chart: @chart, registry: @registry
  end

  defmodule BlockingAgent do
    use Jido.Agent,
      name: "statechart_recoverable_blocking_agent",
      extensions: [Extension]

    agent do
      plugin(Plugin, config: [rescan_interval: 10])
    end

    routes do
      route("emit", statechart: BlockingChart)
    end
  end

  setup do
    jido = String.to_atom("recoverable_send_jido_#{System.unique_integer([:positive])}")
    namespace = "statechart/recoverable/#{System.unique_integer([:positive])}"
    start_supervised!({Jido, name: jido, namespace: namespace})
    {:ok, jido: jido}
  end

  test "runtime owner death terminates its supervised in-flight delivery", %{jido: jido} do
    :persistent_term.put({BlockingAdapter, :observer}, self())
    on_exit(fn -> :persistent_term.erase({BlockingAdapter, :observer}) end)

    {:ok, server} = Jido.start_agent(jido, BlockingAgent, id: "owner-death")
    assert {:ok, _agent} = Agent.initialize(server)
    assert {:ok, _committed} = call(server, "emit", "emit-blocking")

    assert_receive {:delivery_started, task, operation_id}, 2_000
    assert is_binary(operation_id)
    task_monitor = Process.monitor(task)

    runtime = :global.whereis_name({Runtime, server})
    assert is_pid(runtime)
    Process.exit(runtime, :kill)

    assert_receive {:DOWN, ^task_monitor, :process, ^task, _reason}, 2_000
    refute Process.alive?(task)

    assert_receive {:delivery_started, replacement_task, ^operation_id}, 2_000
    assert replacement_task != task
    send(replacement_task, :release)
  end

  test "commits an immediate self-send before delivery and records its later result", %{
    jido: jido
  } do
    {:ok, server} = Jido.start_agent(jido, SelfAgent, id: "self-send")
    assert {:ok, _agent} = Agent.initialize(server)

    assert {:ok, committed} = call(server, "emit", "emit-self")
    [intent] = Map.values(committed.state.statechart.session.operations)
    assert intent.state == :not_started
    assert intent.attempt_count == 0

    assert :ok =
             eventually(fn ->
               current = session(server)
               operation = Map.get(records(current), intent.id)
               current.status == :completed and operation.state == :confirmed_complete
             end)

    operation = Map.fetch!(records(session(server)), intent.id)
    assert operation.id == intent.id
    assert operation.state == :confirmed_complete
  end

  test "a replacement runtime finds committed work after the wake hook is lost", %{jido: jido} do
    {:ok, server} = Jido.start_agent(jido, SelfAgent, id: "lost-wake")
    assert {:ok, _agent} = Agent.initialize(server)

    capture_log(fn ->
      runtime = :global.whereis_name({Runtime, server})
      assert is_pid(runtime)
      :ok = :sys.suspend(runtime)

      assert {:ok, committed} = call(server, "emit", "emit-lost-wake")
      [intent] = Map.values(committed.state.statechart.session.operations)
      assert intent.state == :not_started

      Process.exit(runtime, :kill)

      assert :ok =
               eventually(fn ->
                 current = session(server)
                 operation = Map.get(records(current), intent.id)
                 current.status == :completed and operation.state == :confirmed_complete
               end)

      operation = Map.fetch!(records(session(server)), intent.id)
      assert operation.id == intent.id
      assert operation.state == :confirmed_complete
    end)
  end

  test "replacement and cancellation fence delayed delivery", %{jido: jido} do
    {:ok, replace_server} = Jido.start_agent(jido, TimerAgent, id: "replace-timer")
    assert {:ok, _agent} = Agent.initialize(replace_server)
    assert {:ok, first} = call(replace_server, "schedule", "schedule-replace")
    [old] = Map.values(first.state.statechart.session.operations)
    assert {:ok, _second} = call(replace_server, "schedule", "replace-send")

    assert :ok =
             eventually(fn ->
               current = session(replace_server)

               current.status == :completed and
                 Enum.any?(Map.values(records(current)), &(&1.state == :confirmed_complete))
             end)

    replace_operations = Map.values(records(session(replace_server)))
    assert %{state: :canceled} = Enum.find(replace_operations, &(&1.id == old.id))

    assert %{state: :confirmed_complete, generation: generation} =
             Enum.find(replace_operations, &(&1.key == old.key and &1.id != old.id))

    assert generation > old.generation

    {:ok, cancel_server} = Jido.start_agent(jido, TimerAgent, id: "cancel-timer")
    assert {:ok, _agent} = Agent.initialize(cancel_server)
    assert {:ok, scheduled} = call(cancel_server, "schedule", "schedule-cancel")
    [scheduled_operation] = Map.values(scheduled.state.statechart.session.operations)
    assert {:ok, _canceled} = call(cancel_server, "cancel", "cancel-send")

    assert :ok =
             eventually(fn ->
               operations = Map.values(records(session(cancel_server)))

               Enum.count(operations, &(&1.state == :canceled)) == 1 and
                 Enum.count(operations, &(&1.state == :confirmed_complete)) == 1
             end)

    Process.sleep(350)
    cancel_session = session(cancel_server)
    assert cancel_session.status == :active
    assert cancel_session.configuration == ["root"]

    assert %{state: :canceled} =
             Map.fetch!(records(cancel_session), scheduled_operation.id)
  end

  test "a post-commit failure is a later Turn and does not roll back the intent", %{jido: jido} do
    {:ok, server} = Jido.start_agent(jido, FailureAgent, id: "later-failure")
    assert {:ok, _agent} = Agent.initialize(server)

    assert {:ok, committed} = call(server, "emit", "emit-failure")
    [intent] = Map.values(committed.state.statechart.session.operations)
    assert intent.state == :not_started
    assert committed.state.statechart.session.revision == 2

    assert :ok =
             eventually(fn ->
               current = session(server)
               operation = Map.get(records(current), intent.id)
               current.status == :completed and operation.state == :permanent_failure
             end)

    failed = session(server)
    operation = Map.fetch!(records(failed), intent.id)
    assert operation.id == intent.id
    assert failed.revision >= 4
    assert failed.internal_queue == []
  end

  test "durable retry uses the same operation ID, count, limit, and backoff", %{jido: jido} do
    {:ok, server} = Jido.start_agent(jido, RetryAgent, id: "retry-send")
    assert {:ok, _agent} = Agent.initialize(server)

    assert {:ok, committed} = call(server, "emit", "emit-retry")
    [intent] = Map.values(committed.state.statechart.session.operations)

    assert :ok =
             eventually(fn ->
               [operation] = Map.values(records(session(server)))
               operation.state == :permanent_failure
             end)

    [operation] = Map.values(records(session(server)))
    assert operation.id == intent.id
  end

  defp call(server, type, id) do
    signal = Jido.Signal.new!(type, %{}, id: id, source: "/test")
    AgentServer.call(server, signal)
  end

  defp session(server) do
    {:ok, %{session: session}} = AgentServer.plugin_state(server, Plugin)
    session
  end

  defp records(session),
    do: Map.merge(session.operation_tombstones, session.operations)

  defp eventually(predicate, attempts \\ 200)

  defp eventually(predicate, attempts) when attempts > 0 do
    if predicate.() do
      :ok
    else
      Process.sleep(10)
      eventually(predicate, attempts - 1)
    end
  end

  defp eventually(_predicate, 0), do: {:error, :timeout}
end
