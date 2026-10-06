defmodule JidoStatechartTest.AgentTest do
  use ExUnit.Case, async: false
  alias Jido.AgentServer, as: Server
  alias Jido.Statechart.{Agent, Checkpoint, Error, Registry, Step}
  alias JidoStatechartTest.{Door, NestedDSL}
  import JidoStatechartTest.Fixtures

  setup do
    start_supervised!({Jido, name: JidoStatechartTest.Runtime})
    Process.register(self(), JidoStatechartTest.Observer)
    :ok
  end

  defp signal(type, data \\ %{}), do: Jido.Signal.new!(type, data, source: "/test")

  test "normal Agent definitions store behavior in metadata and only mutable chart data in state" do
    definition = Door.definition()
    assert %Jido.Agent{id: nil, state: nil} = definition
    assert definition.metadata.statechart.definition == Door.chart_definition()
    assert definition.metadata.statechart.registry == Door.registry()
    assert {:ok, agent} = Door.new(id: "door")
    assert agent.state.chart.status == "new"
    assert agent.state.chart.active == []
    assert agent.state.data == %{count: 0}
    assert {:ok, turn} = Door.handle_signal(signal("open"), agent)
    assert turn.executable == Step
    assert turn.source_signal.type == "open"
    assert {:ok, keyword_turn} = Door.handle_signal(signal("open", allowed: true), agent)
    assert keyword_turn.input.event.data == %{allowed: true}
    assert {:ok, candidate, [_directive]} = Door.cmd(agent, signal("open"))
    assert candidate.state.chart.active == ["opened"]
    assert candidate.state.data.count == 2
    assert Map.keys(candidate.state) |> Enum.sort() == [:chart, :data]
    assert {:ok, chart_instance} = Agent.decode_state(candidate.state)
    assert Agent.encode_state(chart_instance) == candidate.state
    refute_received {:signal, %Jido.Signal{type: "chart.changed"}}
  end

  test "Signal data cannot replace trusted behavior or current Agent state" do
    agent = Door.new!()

    assert {:ok, candidate, [_]} =
             Door.cmd(
               agent,
               signal("open", %{trusted: :evil, agent_state: %{count: 50}, event: "close"})
             )

    assert candidate.state.data.count == 2
    assert candidate.state.chart.active == ["opened"]
    altered = %{agent | metadata: %{}}
    assert {:error, %Error{code: :definition_mismatch}} = Agent.trusted_metadata(altered)

    assert {:error, %Error{code: :definition_mismatch}} =
             Agent.trusted_metadata(%{agent | name: "altered"})

    assert {:error, %Error{}} = Door.handle_signal(signal("done.state.closed"), agent)
    assert {:error, _} = Door.handle_signal(signal("open", [1]), agent)
  end

  test "live Jido Server commits one complete candidate and dispatches its effect" do
    {:ok, server} = Jido.start_agent(JidoStatechartTest.Runtime, Door, id: "live")
    assert Server.snapshot(server).state_version == 0
    assert {:ok, candidate} = Server.call(server, signal("open"))
    assert candidate.state.chart.active == ["opened"]
    assert candidate.state.data.count == 2
    assert_receive {:signal, %Jido.Signal{type: "chart.changed"}}, 1000
    assert Server.agent(server) == candidate
    assert Server.snapshot(server).state_version == 1
    assert {:ok, closed} = Server.call(server, signal("close"))
    assert closed.state.data.count == 3
    assert Server.snapshot(server).state_version == 2
  end

  test "limits, unhandled events, bad effects, and invalid domain state never commit or dispatch" do
    {:ok, server} = Jido.start_agent(JidoStatechartTest.Runtime, Door, id: "failures")
    initial = Server.agent(server)

    for type <- ["unknown", "invalid", "loop", "missing_effect"] do
      assert {:error, _} = Server.call(server, signal(type))
      assert Server.agent(server) == initial
      assert Server.snapshot(server).state_version == 0
      refute_received {:signal, %Jido.Signal{type: "chart.changed"}}
    end

    assert {:error, _} =
             Jido.Agent.set(initial, chart: %{initial.state.chart | fingerprint: "other"})

    assert {:error, _} = Door.new(state: %{chart: %{fingerprint: "other"}})
  end

  test "Agent checkpoints keep fingerprints and rebuild trusted behavior without repeating entry" do
    agent = Door.new!(id: "persisted")
    {:ok, opened, _} = Door.cmd(agent, signal("open"))
    assert {:ok, checkpoint} = Jido.Agent.checkpoint(opened)
    assert checkpoint.kind == :agent_custom
    assert checkpoint.payload.fingerprint == Door.chart_definition().fingerprint
    assert checkpoint.payload.state == opened.state
    bytes = :erlang.term_to_binary(checkpoint)
    checkpoint = :erlang.binary_to_term(bytes, [:safe])
    assert {:ok, restored} = Jido.Agent.restore(Door, checkpoint)
    assert restored == opened
    assert {:ok, closed, []} = Door.cmd(restored, signal("close"))
    assert closed.state.data.count == 3
    refute_received {:signal, %Jido.Signal{}}

    assert {:error, %Error{code: :definition_mismatch}} =
             Jido.Agent.restore(Door, put_in(checkpoint.payload.fingerprint, "other"))

    assert {:error, _} =
             Jido.Agent.restore(Door, put_in(checkpoint.payload.state.chart.active, ["missing"]))

    assert {:error, _} = Jido.Agent.restore(Door, %{checkpoint | vsn: 2})
    assert {:error, _} = Agent.restore(Door, %{}, %{})

    assert {:error, _} =
             Jido.Agent.restore(Door, update_in(checkpoint.payload.state, &Map.delete(&1, :data)))
  end

  test "abnormal local restart preserves the committed configuration and revision" do
    {:ok, server} =
      Jido.start_agent(JidoStatechartTest.Runtime, Door, id: "restart", restart: :temporary)

    {:ok, committed} = Server.call(server, signal("open"))
    assert_receive {:signal, %Jido.Signal{type: "chart.changed"}}, 1000
    monitor = Process.monitor(server)
    Process.exit(server, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^server, :killed}, 1000

    {:ok, recovered} =
      Jido.start_agent(JidoStatechartTest.Runtime, Door, id: "restart", restart: :temporary)

    assert Server.agent(recovered) == committed
    assert Server.snapshot(recovered).state_version == 1
    refute_received {:signal, %Jido.Signal{type: "chart.changed"}}
    assert {:ok, closed} = Server.call(recovered, signal("close"))
    assert closed.state.data.count == 3
    assert Server.snapshot(recovered).state_version == 2
  end

  test "pure core checkpoints can be restored and reject malformed or incompatible payloads" do
    definition = Jido.Statechart.compile!(flat())
    {:ok, start} = Jido.Statechart.init(definition)
    {:ok, result} = Jido.Statechart.step(definition, start.instance, event("toggle"))
    assert {:ok, payload} = Checkpoint.dump(definition, result.instance)
    assert {:ok, instance} = Checkpoint.load(definition, payload)
    assert instance == result.instance

    assert {:error, %Error{code: :definition_mismatch}} =
             Checkpoint.load(Jido.Statechart.compile!(flat(%{version: "2"})), payload)

    for bad <- [
          %{},
          %{payload | "version" => 2},
          %{payload | "status" => "evil"},
          Map.put(payload, "module", "evil"),
          %{payload | "data" => self()}
        ] do
      assert {:error, %Error{}} = Checkpoint.load(definition, bad)
    end
  end

  test "data-built Agent uses the same public integration" do
    definition = Jido.Statechart.compile!(flat())
    assert {:ok, agent_def} = Agent.build(Agent, "data_chart", definition)
    assert {:ok, agent} = Jido.Agent.instantiate(agent_def)
    assert {:ok, next, []} = Jido.Agent.cmd(agent, signal("toggle"))
    assert next.state.chart.active == ["on"]
    assert {:ok, checkpoint} = Jido.Agent.checkpoint(next)

    assert {:ok, ^next} =
             Jido.Agent.restore(Agent, checkpoint, %{statechart_definition: agent_def})

    assert {:error, %Error{code: :invalid_checkpoint}} = Jido.Agent.restore(Agent, checkpoint)

    assert {:error, %Error{code: :definition_mismatch}} =
             Jido.Agent.restore(Agent, put_in(checkpoint.payload.fingerprint, "other"), %{
               statechart_definition: agent_def
             })

    assert {:error, %Error{}} =
             Agent.build(Agent, "bad", definition, %Registry{}, effects: %{bad: fn _ -> :ok end})

    assert {:error, %Error{}} = Agent.build(Agent, "bad", definition, %Registry{}, effects: [])
    assert {:error, %Error{}} = Step.run(%{}, %{})
    assert {:error, %Error{}} = Agent.decode_state(%{})

    assert {:error, %Error{}} =
             Agent.decode_state(%{
               chart: %{fingerprint: "x", active: [], status: "evil"},
               data: %{}
             })

    nested = NestedDSL.new!()
    assert {:ok, final, []} = NestedDSL.cmd(nested, signal("finish"))
    assert final.state.chart.status == "done"
  end

  test "invalid and failing Directive builders reject the Turn" do
    chart =
      Jido.Statechart.compile!(%{
        id: "x",
        initial: "a",
        states: [%{id: "a", transitions: [%{event: "go", actions: [%{effect: "x"}]}]}]
      })

    for builder <- [
          fn _ -> :bad end,
          fn _ -> raise "bad" end,
          fn _ -> throw(:bad) end,
          fn _ -> {:ok, :bad} end
        ] do
      {:ok, definition} =
        Agent.build(Agent, "bad_effect", chart, %Registry{}, effects: %{"x" => builder})

      {:ok, agent} = Jido.Agent.instantiate(definition)
      assert {:error, _} = Jido.Agent.cmd(agent, signal("go"))
    end
  end
end
