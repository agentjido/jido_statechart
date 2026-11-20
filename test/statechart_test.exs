defmodule Jido.StatechartTest do
  use ExUnit.Case, async: true

  alias Jido.{Agent, Signal}
  alias Jido.Statechart

  defmodule Chart do
    use Jido.Statechart,
      chart: ~SCXML"""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
        <state id="ready">
          <transition event="touch"/>
          <transition event="finish stop.*" target="completed"/>
        </state>
        <final id="completed"/>
      </scxml>
      """
  end

  defmodule FixtureAgent do
    use Jido.Agent,
      name: "statechart_test",
      plugins: [{Jido.Statechart.Plugin, %{chart: Chart}}]

    routes do
      route("**", Jido.Statechart.Plugin.Route)
    end
  end

  test "a chart must initialize before use and stops processing events when complete" do
    agent = FixtureAgent.instantiate!(id: "chart")
    init = Statechart.initialization_signal(%{})
    malformed_init = Signal.new!("statechart.initialize", %{}, source: "/test")
    touch = Signal.new!("touch", %{}, source: "/test")
    finish = Signal.new!("stop.review", %{}, source: "/test")

    assert {:error, _reason} = Agent.cmd(agent, malformed_init)
    assert {:error, _reason} = Agent.cmd(agent, finish)
    assert {:ok, ready, _directives} = Agent.cmd(agent, init)
    assert {:error, _reason} = Agent.cmd(ready, init)
    assert {:ok, touched, _directives} = Agent.cmd(ready, touch)
    assert touched.state.statechart.session.state == "ready"
    assert touched.state.statechart.session.event.name == "touch"
    assert {:ok, completed, _directives} = Agent.cmd(touched, finish)
    assert completed.state.statechart.session.status == :completed
    assert {:ok, ^completed, []} = Agent.cmd(completed, finish)
  end

  test "the compiler rejects unknown transition targets and duplicate IDs" do
    assert_raise ArgumentError, ~r/unknown SCXML transition target/, fn ->
      Statechart.compile!(document(~s(<state id="s"><transition target="missing"/></state>)))
    end

    assert_raise ArgumentError, ~r/duplicate SCXML state id/, fn ->
      Statechart.compile!(document(~s(<state id="s"/><final id="s"/>)))
    end

    assert_raise ArgumentError, ~r/initial state does not exist/, fn ->
      Statechart.compile!(document(""))
    end
  end

  test "the compiler rejects initial targets outside their compound state" do
    for target <- ["", "parent", "outside"] do
      assert_raise ArgumentError, ~r/invalid SCXML initial target/, fn ->
        Statechart.compile!(
          document(
            ~s(<state id="parent" initial="#{target}"><state id="child"/></state><state id="outside"/>)
          )
        )
      end
    end
  end

  test "multiple targets require distinct parallel regions" do
    for markup <- [
          ~s(<state id="parent" initial="a b"><state id="a"/><state id="b"/></state>),
          ~s(<state id="parent"><transition target="a b"/><state id="a"/><state id="b"/></state>),
          """
          <state id="start"><transition target="previous a2"/></state>
          <parallel id="p">
            <history id="previous" type="deep"><transition target="a1 b1"/></history>
            <state id="a"><state id="a1"/><state id="a2"/></state>
            <state id="b"><state id="b1"/></state>
          </parallel>
          """
        ] do
      assert_raise ArgumentError, ~r/separate parallel regions/, fn ->
        Statechart.compile!(document(markup))
      end
    end
  end

  test "initialization keeps caller values literal and applies overrides only at the root" do
    chart =
      Statechart.compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="jido">
        <datamodel><data id="input" expr="0"/></datamodel>
        <state id="ready"><datamodel><data id="nested" expr="42"/></datamodel></state>
      </scxml>
      """)

    agent =
      Jido.Statechart.Plugin.agent_definition("literal_input", chart, %{})
      |> Agent.instantiate!(id: "literal")

    input = {:invalid_expression, "literal tuple"}
    signal = Statechart.initialization_signal(%{"input" => input, "nested" => 7})

    assert {:ok, agent, _} = Agent.cmd(agent, signal)

    assert %{data: %{"input" => ^input, "nested" => 42}, event: nil} =
             agent.state.statechart.session
  end

  test "a guard that cannot evaluate queues an error and permits the next transition" do
    chart =
      Statechart.compile!(
        document("""
        <state id="ready">
          <transition cond="missing_guard" target="fail"/>
          <transition target="recover"/>
        </state>
        <state id="recover"><transition event="error.execution" target="pass"/></state>
        <final id="fail"/>
        <final id="pass"/>
        """)
      )

    agent =
      Jido.Statechart.Plugin.agent_definition("guard_error", chart, %{})
      |> Agent.instantiate!(id: "guard")

    assert {:ok, agent, _} = Agent.cmd(agent, Statechart.initialization_signal(%{}))

    assert %{status: :completed, state: "pass", event: %{name: "error.execution"}} =
             agent.state.statechart.session
  end

  test "a top-level final runs its exit handler before it returns data" do
    chart =
      Statechart.compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="jido">
        <datamodel><data id="count" expr="1"/></datamodel>
        <final id="finished">
          <onexit><assign location="count" expr="2"/></onexit>
          <donedata><param name="count" location="count"/></donedata>
        </final>
      </scxml>
      """)

    agent =
      Jido.Statechart.Plugin.agent_definition("terminal_exit", chart, %{})
      |> Agent.instantiate!(id: "terminal")

    assert {:ok, completed, _} = Agent.cmd(agent, Statechart.initialization_signal(%{}))

    assert %{
             state: "finished",
             status: :completed,
             configuration: [],
             completion: %{"count" => 2}
           } =
             completed.state.statechart.session
  end

  test "a failed if condition queues an error and evaluates the next branch" do
    chart =
      Statechart.compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="jido">
        <datamodel><data id="choice"/><data id="followed"/></datamodel>
        <state id="ready">
          <onentry>
            <if cond="missing">
              <assign location="choice" expr="1"/>
              <else/>
              <assign location="choice" expr="2"/>
            </if>
            <assign location="followed" expr="true"/>
          </onentry>
          <transition event="error.execution" target="pass"/>
        </state>
        <final id="pass"/>
      </scxml>
      """)

    agent = Jido.Statechart.Plugin.agent_definition("if_error", chart, %{})
    agent = Agent.instantiate!(agent, id: "if")
    assert {:ok, agent, _} = Agent.cmd(agent, Statechart.initialization_signal(%{}))

    assert %{state: "pass", data: %{"choice" => 2, "followed" => true}} =
             agent.state.statechart.session
  end

  test "an empty foreach declares missing variables and keeps existing values" do
    chart =
      Statechart.compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="jido">
        <datamodel><data id="items" expr="[]"/><data id="index" expr="8"/></datamodel>
        <state id="ready">
          <onentry>
            <foreach array="items" item="item" index="index">
              <assign location="index" expr="0"/>
            </foreach>
          </onentry>
        </state>
      </scxml>
      """)

    agent = Jido.Statechart.Plugin.agent_definition("empty_foreach", chart, %{})
    agent = Agent.instantiate!(agent, id: "foreach")
    assert {:ok, agent, _} = Agent.cmd(agent, Statechart.initialization_signal(%{}))
    assert %{"item" => nil, "index" => 8} = agent.state.statechart.session.data
  end

  test "selected transition actions run in XML document order" do
    chart =
      Statechart.compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="jido">
        <datamodel><data id="count"/></datamodel>
        <parallel id="parent">
          <transition event="write"><assign location="count" expr="1"/></transition>
          <state id="first">
            <transition event="write"><assign location="count" expr="2"/></transition>
          </state>
          <state id="second"/>
        </parallel>
      </scxml>
      """)

    agent =
      Jido.Statechart.Plugin.agent_definition("transition_order", chart, %{})
      |> Agent.instantiate!(id: "parallel")

    assert {:ok, agent, _} = Agent.cmd(agent, Statechart.initialization_signal(%{}))
    assert {:ok, agent, _} = Agent.cmd(agent, Signal.new!("write", %{}, source: "/test"))
    assert agent.state.statechart.session.data["count"] == 2
  end

  test "the compiler rejects XML outside the supported subset" do
    unsupported = Jido.Statechart.SCXML.Unsupported

    assert_raise unsupported, ~r/document types/, fn ->
      Statechart.compile!("<!DOCTYPE scxml>" <> document(~s(<state id="s"/>)))
    end

    assert_raise unsupported, ~r/state element/, fn ->
      Statechart.compile!(document(~s(<state id="s"><script/></state>)))
    end

    assert_raise ArgumentError, ~r/invalid SCXML initial declaration/, fn ->
      Statechart.compile!(document(~s(<state id="s" initial="child"/>)))
    end

    assert_raise unsupported, ~r/unexpected text/, fn ->
      Statechart.compile!(document(~s(<state id="s">invalid</state>)))
    end

    assert_raise ArgumentError, ~r/expected an SCXML root/, fn ->
      Statechart.compile!("<state/>")
    end

    assert_raise ArgumentError, fn ->
      Statechart.compile!("<scxml")
    end

    assert_raise ArgumentError, ~r/missing SCXML id/, fn ->
      Statechart.compile!(document(~s(<state id=""/>)))
    end
  end

  test "the sigil rejects modifiers and non-literal input" do
    assert_raise ArgumentError, ~r/no modifiers/, fn ->
      Code.eval_string(~S(import Jido.Statechart; ~SCXML"<state/>"x))
    end

    assert_raise ArgumentError, ~r/literal XML/, fn ->
      Code.eval_quoted(
        quote do
          require Jido.Statechart
          Jido.Statechart.sigil_SCXML(System.get_env("SCXML"), [])
        end
      )
    end
  end

  test "the XML reader resolves prefixes and preserves ordered text" do
    chart =
      Statechart.compile!("""
      <s:scxml xmlns:s="http://www.w3.org/2005/07/scxml" version="1.0">
        <s:final id="finished">
          <s:donedata><s:content>α<![CDATA[β]]>&amp;γ</s:content></s:donedata>
        </s:final>
      </s:scxml>
      <!-- trailing comment -->
      """)

    assert chart.states["finished"].completion == "αβ&γ"
  end

  test "the XML reader rejects undeclared prefixes and content after the root" do
    for xml <- [document(~s(<p:state id="s"/>)), document(~s(<state p:id="s"/>))] do
      assert_raise ArgumentError, ~r/undeclared namespace prefix p/, fn ->
        Statechart.compile!(xml)
      end
    end

    assert_raise ArgumentError, ~r/expected one XML document/, fn ->
      Statechart.compile!(document(~s(<state id="s"/>)) <> "<other/>")
    end
  end

  test "the XML reader rejects a DOCTYPE in UTF-16" do
    xml = "<!DOCTYPE scxml [<!ELEMENT scxml ANY>]>" <> document(~s(<state id="s"/>))
    utf16 = <<0xFF, 0xFE>> <> :unicode.characters_to_binary(xml, :utf8, {:utf16, :little})

    assert_raise Jido.Statechart.SCXML.Unsupported, ~r/document types/, fn ->
      Statechart.compile!(utf16)
    end
  end

  test "the compiler rejects unsupported literal invoke types" do
    unsupported = Jido.Statechart.SCXML.Unsupported

    assert_raise unsupported, ~r/invoke type/, fn ->
      Statechart.compile!(
        document(~s(<state id="s"><invoke id="one" src="urn:child" type="other"/></state>))
      )
    end
  end

  test "an eventless loop fails its turn without changing the session" do
    chart =
      Statechart.compile!(document(~s(<state id="loop"><transition target="loop"/></state>)))

    plugin = Jido.Statechart.Plugin

    agent =
      Agent.define!(%{
        name: "statechart_loop",
        plugins: [%{id: plugin.id(), provider: plugin, vsn: plugin.vsn(), data: %{chart: chart}}]
      })
      |> Agent.instantiate!(id: "loop")

    assert {:error, _reason} = Agent.cmd(agent, Statechart.initialization_signal(%{}))
    assert agent.state.statechart.session == nil
  end

  defp document(content),
    do: ~s(<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">#{content}</scxml>)
end
