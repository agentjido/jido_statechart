defmodule Jido.Statechart.AgentTest do
  use ExUnit.Case, async: true

  alias Jido.Agent, as: JidoAgent
  alias Jido.Agent.Extension.RouteTarget
  alias Jido.Plugin.Input
  alias Jido.Signal.Router.Route, as: SignalRoute
  alias Jido.Statechart.Agent.{Extension, Route}
  alias Jido.Statechart.Model.Event
  alias Jido.Statechart.{Chart, Flow, Plugin, Result, SemanticFixture}

  defmodule BoundChart do
    @chart SemanticFixture.chart("""
           <state id="root" initial="idle">
             <state id="idle"><transition event="go" target="working"/></state>
             <state id="working"><transition event="finish" target="done"/></state>
             <final id="done"/>
           </state>
           """)
    @registry SemanticFixture.registry()

    use Chart, chart: @chart, registry: @registry
  end

  defmodule LiveAgent do
    use Jido.Agent,
      name: "statechart_agent_test",
      extensions: [Extension]

    agent do
      schema(Zoi.object(%{label: Zoi.string() |> Zoi.default("kept")}))
      plugin(Plugin, config: [duplicate_window: 2])
    end

    routes do
      route("go", statechart: BoundChart)
    end
  end

  defmodule OtherChart do
    @chart SemanticFixture.chart(
             """
             <state id="root"><transition event="go" target="done"/></state>
             <final id="done"/>
             """,
             id: "other-chart"
           )
    @registry SemanticFixture.registry()
    use Chart, chart: @chart, registry: @registry
  end

  test "the Agent extension lowers a chart route to the normal Flow wrapper" do
    definition = LiveAgent.definition()

    assert Enum.any?(definition.routes, &(&1.path == "go" and &1.target == Route))
    assert Enum.any?(definition.routes, &(&1.path == "**" and &1.target == Route))

    for type <- Jido.Statechart.Agent.reserved_signal_types() do
      assert Enum.any?(definition.routes, &(&1.path == type))
    end

    assert [{Plugin, options}] = definition.plugins
    assert options[:chart] == BoundChart
    assert options[:duplicate_window] == 2
    assert [%Jido.Flow.Step{}, %Jido.Flow.Subflow{}, %Jido.Flow.Step{}] = Route.flow().components
    assert %Jido.Flow.Compiled{} = Route.compiled()
    assert {:error, _error} = Route.validate_params(:invalid)
    assert {:error, _error} = Route.validate_output(%Result{})
  end

  test "the Agent extension rejects missing, invalid, conflicting, and multiple chart bindings" do
    base = %{routes: [], plugins: [], metadata: %{}}
    assert {:error, _error} = Extension.lower_agent(base, [])
    assert {:error, _error} = Extension.lower_agent(%{base | routes: :invalid}, [])

    invalid = statechart_route("go", String)
    assert {:error, _error} = Extension.lower_agent(%{base | routes: [invalid]}, [])

    invalid_value = statechart_route("go", 1)
    assert {:error, _error} = Extension.lower_agent(%{base | routes: [invalid_value]}, [])

    first = statechart_route("one", BoundChart)
    second = statechart_route("two", OtherChart)
    assert {:error, _error} = Extension.lower_agent(%{base | routes: [first, second]}, [])

    for type <- Jido.Statechart.Agent.reserved_signal_types() do
      reserved = %SignalRoute{path: type, target: Route, priority: 0, match: nil}

      assert {:error, _error} =
               Extension.lower_agent(%{base | routes: [first, reserved]}, [])
    end

    conflicting_plugins = [{Plugin, [chart: OtherChart]}]

    assert {:error, _error} =
             Extension.lower_agent(%{base | routes: [first], plugins: conflicting_plugins}, [])

    assert {:error, _error} =
             Extension.lower_agent(%{base | routes: [first], plugins: :invalid}, [])
  end

  test "reserved Signal helpers expose the closed runtime-owned set" do
    assert Jido.Statechart.Agent.reserved_signal_types() == [
             "jido.statechart.initialize",
             "jido.statechart.cleanup.confirmed",
             "jido.statechart.timer",
             "jido.statechart.delivery",
             "jido.statechart.child",
             "jido.statechart.reconcile"
           ]

    refute Jido.Statechart.Agent.reserved_signal?("business.event")
  end

  test "the live route refuses an unauthenticated initialization" do
    session = SemanticFixture.session(BoundChart.chart())

    input = %Input{
      prepared: %{
        kind: :macrostep,
        operation: :initialize,
        chart: BoundChart,
        session: session,
        event: nil,
        limits: Jido.Statechart.Limits.default()
      },
      runtime: %{}
    }

    context = %{plugin_inputs: %{Plugin => input}}

    assert {:error, :statechart_live_initialization_required} =
             Route.Prepare.run(%{}, context)
  end

  test "direct Agent execution keeps non-Plugin state and matches direct Flow output" do
    chart = BoundChart.chart()
    registry = BoundChart.registry()
    session = SemanticFixture.session(chart, status: :active, configuration: ["idle"])

    agent =
      LiveAgent.new!(
        id: "agent-direct",
        state: %{
          label: "kept",
          statechart: Plugin.state(session, ["prior"])
        }
      )

    signal = Jido.Signal.new!("go", %{"value" => 7}, id: "signal-go", source: "/caller")
    event = Plugin.event(signal, session)

    assert {:ok, %Result{} = direct} = Flow.step(chart, session, event, registry)
    assert {:ok, next_agent, [%Jido.Statechart.Plugin.Commit{}]} = JidoAgent.cmd(agent, signal)
    assert next_agent.state.label == "kept"
    assert next_agent.state.statechart.session == direct.session
    assert next_agent.state.statechart.recent_signal_ids == ["prior", "signal-go"]
  end

  test "unmatched Signals use the statechart fallback and keep a successful no-op result" do
    session =
      BoundChart.chart()
      |> SemanticFixture.session(status: :active, configuration: ["idle"])

    agent =
      LiveAgent.new!(
        id: "agent-unmatched",
        state: %{label: "kept", statechart: Plugin.state(session)}
      )

    signal = Jido.Signal.new!("not.handled", %{}, id: "signal-unmatched", source: "/caller")
    assert {:ok, next_agent, [_commit]} = JidoAgent.cmd(agent, signal)
    assert next_agent.state.statechart.session.configuration == ["idle"]
    assert next_agent.state.statechart.session.revision == session.revision + 1

    assert Enum.any?(
             next_agent.state.statechart.session.trace,
             &(&1["kind"] == "event_discarded")
           )
  end

  test "a duplicate Signal ID is rejected before route execution" do
    session =
      BoundChart.chart()
      |> SemanticFixture.session(status: :active, configuration: ["idle"])

    agent =
      LiveAgent.new!(
        id: "agent-duplicate",
        state: %{label: "kept", statechart: Plugin.state(session, ["same-id"])}
      )

    signal = Jido.Signal.new!("go", %{}, id: "same-id", source: "/caller")
    assert {:error, {:duplicate_signal, "same-id"}} = JidoAgent.cmd(agent, signal)
  end

  test "Signal conversion keeps transport identity separate from SCXML send identity" do
    session =
      SemanticFixture.session(BoundChart.chart(), status: :active, configuration: ["idle"])

    signal =
      Jido.Signal.new!("go", %{"secret" => "data"},
        id: "transport-id",
        source: "/caller",
        jidoscsendid: "authored-send",
        jidoscorigintype: "urn:test",
        jidoscinvokeid: "child-1",
        jidoscturnid: "turn-1"
      )

    session_id = session.id

    assert %Event{
             name: "go",
             class: :external,
             data: %{"secret" => "data"},
             message_id: "transport-id",
             send_id: "authored-send",
             origin: "/caller",
             origin_type: "urn:test",
             invoke_id: "child-1",
             turn_id: "turn-1",
             session_id: ^session_id
           } = Plugin.event(signal, session)
  end

  defp statechart_route(path, chart) do
    %SignalRoute{
      path: path,
      target: %RouteTarget{extension: Extension, option: :statechart, value: chart},
      priority: 0,
      match: nil
    }
  end
end
