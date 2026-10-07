defmodule Jido.Statechart.Semantics.CompletionTest do
  use ExUnit.Case, async: true

  alias Jido.Statechart.SemanticFixture, as: Fixture
  alias Jido.Statechart.Semantics.Macrostep

  test "compound and parallel completion events are appended in deterministic order" do
    chart =
      Fixture.chart("""
      <state id="root" initial="regions">
        <parallel id="regions">
          <state id="left" initial="left_done"><final id="left_done"/></state>
          <state id="right" initial="right_done"><final id="right_done"/></state>
        </parallel>
      </state>
      """)

    assert {:ok, result} = Macrostep.initialize(chart, Fixture.session(chart), Fixture.options())

    discarded = Enum.filter(result.trace, &(&1["kind"] == "event_discarded"))

    assert Enum.map(discarded, & &1["event"]) == [
             "done.state.left",
             "done.state.right",
             "done.state.regions"
           ]
  end

  test "top-level final completes once and keeps constructed donedata" do
    chart =
      Fixture.chart("""
      <state id="root">
        <onexit><send event="root.exit" target="parent"/></onexit>
        <transition event="finish" target="done"/>
      </state>
      <final id="done">
        <onexit><send event="done.exit" target="parent"/></onexit>
        <donedata><content>complete</content></donedata>
      </final>
      """)

    session = Fixture.session(chart, status: :active, configuration: ["root"])
    assert {:ok, result} = Macrostep.run(chart, session, %{name: "finish"}, Fixture.options())
    assert result.session.status == :completed
    assert result.session.configuration == []
    assert result.session.completion_data == "complete"
    assert Enum.map(result.intents, & &1["event"]) == ["root.exit", "done.exit"]
    assert List.last(result.trace)["kind"] == "terminal_exit"
    assert List.last(result.trace)["exited"] == ["done"]

    assert {:error, %{code: :session_completed}} =
             Macrostep.run(chart, result.session, %{name: "again"}, Fixture.options())
  end

  test "authored donedata failures become error.execution without invalidating completion" do
    chart =
      Fixture.chart(
        """
        <state id="root"><transition event="finish" target="done"/></state>
        <final id="done"><donedata><content expr="missing"/></donedata></final>
        """,
        datamodel: "jido"
      )

    session = Fixture.session(chart, status: :active, configuration: ["root"])
    assert {:ok, result} = Macrostep.run(chart, session, %{name: "finish"}, Fixture.options())
    assert result.session.status == :completed
    assert result.session.configuration == []
    assert result.session.completion_data == nil

    assert [%{"name" => "error.execution", "class" => "platform"}] =
             result.session.internal_queue
  end

  test "nested parallel completion walks complete ancestors inner to outer once" do
    chart =
      Fixture.chart("""
      <state id="root" initial="outer">
        <parallel id="outer">
          <state id="right" initial="right_done"><final id="right_done"/></state>
          <parallel id="inner">
            <state id="left" initial="left_done"><final id="left_done"/></state>
            <state id="middle" initial="middle_done"><final id="middle_done"/></state>
          </parallel>
        </parallel>
      </state>
      """)

    assert {:ok, result} = Macrostep.initialize(chart, Fixture.session(chart), Fixture.options())

    names = Enum.map(result.trace, & &1["event"])
    assert Enum.count(names, &(&1 == "done.state.inner")) == 1
    assert Enum.count(names, &(&1 == "done.state.outer")) == 1

    assert Enum.find_index(names, &(&1 == "done.state.inner")) <
             Enum.find_index(names, &(&1 == "done.state.outer"))
  end
end
