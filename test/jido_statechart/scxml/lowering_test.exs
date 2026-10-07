defmodule Jido.Statechart.SCXML.LoweringTest do
  use ExUnit.Case, async: true

  alias Jido.Statechart.{Diagnostic, SCXML}

  @content_fixture Path.expand("../../fixtures/scxml/content.scxml", __DIR__)
  @uri "http://www.w3.org/2005/07/scxml"

  test "preserves CDATA and mixed content as portable executable data" do
    assert {:ok, chart} = @content_fixture |> File.read!() |> SCXML.compile()
    [transition] = chart.transitions
    [send] = transition.executable

    assert send.kind == :send

    assert send.data["content"]["items"] == [
             %{"kind" => "text", "value" => "Hello "},
             %{"kind" => "cdata", "value" => "<safe>"},
             %{"kind" => "text", "value" => " "},
             %{
               "kind" => "element",
               "value" => %{
                 "name" => %{"namespace" => "urn:example:data", "local" => "payload"},
                 "attributes" => [
                   %{
                     "name" => %{"namespace" => nil, "local" => "code"},
                     "value" => "200"
                   }
                 ],
                 "content" => [%{"kind" => "text", "value" => "world"}]
               }
             },
             %{"kind" => "text", "value" => "!"}
           ]

    assert :ok = Jido.PortableTerm.validate(send.data, :content)
  end

  test "rejects duplicate IDs, illegal target sets, and unknown profile elements" do
    assert {:error, %Diagnostic{code: :duplicate_id, path: path}} =
             compile_body(~s(<state id="same"/><state id="same"/>))

    assert path != []

    assert {:error, %Diagnostic{code: :illegal_target_set}} =
             compile_body("""
             <parallel id="p">
               <state id="left"><state id="left_child"/></state>
               <state id="right"/>
               <transition event="bad" target="left left_child"/>
             </parallel>
             """)

    assert {:error,
            %Diagnostic{code: :unknown_profile_element, profile_feature: "unknown_element"}} =
             compile_body(~s(<state id="s"><unknown/></state>))
  end

  test "lowers compound, parallel, final, and history states in document order" do
    assert {:ok, chart} =
             compile_body("""
             <state id="root" initial="regions">
               <parallel id="regions">
                 <state id="left" initial="left_child">
                   <history id="left_history" type="deep"><transition target="left_child"/></history>
                   <state id="left_child"/>
                 </state>
                 <state id="right_region"><final id="right"/></state>
               </parallel>
             </state>
             """)

    assert Enum.map(chart.states, &{&1.id, &1.kind, &1.parent}) == [
             {"root", :compound, nil},
             {"regions", :parallel, "root"},
             {"left", :compound, "regions"},
             {"left_history", :history_deep, "left"},
             {"left_child", :atomic, "left"},
             {"right_region", :compound, "regions"},
             {"right", :final, "right_region"}
           ]
  end

  test "lowers supported data and executable content without executable authority" do
    xml = """
    <scxml xmlns="#{@uri}" xmlns:j="urn:jido:statechart:1" version="1.0"
           name="complete" datamodel="jido" binding="late" initial="root">
      <datamodel><data id="global" expr="global_expr"/></datamodel>
      <state id="root" initial="work">
        <datamodel><data id="local"><value xmlns="urn:data">safe</value></data></datamodel>
        <onentry>
          <raise event="entered"/>
          <if cond="ready"><log label="yes" expr="message"/><elseif cond="later"/><else/></if>
          <foreach array="items" item="item" index="index"><assign location="seen" expr="item"/></foreach>
          <send event="notice" target="parent"><param name="id" expr="item"/></send>
          <send><content>body</content></send>
          <cancel sendid="pending"/>
          <j:action id="record" params="{}"/>
        </onentry>
        <onexit><log label="leaving"/></onexit>
        <invoke type="jido" src="worker" id="worker"><finalize><raise event="finalized"/></finalize></invoke>
        <state id="work">
          <transition event="finish" cond="allowed" target="done" type="internal">
            <assign location="result" expr="value"/>
          </transition>
        </state>
        <final id="done"><donedata><content>ok</content></donedata></final>
      </state>
    </scxml>
    """

    assert {:ok, chart} = SCXML.compile(xml)
    assert chart.datamodel == "jido"
    assert chart.binding == "late"
    assert chart.metadata["root_initial"] == ["root"]
    assert chart.metadata["root_data"]["global"]["expr"] == "global_expr"
    assert [%{"attributes" => %{"id" => "worker"}}] = chart.metadata["invocations"]["root"]

    [root, work, done] = chart.states

    assert root.data["local"]["content"]["items"] == [
             %{
               "kind" => "element",
               "value" => %{
                 "name" => %{"namespace" => "urn:data", "local" => "value"},
                 "attributes" => [],
                 "content" => [%{"kind" => "text", "value" => "safe"}]
               }
             }
           ]

    assert Enum.map(root.on_entry, & &1.kind) == [
             :raise,
             :if,
             :foreach,
             :send,
             :send,
             :cancel,
             :action
           ]

    assert Enum.map(root.on_exit, & &1.kind) == [:log]

    [event_send, content_send] = Enum.filter(root.on_entry, &(&1.kind == :send))
    assert event_send.data["params"] == [%{"expr" => "item", "name" => "id"}]

    assert content_send.data["content"]["items"] == [
             %{"kind" => "text", "value" => "body"}
           ]

    conditional = Enum.find(root.on_entry, &(&1.kind == :if))
    assert Enum.map(conditional.data["branches"], & &1["kind"]) == ["if", "elseif", "else"]

    assert done.done_data["content"]["items"] == [%{"kind" => "text", "value" => "ok"}]

    assert [%{source_id: "work", target_ids: ["done"], type: :internal}] = chart.transitions
    assert work.transition_ids == [hd(chart.transitions).id]
  end

  test "records data declaration document order" do
    xml = """
    <scxml xmlns="#{@uri}" version="1.0" datamodel="jido">
      <datamodel>
        <data id="z" expr="z_value"/>
        <data id="a" expr="copy_z"/>
      </datamodel>
      <state id="ready"/>
    </scxml>
    """

    assert {:ok, chart} = SCXML.compile(xml)
    assert chart.metadata["root_data"]["z"]["ordinal"] == 0
    assert chart.metadata["root_data"]["a"]["ordinal"] == 1
  end

  test "accepts legal multi-target transitions across parallel regions" do
    assert {:ok, chart} =
             compile_body("""
             <state id="source">
               <transition event="split" target="left right"/>
             </state>
             <parallel id="p">
               <state id="left_region"><state id="left"/></state>
               <state id="right_region"><state id="right"/></state>
             </parallel>
             """)

    assert [%{target_ids: ["left", "right"]}] = chart.transitions
  end

  test "preserves initial transition content and real transition document order" do
    assert {:ok, chart} =
             compile_body("""
             <state id="root">
               <state id="first"><transition event="child"/></state>
               <transition event="parent"/>
               <initial><transition target="first"><raise event="boot"/></transition></initial>
             </state>
             """)

    assert Enum.map(chart.transitions, & &1.events) == [["child"], ["parent"]]
    assert [%{"kind" => "raise"}] = chart.metadata["initial_transition_content"]["root"]
  end

  test "rejects invalid root and state initial targets" do
    assert {:error, %Diagnostic{code: :invalid_initial}} =
             SCXML.compile(
               ~s(<scxml xmlns="#{@uri}" version="1.0" initial="missing"><state id="s"/></scxml>)
             )

    assert {:error, %Diagnostic{code: :invalid_initial}} =
             compile_body(~s(<state id="s" initial="missing"><state id="child"/></state>))
  end

  test "accepts legal multi-target initial specifications in nested parallel regions" do
    xml = """
    <scxml xmlns="#{@uri}" version="1.0" initial="left_active right_active">
      <parallel id="root">
        <state id="left"><state id="left_active"/></state>
        <state id="right"><state id="right_active"/></state>
      </parallel>
    </scxml>
    """

    assert {:ok, chart} = SCXML.compile(xml)
    assert chart.metadata["root_initial"] == ["left_active", "right_active"]

    state_xml = """
    <state id="wrapper" initial="left_active right_active">
      <parallel id="regions">
        <state id="left"><state id="left_active"/></state>
        <state id="right"><state id="right_active"/></state>
      </parallel>
    </state>
    """

    assert {:ok, chart} = compile_body(state_xml)
    assert hd(chart.states).initial == ["left_active", "right_active"]
  end

  defp compile_body(body) do
    SCXML.compile(~s(<scxml xmlns="#{@uri}" version="1.0">#{body}</scxml>))
  end
end
