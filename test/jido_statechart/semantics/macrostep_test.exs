defmodule Jido.Statechart.Semantics.MacrostepTest do
  use ExUnit.Case, async: true

  alias Jido.Statechart.Expression.Reference
  alias Jido.Statechart.Model.Event
  alias Jido.Statechart.{Limits, SemanticFixture, Session}
  alias Jido.Statechart.Semantics.{Macrostep, Trace}

  test "eventless transitions run before FIFO internal events" do
    chart =
      SemanticFixture.chart("""
      <state id="root" initial="a">
        <state id="a"><transition event="go" target="b"><raise event="queued"/></transition></state>
        <state id="b"><transition target="c"/></state>
        <state id="c"><transition event="queued" target="done"/></state>
        <final id="done"/>
      </state>
      """)

    session = SemanticFixture.session(chart, status: :active, configuration: ["a"])
    assert {:ok, result} = Macrostep.run(chart, session, %{name: "go"}, SemanticFixture.options())
    assert result.session.configuration == ["done"]
    microsteps = Enum.filter(result.trace, &(&1["kind"] == "microstep"))

    assert Enum.map(microsteps, & &1["transitions"]) ==
             Enum.map(chart.transitions, &[&1.id])
  end

  test "unmatched external and internal error events are discarded as stable no-ops" do
    chart = SemanticFixture.chart(~s(<state id="root"/>))
    queue = [%{"name" => "error.execution", "class" => "platform", "data" => nil}]

    session =
      SemanticFixture.session(chart,
        status: :active,
        configuration: ["root"],
        internal_queue: queue
      )

    assert {:ok, result} =
             Macrostep.run(chart, session, %{name: "unknown"}, SemanticFixture.options())

    assert result.session.configuration == ["root"]
    assert result.session.internal_queue == []
    assert Enum.map(result.trace, & &1["event"]) == ["unknown", "error.execution"]
    assert Enum.all?(result.trace, &(&1["kind"] == "event_discarded"))
  end

  test "public macrosteps accept only reconstructed external events" do
    chart = SemanticFixture.chart(~s(<state id="root"/>))
    session = SemanticFixture.session(chart, status: :active, configuration: ["root"])
    options = SemanticFixture.options()

    for event <- [
          %{},
          %{name: ""},
          %Event{name: nil, class: :external},
          %{name: "go", class: :internal},
          %{name: "go", class: :platform},
          Event.new!(%{name: "go", class: :internal}),
          Event.new!(%{name: "go", class: :platform})
        ] do
      assert {:error, _diagnostic} = Macrostep.run(chart, session, event, options)
    end

    for event <- [%{name: "go"}, %{name: "go", class: :external}, Event.new!(%{name: "go"})] do
      assert {:ok, result} = Macrostep.run(chart, session, event, options)
      assert result.session.configuration == ["root"]
    end
  end

  test "work and trace limits stop at the exact boundary with no partial result" do
    chart =
      SemanticFixture.chart("""
      <state id="root" initial="a">
        <state id="a"><transition event="go" target="b"><send event="outside" target="parent"/></transition></state>
        <state id="b"><transition target="done"/></state><final id="done"/>
      </state>
      """)

    work_limits = Limits.new!(%{microsteps_per_macrostep: 2})

    work_session =
      SemanticFixture.session(chart,
        status: :active,
        configuration: ["a"],
        limits: work_limits
      )

    assert {:error, %{code: :microstep_limit_exceeded}} =
             Macrostep.run(
               chart,
               work_session,
               %{name: "go"},
               SemanticFixture.options(limits: work_limits)
             )

    assert work_session.configuration == ["a"]

    trace_limits = Limits.new!(%{trace_entries: 0})

    trace_session =
      SemanticFixture.session(chart,
        status: :active,
        configuration: ["a"],
        limits: trace_limits
      )

    assert {:error, %{code: :trace_limit_exceeded}} =
             Macrostep.run(
               chart,
               trace_session,
               %{name: "go"},
               SemanticFixture.options(limits: trace_limits)
             )
  end

  test "repeated execution and trace replay are deterministic" do
    chart =
      SemanticFixture.chart("""
      <state id="root" initial="a"><state id="a"><transition event="go" target="b"/></state><state id="b"/></state>
      """)

    session = SemanticFixture.session(chart, status: :active, configuration: ["a"])
    opts = SemanticFixture.options()
    assert {:ok, first} = Macrostep.run(chart, session, %{name: "go"}, opts)
    assert {:ok, second} = Macrostep.run(chart, session, %{name: "go"}, opts)
    assert first == second
    assert {:ok, ^first} = Trace.replay(chart, session, %{name: "go"}, first.trace, opts)

    assert {:error, %{code: :trace_replay_mismatch}} =
             Trace.replay(chart, session, %{name: "go"}, [], opts)
  end

  test "eventless content sees the current event and generated send IDs replay" do
    chart =
      SemanticFixture.chart(
        """
        <datamodel><data id="send_id"/></datamodel>
        <state id="root" initial="a">
          <state id="a"><transition event="go" target="b"/></state>
          <state id="b"><transition target="c"><send eventexpr="current_event" target="parent" idlocation="send_id"/></transition></state>
          <state id="c"/>
        </state>
        """,
        datamodel: "jido"
      )

    registry =
      SemanticFixture.registry([
        SemanticFixture.expression("current_event", Reference.system("_event.name"))
      ])

    session =
      SemanticFixture.session(chart,
        status: :active,
        configuration: ["a"],
        registry: registry,
        data: %{"send_id" => nil}
      )

    opts = SemanticFixture.options(registry: registry)
    assert {:ok, first} = Macrostep.run(chart, session, %{name: "go"}, opts)
    assert {:ok, second} = Macrostep.run(chart, session, %{name: "go"}, opts)
    assert [%{"event" => "go", "send_id" => send_id}] = first.intents
    assert second.intents == first.intents
    assert first.session.generated_id_counter == 1
    assert String.starts_with?(send_id, Session.generated_id_prefix())
  end

  test "late data binding records first entry and survives session storage" do
    chart =
      SemanticFixture.chart(
        """
        <state id="root" initial="child">
          <datamodel><data id="root_value"/></datamodel>
          <state id="child">
            <datamodel><data id="child_value"/></datamodel>
            <transition event="again" target="child"/>
          </state>
        </state>
        """,
        datamodel: "jido",
        binding: "late"
      )

    session = SemanticFixture.session(chart)
    assert {:ok, initialized} = Macrostep.initialize(chart, session, SemanticFixture.options())
    assert initialized.session.initialized_data_state_ids == ["root", "child"]

    assert {:ok, reentered} =
             Macrostep.run(
               chart,
               initialized.session,
               %{name: "again"},
               SemanticFixture.options()
             )

    assert reentered.session.initialized_data_state_ids == ["root", "child"]
    stored_session = reentered.session
    assert {:ok, ^stored_session} = stored_session |> Session.dump() |> Session.load()

    assert {:error, %{code: :missing_session_field}} =
             stored_session
             |> Session.dump()
             |> Map.delete("initialized_data_state_ids")
             |> Session.load()
  end

  test "late binding keeps initialized data states in document order" do
    chart =
      SemanticFixture.chart(
        """
        <state id="root" initial="later">
          <state id="earlier">
            <datamodel><data id="earlier_value"/></datamodel>
            <transition event="stay" target="earlier"/>
          </state>
          <state id="later">
            <datamodel><data id="later_value"/></datamodel>
            <transition event="back" target="earlier"/>
          </state>
        </state>
        """,
        datamodel: "jido",
        binding: "late"
      )

    assert {:ok, initialized} =
             Macrostep.initialize(
               chart,
               SemanticFixture.session(chart),
               SemanticFixture.options()
             )

    assert initialized.session.initialized_data_state_ids == ["later"]

    assert {:ok, moved} =
             Macrostep.run(
               chart,
               initialized.session,
               %{name: "back"},
               SemanticFixture.options()
             )

    assert moved.session.initialized_data_state_ids == ["earlier", "later"]

    assert {:ok, stayed} =
             Macrostep.run(
               chart,
               moved.session,
               %{name: "stay"},
               SemanticFixture.options()
             )

    assert stayed.session.initialized_data_state_ids == ["earlier", "later"]
  end

  test "rejects invalid persisted history and late binding state ids before work" do
    chart =
      SemanticFixture.chart(
        """
        <state id="root" initial="a">
          <history id="shallow" type="shallow"><transition target="a"/></history>
          <state id="a"><datamodel><data id="value"/></datamodel></state>
          <state id="b"/>
        </state>
        """,
        datamodel: "jido",
        binding: "late"
      )

    base = SemanticFixture.session(chart, status: :active, configuration: ["a"])

    for {session, code} <- [
          {%{base | history: %{"missing" => ["a"]}}, :invalid_history},
          {%{base | history: %{"shallow" => ["b", "a"]}}, :invalid_history},
          {%{base | initialized_data_state_ids: ["missing"]}, :invalid_initialized_data_states},
          {%{base | initialized_data_state_ids: ["b"]}, :invalid_initialized_data_states}
        ] do
      assert {:error, %{code: ^code}} =
               Macrostep.run(chart, session, %{name: "noop"}, SemanticFixture.options())
    end
  end

  test "validates shallow and deep history as legal regional configurations" do
    chart =
      SemanticFixture.chart("""
      <state id="root" initial="regions">
        <parallel id="regions">
          <history id="shallow" type="shallow"><transition target="left right"/></history>
          <history id="deep" type="deep"><transition target="left_a right_a"/></history>
          <state id="left" initial="left_a"><state id="left_a"/></state>
          <state id="right" initial="right_a"><state id="right_a"/></state>
        </parallel>
      </state>
      """)

    base = SemanticFixture.session(chart, status: :active, configuration: ["left_a", "right_a"])

    valid = %{base | history: %{"shallow" => ["left", "right"], "deep" => ["left_a", "right_a"]}}

    assert {:ok, _result} =
             Macrostep.run(chart, valid, %{name: "noop"}, SemanticFixture.options())

    for value <- [
          %{"shallow" => ["left"]},
          %{"shallow" => ["right", "left"]},
          %{"deep" => ["left"]},
          %{"deep" => ["left_a"]},
          %{"deep" => ["right_a", "left_a"]},
          %{"deep" => ["left_a", "left_a"]}
        ] do
      assert {:error, %{code: :invalid_history}} =
               Macrostep.run(
                 chart,
                 %{base | history: value},
                 %{name: "noop"},
                 SemanticFixture.options()
               )
    end
  end

  test "validates complete session and event limits at exact byte boundaries" do
    chart = SemanticFixture.chart(~s(<state id="root"/>))
    data = %{"payload" => String.duplicate("x", 500)}
    data_bytes = data |> :erlang.term_to_binary([:deterministic]) |> byte_size()
    limits = Limits.new!(%{data_bytes: data_bytes})

    session =
      SemanticFixture.session(chart,
        status: :active,
        configuration: ["root"],
        data: data,
        limits: limits
      )

    options = SemanticFixture.options(limits: limits)

    assert {:ok, _result} = Macrostep.run(chart, session, %{name: "noop"}, options)

    oversized = %{session | data: Map.put(data, "payload", String.duplicate("x", 501))}

    assert {:error, %{code: :data_limit_exceeded}} =
             Macrostep.run(chart, oversized, %{name: "noop"}, options)

    event = Jido.Statechart.Model.Event.new!(%{name: "noop", data: data})

    event_bytes =
      event
      |> Jido.Statechart.Model.Event.dump()
      |> :erlang.term_to_binary([:deterministic])
      |> byte_size()

    event_limits = Limits.new!(%{data_bytes: event_bytes})

    event_session =
      SemanticFixture.session(chart,
        status: :active,
        configuration: ["root"],
        limits: event_limits
      )

    assert {:ok, _result} =
             Macrostep.run(
               chart,
               event_session,
               event,
               SemanticFixture.options(limits: event_limits)
             )

    one_past_limits = Limits.new!(%{data_bytes: event_bytes - 1})

    one_past_session =
      SemanticFixture.session(chart,
        status: :active,
        configuration: ["root"],
        limits: one_past_limits
      )

    assert {:error, %{code: :data_limit_exceeded}} =
             Macrostep.run(
               chart,
               one_past_session,
               event,
               SemanticFixture.options(limits: one_past_limits)
             )
  end

  test "validates queue, completion, trace, and aggregate session boundaries" do
    chart = SemanticFixture.chart(~s(<state id="root"/>))
    event = Jido.Statechart.Model.Event.new!(%{name: "queued", data: String.duplicate("q", 500)})
    event_map = Jido.Statechart.Model.Event.dump(event)
    event_bytes = event_map |> :erlang.term_to_binary([:deterministic]) |> byte_size()
    event_limits = Limits.new!(%{data_bytes: event_bytes, internal_queue_events: 1})

    queue_session =
      SemanticFixture.session(chart, status: :completed, limits: event_limits)
      |> Map.put(:internal_queue, [event_map])

    assert {:error, %{code: :session_completed}} =
             Macrostep.run(
               chart,
               queue_session,
               %{name: "noop"},
               SemanticFixture.options(limits: event_limits)
             )

    assert {:error, %{code: :internal_queue_limit_exceeded}} =
             Macrostep.run(
               chart,
               %{queue_session | internal_queue: [event_map, event_map]},
               %{name: "noop"},
               SemanticFixture.options(limits: event_limits)
             )

    completion = String.duplicate("c", 500)
    completion_bytes = completion |> :erlang.term_to_binary([:deterministic]) |> byte_size()
    completion_limits = Limits.new!(%{data_bytes: completion_bytes})

    completion_session =
      SemanticFixture.session(chart, status: :completed, limits: completion_limits)
      |> Map.put(:completion_data, completion)

    assert {:error, %{code: :session_completed}} =
             Macrostep.run(
               chart,
               completion_session,
               %{name: "noop"},
               SemanticFixture.options(limits: completion_limits)
             )

    assert {:error, %{code: :data_limit_exceeded}} =
             Macrostep.run(
               chart,
               %{completion_session | completion_data: completion <> "x"},
               %{name: "noop"},
               SemanticFixture.options(limits: completion_limits)
             )

    trace = [%{"payload" => String.duplicate("t", 500)}]
    trace_bytes = trace |> :erlang.term_to_binary([:deterministic]) |> byte_size()
    trace_limits = Limits.new!(%{data_bytes: trace_bytes, trace_entries: 1})

    trace_session =
      SemanticFixture.session(chart, status: :completed, limits: trace_limits)
      |> Map.put(:trace, trace)

    assert {:error, %{code: :session_completed}} =
             Macrostep.run(
               chart,
               trace_session,
               %{name: "noop"},
               SemanticFixture.options(limits: trace_limits)
             )

    assert {:error, %{code: :data_limit_exceeded}} =
             Macrostep.run(
               chart,
               %{trace_session | trace: [%{"payload" => String.duplicate("t", 501)}]},
               %{name: "noop"},
               SemanticFixture.options(limits: trace_limits)
             )

    assert {:error, %{code: :trace_limit_exceeded}} =
             Macrostep.run(
               chart,
               %{trace_session | trace: trace ++ trace},
               %{name: "noop"},
               SemanticFixture.options(limits: trace_limits)
             )

    bad_trace_session =
      SemanticFixture.session(chart, status: :completed)
      |> Map.put(:trace, [%{"bad" => self()}])

    assert {:error, %{code: :non_portable_value}} =
             Macrostep.run(
               chart,
               bad_trace_session,
               %{name: "noop"},
               SemanticFixture.options(limits: Limits.default())
             )

    session_data = %{"padding" => String.duplicate("s", 1_000)}
    base = SemanticFixture.session(chart, status: :completed, data: session_data)

    session_bytes =
      base |> Session.dump() |> :erlang.term_to_binary([:deterministic]) |> byte_size()

    exact_limits = Limits.new!(%{session_bytes: session_bytes})

    exact_session =
      SemanticFixture.session(chart,
        status: :completed,
        data: session_data,
        limits: exact_limits
      )

    assert byte_size(:erlang.term_to_binary(Session.dump(exact_session), [:deterministic])) ==
             session_bytes

    assert {:error, %{code: :session_completed}} =
             Macrostep.run(
               chart,
               exact_session,
               %{name: "noop"},
               SemanticFixture.options(limits: exact_limits)
             )

    one_past_limits = Limits.new!(%{session_bytes: session_bytes - 1})

    one_past_session =
      SemanticFixture.session(chart,
        status: :completed,
        data: session_data,
        limits: one_past_limits
      )

    assert {:error, %{code: :session_size_limit_exceeded}} =
             Macrostep.run(
               chart,
               one_past_session,
               %{name: "noop"},
               SemanticFixture.options(limits: one_past_limits)
             )
  end

  test "validates the grown output session before it returns" do
    chart = SemanticFixture.chart(~s(<state id="root"/>))
    data = %{"padding" => String.duplicate("s", 1_000)}
    base = SemanticFixture.session(chart, status: :active, configuration: ["root"], data: data)

    session_bytes =
      base |> Session.dump() |> :erlang.term_to_binary([:deterministic]) |> byte_size()

    limits = Limits.new!(%{session_bytes: session_bytes})

    session =
      SemanticFixture.session(chart,
        status: :active,
        configuration: ["root"],
        data: data,
        limits: limits
      )

    assert byte_size(:erlang.term_to_binary(Session.dump(session), [:deterministic])) ==
             session_bytes

    assert {:error, %{code: :session_size_limit_exceeded}} =
             Macrostep.run(
               chart,
               session,
               %{name: "unmatched"},
               SemanticFixture.options(limits: limits)
             )

    assert session.trace == []
    assert session.configuration == ["root"]
  end
end
