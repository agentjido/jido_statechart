defmodule Jido.Statechart.Semantics.TransitionSelectionTest do
  use ExUnit.Case, async: true

  alias Jido.Statechart.Model.Event
  alias Jido.Statechart.SemanticFixture, as: Fixture
  alias Jido.Statechart.Semantics.{Configuration, Domain, Selection}

  test "W3C 403 descendant priority and document order select one transition" do
    chart =
      Fixture.chart("""
      <state id="root" initial="child">
        <transition event="go" target="parent_win"/>
        <state id="child">
          <transition event="go" target="first"/>
          <transition event="go" target="second"/>
        </state>
        <final id="first"/><final id="second"/><final id="parent_win"/>
      </state>
      """)

    assert {:ok, transitions, _workspace} =
             Selection.select(chart, ["child"], Event.new!(%{name: "go"}), %{}, Fixture.options())

    assert Enum.map(transitions, & &1.target_ids) == [["first"]]
  end

  test "a false descendant condition falls back to the matching ancestor transition" do
    chart =
      Fixture.chart(
        """
        <state id="root" initial="child">
          <transition event="go" target="parent_win"/>
          <state id="child"><transition event="go" cond="no" target="child_win"/></state>
          <final id="child_win"/><final id="parent_win"/>
        </state>
        """,
        datamodel: "jido"
      )

    registry = Fixture.registry([Fixture.expression("no", false)])

    assert {:ok, transitions, _workspace} =
             Selection.select(
               chart,
               ["child"],
               %{name: "go"},
               %{},
               Fixture.options(registry: registry)
             )

    assert Enum.map(transitions, & &1.target_ids) == [["parent_win"]]
  end

  test "event descriptors use exact token prefixes and wildcard matching" do
    assert Selection.event_match?("order", "order")
    assert Selection.event_match?("order", "order.created")
    assert Selection.event_match?("order.*", "order.created")
    assert Selection.event_match?("*", "anything")
    refute Selection.event_match?("order", "ordered")
    refute Selection.event_match?("Order", "order")
  end

  test "an authored condition failure enqueues error.execution and does not select it" do
    chart =
      Fixture.chart(
        """
        <state id="root" initial="child">
          <state id="child"><transition event="go" cond="not_boolean" target="done"/></state>
          <final id="done"/>
        </state>
        """,
        datamodel: "jido"
      )

    registry = Fixture.registry([Fixture.expression("not_boolean", 1)])

    assert {:ok, [], workspace} =
             Selection.select(
               chart,
               ["child"],
               %{name: "go"},
               %{},
               Fixture.options(registry: registry)
             )

    assert [%{"name" => "error.execution", "class" => "platform"}] = workspace.internal_queue
  end

  test "W3C 403 ancestor transition selected by two regions is executed once" do
    chart =
      Fixture.chart("""
      <state id="root" initial="regions">
        <parallel id="regions">
          <transition event="go"/>
          <state id="left"/><state id="right"/>
        </parallel>
      </state>
      """)

    assert {:ok, transitions, _workspace} =
             Selection.select(chart, ["left", "right"], %{name: "go"}, %{}, Fixture.options())

    assert length(transitions) == 1
    assert hd(transitions).source_id == "regions"
  end

  test "W3C 403 descendant conflict preempts an earlier ancestor transition" do
    chart =
      Fixture.chart("""
      <state id="root" initial="regions">
        <parallel id="regions">
          <transition event="go" target="left"/>
          <state id="left"/>
          <state id="right"><transition event="go" target="outside"/></state>
        </parallel>
        <final id="outside"/>
      </state>
      """)

    assert {:ok, transitions, _workspace} =
             Selection.select(chart, ["left", "right"], %{name: "go"}, %{}, Fixture.options())

    assert Enum.map(transitions, & &1.source_id) == ["right"]
  end

  test "transition domains distinguish targetless, internal descendant, and external self" do
    chart =
      Fixture.chart("""
      <state id="root" initial="parent">
        <state id="parent" initial="child">
          <transition event="none"/>
          <transition event="inside" type="internal" target="child"/>
          <transition event="self" target="parent"/>
          <state id="child"/>
        </state>
      </state>
      """)

    [targetless, internal, external] = chart.transitions
    assert Domain.transition_domain(chart, targetless, %{}) == nil
    assert Domain.transition_domain(chart, internal, %{}) == "parent"
    assert Domain.transition_domain(chart, external, %{}) == "root"
    assert Domain.exit_set(chart, [targetless], ["child"], %{}) == []
    assert Domain.exit_set(chart, [internal], ["child"], %{}) == ["child"]
    assert Domain.exit_set(chart, [external], ["child"], %{}) == ["child", "parent"]
  end

  test "configuration is a legal ordered set of atomic states" do
    chart =
      Fixture.chart("""
      <state id="root" initial="regions">
        <parallel id="regions"><state id="left"/><state id="right"/></parallel>
      </state>
      """)

    assert {:ok, ["left", "right"]} = Configuration.canonical(chart, ["right", "left"])
    assert :ok = Configuration.validate(chart, ["left", "right"])
    assert {:error, %{code: :illegal_configuration}} = Configuration.validate(chart, ["left"])
    assert {:error, %{code: :invalid_configuration}} = Configuration.canonical(chart, ["root"])
  end
end
