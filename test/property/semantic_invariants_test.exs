defmodule Jido.Statechart.SemanticInvariantsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Jido.Statechart.SemanticFixture, as: Fixture
  alias Jido.Statechart.Semantics.{Configuration, Macrostep}

  property "canonical parallel configurations have stable document order" do
    chart =
      Fixture.chart("""
      <state id="root" initial="regions">
        <parallel id="regions"><state id="a"/><state id="b"/><state id="c"/></parallel>
      </state>
      """)

    check all(ids <- member_of([~w(a b c), ~w(c b a), ~w(b a c)]), max_runs: 15) do
      assert {:ok, ~w(a b c)} = Configuration.canonical(chart, ids)
      assert :ok = Configuration.validate(chart, ~w(a b c))
    end
  end

  property "deep history replay restores the same legal atomic state" do
    chart =
      Fixture.chart("""
      <state id="root" initial="inside">
        <state id="inside" initial="a">
          <history id="memory" type="deep"><transition target="a"/></history>
          <state id="a"><transition event="leave" target="outside"/></state>
          <state id="b"><transition event="leave" target="outside"/></state>
        </state>
        <state id="outside"><transition event="restore" target="memory"/></state>
      </state>
      """)

    check all(active <- member_of(["a", "b"]), max_runs: 10) do
      session = Fixture.session(chart, status: :active, configuration: [active])
      assert {:ok, outside} = Macrostep.run(chart, session, %{name: "leave"}, Fixture.options())

      assert {:ok, restored} =
               Macrostep.run(chart, outside.session, %{name: "restore"}, Fixture.options())

      assert restored.session.configuration == [active]
      assert :ok = Configuration.validate(chart, restored.session.configuration)
    end
  end
end
