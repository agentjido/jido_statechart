defmodule Jido.Statechart.Semantics.HistoryTest do
  use ExUnit.Case, async: true

  alias Jido.Statechart.SemanticFixture, as: Fixture
  alias Jido.Statechart.Semantics.{EntryExit, Macrostep}

  test "shallow history saves a child and restores its default descendants" do
    chart = history_chart("shallow")
    session = Fixture.session(chart, status: :active, configuration: ["a2"])

    assert {:ok, left} = Macrostep.run(chart, session, %{name: "leave"}, Fixture.options())
    assert left.session.history["memory"] == ["a"]
    refute "memory" in left.session.configuration

    assert {:ok, restored} =
             Macrostep.run(chart, left.session, %{name: "restore"}, Fixture.options())

    assert restored.session.configuration == ["a1"]
  end

  test "deep history saves and restores atomic descendants" do
    chart = history_chart("deep")
    session = Fixture.session(chart, status: :active, configuration: ["a2"])

    assert {:ok, left} = Macrostep.run(chart, session, %{name: "leave"}, Fixture.options())
    assert left.session.history["memory"] == ["a2"]

    assert {:ok, restored} =
             Macrostep.run(chart, left.session, %{name: "restore"}, Fixture.options())

    assert restored.session.configuration == ["a2"]
  end

  test "history default transition content runs before its target entry" do
    chart =
      Fixture.chart("""
      <state id="root" initial="outside">
        <state id="inside" initial="child">
          <history id="memory"><transition target="child"><raise event="history.default"/></transition></history>
          <state id="child"><onentry><raise event="child.entry"/></onentry></state>
        </state>
        <state id="outside"><transition event="restore" target="memory"/></state>
      </state>
      """)

    session = Fixture.session(chart, status: :active, configuration: ["outside"])
    assert {:ok, result} = Macrostep.run(chart, session, %{name: "restore"}, Fixture.options())
    discarded = Enum.filter(result.trace, &(&1["kind"] == "event_discarded"))
    assert Enum.map(discarded, & &1["event"]) == ["history.default", "child.entry"]
  end

  test "entry planning does not raise for a defensively malformed chart" do
    chart = history_chart("shallow")

    no_default =
      %{
        chart
        | states:
            Enum.map(
              chart.states,
              &if(&1.id == "memory", do: %{&1 | transition_ids: []}, else: &1)
            )
      }
      |> Map.update!(:metadata, &Map.put(&1, "root_initial", ["memory"]))

    assert %{atomic_ids: [], entry_ids: []} = EntryExit.initial_plan(no_default, %{})

    unknown_root = Map.update!(chart, :metadata, &Map.put(&1, "root_initial", ["missing"]))
    assert %{atomic_ids: [], entry_ids: []} = EntryExit.initial_plan(unknown_root, %{})
  end

  defp history_chart(type) do
    Fixture.chart("""
    <state id="root" initial="inside">
      <state id="inside" initial="a">
        <history id="memory" type="#{type}"><transition target="a"/></history>
        <state id="a" initial="a1">
          <state id="a1"/><state id="a2"><transition event="leave" target="outside"/></state>
        </state>
      </state>
      <state id="outside"><transition event="restore" target="memory"/></state>
    </state>
    """)
  end
end
