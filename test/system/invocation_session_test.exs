defmodule Jido.Statechart.InvocationSessionTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Jido.AgentServer
  alias Jido.Agent.Directive
  alias Jido.Statechart.Agent.Extension
  alias Jido.Statechart.Plugin.Runtime
  alias Jido.Statechart.Plugin.OwnedChildControl
  alias Jido.Statechart.Runtime.Child
  alias Jido.Statechart.{Agent, Chart, Plugin, Registry, SemanticFixture}

  defmodule ChildChart do
    @chart SemanticFixture.chart("""
           <state id="root">
             <transition event="finish" target="done"/>
           </state>
           <final id="done">
             <donedata><content>{"answer":42}</content></donedata>
           </final>
           """)
    @registry SemanticFixture.registry()
    use Chart, chart: @chart, registry: @registry
  end

  defmodule ChildAgent do
    use Jido.Agent,
      name: "statechart_invoked_child_agent",
      extensions: [Extension]

    agent do
      plugin(Plugin, config: [rescan_interval: 10])
    end

    routes do
      route("finish", statechart: ChildChart)
    end
  end

  defmodule StandardParentChart do
    @chart SemanticFixture.chart("""
           <state id="root">
             <invoke id="child" type="scxml" src="child-chart" autoforward="true"/>
             <transition event="done.invoke.child" target="done"/>
           </state>
           <final id="done"/>
           """)
    @registry Registry.new!(%{
                version: "standard-invocation-1",
                entries: [
                  %{
                    kind: :invocation,
                    alias: "child-chart",
                    permissions: ["invoke:scxml", "scope:local"],
                    metadata: %{
                      "type" => "scxml",
                      "chart_fingerprint" => ChildChart.chart().fingerprint
                    },
                    handler: ChildAgent
                  }
                ]
              })
    use Chart, chart: @chart, registry: @registry
  end

  defmodule StandardParentAgent do
    use Jido.Agent,
      name: "statechart_standard_invocation_parent",
      extensions: [Extension]

    agent do
      plugin(Plugin, config: [rescan_interval: 10])
    end

    routes do
      route("finish", statechart: StandardParentChart)
    end
  end

  defmodule WorkerAgent do
    use Jido.Agent, name: "statechart_invoked_local_worker"

    agent do
      schema(Zoi.object(%{job: Zoi.string() |> Zoi.default("none")}))
    end
  end

  defmodule ReturnDirective do
    use Jido.Action, name: "statechart_test_return_directive"

    @impl true
    def run(%{directive: directive}, context),
      do: {:ok, context.agent_state, [directive]}
  end

  defmodule LocalParentChart do
    @chart SemanticFixture.chart("""
           <state id="root">
             <invoke id="worker" type="jido" src="worker"/>
             <transition event="finish" target="done"/>
           </state>
           <final id="done"/>
           """)
    @registry Registry.new!(%{
                version: "local-invocation-1",
                entries: [
                  %{
                    kind: :invocation,
                    alias: "worker",
                    permissions: ["invoke:jido", "scope:local"],
                    metadata: %{"type" => "jido", "input_mode" => "initial_state"},
                    handler: WorkerAgent
                  }
                ]
              })
    use Chart, chart: @chart, registry: @registry
  end

  defmodule LocalParentAgent do
    use Jido.Agent,
      name: "statechart_local_invocation_parent",
      extensions: [Extension]

    agent do
      plugin(Plugin, config: [rescan_interval: 10])
    end

    routes do
      route("finish", statechart: LocalParentChart)
      route("test.directive", ReturnDirective)
    end
  end

  defmodule RaceParentChart do
    @chart SemanticFixture.chart("""
           <state id="root">
             <invoke id="worker" type="jido" src="worker"/>
             <transition target="done"/>
           </state>
           <final id="done"/>
           """)
    @registry LocalParentChart.registry()
    use Chart, chart: @chart, registry: @registry
  end

  defmodule RaceParentAgent do
    use Jido.Agent,
      name: "statechart_invocation_race_parent",
      extensions: [Extension]

    agent do
      plugin(Plugin, config: [rescan_interval: 10])
    end

    routes do
      route("finish", statechart: RaceParentChart)
    end
  end

  defmodule InvalidChildAgent do
    use Jido.Agent, name: "statechart_invalid_invocation_child"

    agent do
      schema(Zoi.object(%{required_job: Zoi.string()}))
    end
  end

  defmodule FailedStartChart do
    @chart SemanticFixture.chart("""
           <state id="root">
             <invoke id="worker" type="jido" src="invalid-worker"/>
             <transition event="error.communication" target="done"/>
           </state>
           <final id="done"/>
           """)
    @registry Registry.new!(%{
                version: "failed-start-invocation-1",
                entries: [
                  %{
                    kind: :invocation,
                    alias: "invalid-worker",
                    permissions: ["invoke:jido", "scope:local"],
                    metadata: %{"type" => "jido", "input_mode" => "initial_state"},
                    handler: InvalidChildAgent
                  }
                ]
              })
    use Chart, chart: @chart, registry: @registry
  end

  defmodule FailedStartAgent do
    use Jido.Agent,
      name: "statechart_failed_start_parent",
      extensions: [Extension]

    agent do
      plugin(Plugin,
        config: [rescan_interval: 10, retry_limit: 1, retry_backoff_ms: 10]
      )
    end

    routes do
      route("finish", statechart: FailedStartChart)
    end
  end

  defmodule MutualAChart do
    @chart SemanticFixture.chart(
             """
             <state id="root">
               <invoke id="b" type="scxml" src="mutual-b"/>
               <transition event="error.communication" target="done"/>
             </state>
             <final id="done"/>
             """,
             id: "mutual-a"
           )

    def chart, do: @chart

    def registry do
      Registry.new!(%{
        version: "mutual-a-registry-1",
        entries: [
          %{
            kind: :invocation,
            alias: "mutual-b",
            permissions: ["invoke:scxml", "scope:local"],
            metadata: %{
              "type" => "scxml",
              "chart_fingerprint" =>
                Jido.Statechart.InvocationSessionTest.MutualBChart.chart().fingerprint
            },
            handler: Jido.Statechart.InvocationSessionTest.MutualBAgent
          }
        ]
      })
    end
  end

  defmodule MutualBChart do
    @chart SemanticFixture.chart(
             """
             <state id="root">
               <invoke id="a" type="scxml" src="mutual-a"/>
             </state>
             """,
             id: "mutual-b"
           )

    def chart, do: @chart

    def registry do
      Registry.new!(%{
        version: "mutual-b-registry-1",
        entries: [
          %{
            kind: :invocation,
            alias: "mutual-a",
            permissions: ["invoke:scxml", "scope:local"],
            metadata: %{
              "type" => "scxml",
              "chart_fingerprint" =>
                Jido.Statechart.InvocationSessionTest.MutualAChart.chart().fingerprint
            },
            handler: Jido.Statechart.InvocationSessionTest.MutualAAgent
          }
        ]
      })
    end
  end

  defmodule MutualAAgent do
    use Jido.Agent,
      name: "statechart_mutual_a_agent",
      extensions: [Extension]

    agent do
      plugin(Plugin, config: [rescan_interval: 10])
    end

    routes do
      route("finish", statechart: MutualAChart)
    end
  end

  defmodule MutualBAgent do
    use Jido.Agent,
      name: "statechart_mutual_b_agent",
      extensions: [Extension]

    agent do
      plugin(Plugin, config: [rescan_interval: 10])
    end

    routes do
      route("finish", statechart: MutualBChart)
    end
  end

  setup do
    jido = String.to_atom("invocation_jido_#{System.unique_integer([:positive])}")
    namespace = "statechart/invocation/#{System.unique_integer([:positive])}"
    start_supervised!({Jido, name: jido, namespace: namespace})
    {:ok, jido: jido}
  end

  test "a standard child is initialized, receives autoforward, and completes once", %{jido: jido} do
    {:ok, parent} =
      Jido.start_agent(jido, StandardParentAgent, id: "standard-parent", debug: true)

    assert {:ok, _agent} = Agent.initialize(parent)

    assert eventually(fn -> length(invocation_children(parent)) == 1 end) == :ok,
           inspect({session(parent), AgentServer.recent_events(parent)})

    [child] = invocation_children(parent)

    assert child.meta["jido_statechart_invoke_id"] == "child"
    assert child.meta["jido_statechart_depth"] == 1
    assert :ok = Jido.PortableTerm.validate(child.meta, [:child, :meta])
    assert session(parent).revision == 2

    assert :ok =
             eventually(fn ->
               match?(
                 {:ok, %{session: %{status: :active}}},
                 AgentServer.plugin_state(child.pid, Plugin)
               )
             end)

    child_session = session(child.pid)
    assert child_session.invocation_ancestry == child.meta["jido_statechart_ancestry"]
    assert child_session.invocation_depth == 1

    assert child_session.invocation_remaining_descendants ==
             child.meta["jido_statechart_remaining_descendants"]

    assert {:ok, committed} = call(parent, "finish", "finish-standard-child")
    assert committed.state.statechart.session.status == :active

    assert :ok =
             eventually(fn ->
               current = session(parent)

               current.status == :completed and
                 Enum.count(records(current), fn operation ->
                   operation.kind == :invoke and operation.state == :confirmed_complete
                 end) == 1 and
                 Enum.any?(records(current), fn operation ->
                   operation.kind == :child_stop and operation.state == :confirmed_complete
                 end) and invocation_children(parent) == []
             end)

    assert {:ok, events} = AgentServer.recent_events(parent)
    refute Enum.any?(events, &(&1.event == :turn_failed)), inspect(events)
  end

  test "same-macrostep start and stop converges without an orphan", %{jido: jido} do
    {:ok, parent} = Jido.start_agent(jido, RaceParentAgent, id: "race-parent", debug: true)

    assert {:ok, completed} = Agent.initialize(parent)
    assert completed.state.statechart.session.status == :completed

    assert :ok =
             eventually(fn ->
               current = session(parent)
               operations = records(current)

               invocation_children(parent) == [] and
                 Enum.any?(operations, &(&1.kind == :invoke and &1.state == :canceled)) and
                 Enum.any?(
                   operations,
                   &(&1.kind == :child_stop and &1.state == :confirmed_complete)
                 )
             end)

    assert session(parent).revision == 3
    assert {:ok, events} = AgentServer.recent_events(parent)
    refute Enum.any?(events, &(&1.event == :turn_failed)), inspect(events)

    refute Enum.any?(events, fn event ->
             get_in(event, [:metadata, :signal_type]) == "jido.agent.child.started"
           end)
  end

  test "a permanent child constructor failure becomes a later communication event", %{jido: jido} do
    {:ok, parent} =
      Jido.start_agent(jido, FailedStartAgent, id: "failed-start-parent", debug: true)

    assert {:ok, initialized} = Agent.initialize(parent)
    assert initialized.state.statechart.session.status == :active

    assert :ok =
             eventually(fn ->
               current = session(parent)

               current.status == :completed and
                 Enum.any?(records(current), fn operation ->
                   operation.kind == :invoke and operation.state == :permanent_failure
                 end)
             end)

    assert invocation_children(parent) == []
  end

  test "live mutual A to B to A recursion fails through carried child context", %{jido: jido} do
    {:ok, parent} = Jido.start_agent(jido, MutualAAgent, id: "mutual-a-parent", debug: true)

    assert {:ok, initialized} = Agent.initialize(parent)
    assert initialized.state.statechart.session.status == :active

    result =
      eventually(fn ->
        current = session(parent)

        current.status == :completed and
          Enum.any?(records(current), fn operation ->
            operation.kind == :invoke and operation.state == :permanent_failure
          end) and invocation_children(parent) == []
      end)

    assert result == :ok,
           inspect(
             {session(parent), invocation_children(parent), AgentServer.recent_events(parent)}
           )
  end

  test "a local Agent child survives runtime replacement and stops on state exit", %{jido: jido} do
    {:ok, parent} =
      Jido.start_agent(jido, LocalParentAgent, id: "local-parent", debug: true)

    assert {:ok, _agent} = Agent.initialize(parent)

    assert :ok = eventually(fn -> length(invocation_children(parent)) == 1 end)
    [child] = invocation_children(parent)
    current = session(parent)
    assert current.revision == 2
    invoke = Enum.find(Map.values(current.operations), &(&1.kind == :invoke))
    assert Child.owned?(child, invoke)

    refute Child.owned?(
             put_in(child, [:meta, "jido_statechart_session_incarnation"], "stale"),
             invoke
           )

    assert :ok =
             eventually(fn ->
               {:ok, events} = AgentServer.recent_events(parent)

               Enum.any?(events, fn event ->
                 event.event == :turn_completed and
                   event.metadata.signal_type == "jido.agent.child.started"
               end)
             end)

    runtime = :global.whereis_name({Runtime, parent})
    assert is_pid(runtime)

    capture_log(fn ->
      Process.exit(runtime, :kill)

      assert :ok =
               eventually(fn ->
                 replacement = :global.whereis_name({Runtime, parent})
                 is_pid(replacement) and replacement != runtime
               end)
    end)

    assert [restored_child] = invocation_children(parent)
    assert restored_child.pid == child.pid
    assert session(parent).revision == 2

    assert {:ok, completed} = call(parent, "finish", "finish-local-child")
    assert completed.state.statechart.session.status == :completed

    assert :ok =
             eventually(fn ->
               current = session(parent)
               operations = records(current)

               invocation_children(parent) == [] and
                 Enum.any?(operations, &(&1.kind == :invoke and &1.state == :canceled)) and
                 Enum.any?(
                   operations,
                   &(&1.kind == :child_stop and &1.state == :confirmed_complete)
                 )
             end)

    assert {:ok, events} = AgentServer.recent_events(parent)
    refute Enum.any?(events, &(&1.event == :turn_failed)), inspect(events)
  end

  test "serialized child control rejects a replacement with the same tag", %{jido: jido} do
    {:ok, parent} =
      Jido.start_agent(jido, LocalParentAgent, id: "ownership-parent", debug: true)

    assert {:ok, _agent} = Agent.initialize(parent)
    assert :ok = eventually(fn -> length(invocation_children(parent)) == 1 end)

    [original] = invocation_children(parent)
    invoke = Enum.find(Map.values(session(parent).operations), &(&1.kind == :invoke))
    assert Child.owned?(original, invoke)

    control = %OwnedChildControl{
      action: :stop,
      tag: original.tag,
      invoke_operation_id: invoke.id,
      invoke_generation: invoke.generation,
      invoke_id: invoke.correlation["invoke_id"],
      session_incarnation: invoke.session_incarnation,
      control_operation_id: "replacement-race-stop"
    }

    assert {:ok, _agent} =
             AgentServer.call(
               parent,
               Jido.Signal.new!(
                 "test.directive",
                 %{directive: Directive.stop_child(original.tag)},
                 source: "/test"
               )
             )

    assert :ok = eventually(fn -> invocation_children(parent) == [] end)

    wrong_meta = %{
      "jido_statechart_operation_id" => "replacement-operation",
      "jido_statechart_generation" => invoke.generation,
      "jido_statechart_invoke_id" => invoke.correlation["invoke_id"],
      "jido_statechart_session_incarnation" => invoke.session_incarnation
    }

    assert {:ok, _agent} =
             AgentServer.call(
               parent,
               Jido.Signal.new!(
                 "test.directive",
                 %{
                   directive:
                     Directive.spawn_child(WorkerAgent, original.tag,
                       meta: wrong_meta,
                       restart: :temporary
                     )
                 },
                 source: "/test"
               )
             )

    assert :ok = eventually(fn -> length(invocation_children(parent)) == 1 end)
    [replacement] = invocation_children(parent)
    refute Child.owned?(replacement, invoke)

    _result =
      AgentServer.call(
        parent,
        Jido.Signal.new!("test.directive", %{directive: control},
          id: "replacement-control",
          source: "/test"
        )
      )

    assert :ok =
             eventually(fn ->
               {:ok, events} = AgentServer.recent_events(parent)

               Enum.any?(events, fn event ->
                 event.event == :directive_failed and
                   inspect(event.metadata.error) =~ "statechart_child_ownership_conflict"
               end)
             end)

    assert Process.alive?(replacement.pid)
    assert Enum.any?(invocation_children(parent), &(&1.pid == replacement.pid))
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
    do: Map.values(Map.merge(session.operation_tombstones, session.operations))

  defp invocation_children(server) do
    server
    |> AgentServer.children()
    |> Map.values()
    |> Enum.filter(fn child ->
      child.kind == :agent and is_binary(child.meta["jido_statechart_operation_id"])
    end)
  end

  defp eventually(predicate, attempts \\ 300)

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
