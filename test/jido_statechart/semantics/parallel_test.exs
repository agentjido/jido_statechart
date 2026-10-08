defmodule Jido.Statechart.Semantics.ParallelTest do
  use ExUnit.Case, async: true

  alias Jido.Statechart.SemanticFixture, as: Fixture
  alias Jido.Statechart.Semantics.Macrostep

  test "parallel initialization enters every region in document order" do
    chart =
      Fixture.chart("""
      <state id="root" initial="regions">
        <parallel id="regions">
          <state id="left" initial="left_a"><state id="left_a"/></state>
          <state id="right" initial="right_a"><state id="right_a"/></state>
        </parallel>
      </state>
      """)

    assert {:ok, result} = Macrostep.initialize(chart, Fixture.session(chart), Fixture.options())
    assert result.session.configuration == ["left_a", "right_a"]
    assert [%{"entered" => entered}] = result.trace
    assert entered == ["root", "regions", "left", "left_a", "right", "right_a"]
  end

  test "compound initial transition content runs after parent entry and before child entry" do
    chart =
      Fixture.chart("""
      <state id="root">
        <onentry><raise event="root.entry"/></onentry>
        <initial><transition target="child"><raise event="root.initial"/></transition></initial>
        <state id="child"><onentry><raise event="child.entry"/></onentry></state>
      </state>
      """)

    assert {:ok, result} = Macrostep.initialize(chart, Fixture.session(chart), Fixture.options())
    discarded = Enum.filter(result.trace, &(&1["kind"] == "event_discarded"))
    assert Enum.map(discarded, & &1["event"]) == ["root.entry", "root.initial", "child.entry"]
  end

  test "one microstep runs all exits, transition content, then entries in SCXML order" do
    chart =
      Fixture.chart("""
      <state id="root" initial="regions">
        <parallel id="regions">
          <state id="left_region" initial="left">
            <state id="left"><onexit><raise event="exit.left"/></onexit><transition event="go" target="done_left"><raise event="transition.left"/></transition></state>
            <final id="done_left"><onentry><raise event="entry.left"/></onentry></final>
          </state>
          <state id="right_region" initial="right">
            <state id="right"><onexit><raise event="exit.right"/></onexit><transition event="go" target="done_right"><raise event="transition.right"/></transition></state>
            <final id="done_right"><onentry><raise event="entry.right"/></onentry></final>
          </state>
        </parallel>
      </state>
      """)

    session = Fixture.session(chart, status: :active, configuration: ["left", "right"])
    assert {:ok, result} = Macrostep.run(chart, session, %{name: "go"}, Fixture.options())

    discarded =
      Enum.filter(result.trace, fn entry ->
        entry["kind"] == "event_discarded" and
          not String.starts_with?(entry["event"], "done.state.")
      end)

    assert Enum.map(discarded, & &1["event"]) == [
             "exit.right",
             "exit.left",
             "transition.left",
             "transition.right",
             "entry.left",
             "entry.right"
           ]

    assert result.session.configuration == ["done_left", "done_right"]
  end

  test "multi-target entry and targetless transition preserve legal configuration" do
    chart =
      Fixture.chart("""
      <state id="root" initial="start">
        <state id="start">
          <transition event="stay"><raise event="kept"/></transition>
          <transition event="split" target="left right"/>
        </state>
        <parallel id="regions"><state id="left"/><state id="right"/></parallel>
      </state>
      """)

    session = Fixture.session(chart, status: :active, configuration: ["start"])
    assert {:ok, stayed} = Macrostep.run(chart, session, %{name: "stay"}, Fixture.options())
    assert stayed.session.configuration == ["start"]

    assert {:ok, split} = Macrostep.run(chart, session, %{name: "split"}, Fixture.options())
    assert split.session.configuration == ["left", "right"]
  end
end
