defmodule Jido.Statechart.SCXML.RereviewRegressionTest do
  use ExUnit.Case, async: true

  alias Jido.Statechart.{Diagnostic, SCXML}

  @scxml "http://www.w3.org/2005/07/scxml"

  test "assign requires one expression or one ordered inline value" do
    assert {:error, %Diagnostic{code: :mutually_exclusive_content}} =
             compile_onentry(~s(<assign location="result"/>))

    assert {:error, %Diagnostic{code: :mutually_exclusive_content}} =
             compile_onentry(~s(<assign location="result" expr="value">inline</assign>))

    assert {:ok, chart} =
             compile_onentry(
               ~s(<assign location="result">one<![CDATA[<two>]]><value xmlns="urn:data">three</value>four</assign>)
             )

    [assign] = hd(chart.states).on_entry

    assert assign.data["content"]["items"] == [
             %{"kind" => "text", "value" => "one"},
             %{"kind" => "cdata", "value" => "<two>"},
             %{
               "kind" => "element",
               "value" => %{
                 "name" => %{"namespace" => "urn:data", "local" => "value"},
                 "attributes" => [],
                 "content" => [%{"kind" => "text", "value" => "three"}]
               }
             },
             %{"kind" => "text", "value" => "four"}
           ]
  end

  test "history-only parents and history default targets that are history nodes are invalid" do
    history_only =
      document(~s(<state id="parent"><history id="h"><transition target="h"/></history></state>))

    assert {:error, %Diagnostic{code: :invalid_history, profile_feature: "history_shallow"}} =
             SCXML.compile(history_only)

    history_target =
      document("""
      <state id="parent">
        <history id="first"><transition target="second"/></history>
        <history id="second"><transition target="child"/></history>
        <state id="child"/>
      </state>
      """)

    assert {:error, %Diagnostic{code: :illegal_target_set, profile_feature: "history_shallow"}} =
             SCXML.compile(history_target)
  end

  test "stops at an unsupported entity reference but ignores ampersands in comments and CDATA" do
    owner = self()

    chunks =
      ["<scxml xmlns=\"#{@scxml}\" version=\"1.0\"><state id=\"s\">&cus", "tom;", "later"]
      |> Stream.map(fn chunk ->
        if chunk == "later", do: send(owner, :enumerated_after_entity)
        chunk
      end)

    assert {:error,
            %Diagnostic{
              code: :unsupported_entity_reference,
              profile_feature: "restricted_xml"
            }} = SCXML.compile_stream(chunks)

    refute_received :enumerated_after_entity

    safe =
      document(
        ~s(<!-- &custom; --><state id="s"><onentry><send><content><![CDATA[&custom;]]></content></send></onentry></state>)
      )

    assert {:ok, chart} = SCXML.compile_stream(Enum.map(:binary.bin_to_list(safe), &<<&1>>))
    [send] = hd(chart.states).on_entry

    assert send.data["content"]["items"] == [
             %{"kind" => "cdata", "value" => "&custom;"}
           ]
  end

  test "foreign inline element IDs do not join the SCXML ID namespace" do
    xml =
      document(
        ~s(<state id="same"><onentry><send><content><send xmlns="urn:data" id="same"/></content></send></onentry></state>)
      )

    assert {:ok, _chart} = SCXML.compile(xml)

    scxml_id =
      document(
        ~s(<state id="same"><onentry><send><content><state id="same"/></content></send></onentry></state>)
      )

    assert {:error, %Diagnostic{code: :duplicate_id}} = SCXML.compile(scxml_id)
  end

  test "compiler diagnostics use the producing profile feature" do
    assert {:error, %Diagnostic{profile_feature: "state_atomic"}} =
             SCXML.compile(document(~s(<state id="same"/><state id="same"/>)))

    assert {:error, %Diagnostic{profile_feature: "assign_element"}} =
             compile_onentry(~s(<assign location="result"/>))

    assert {:error, %Diagnostic{profile_feature: "restricted_xml"}} =
             SCXML.compile(document(~s(<state id="s">&custom;</state>)))
  end

  test "validates invoke autoforward as a W3C boolean" do
    assert {:error,
            %Diagnostic{
              code: :invalid_autoforward,
              profile_feature: "invoke_scxml_element"
            }} =
             SCXML.compile(
               document(~s(<state id="s"><invoke src="child" autoforward="yes"/></state>))
             )

    assert {:ok, _chart} =
             SCXML.compile(
               document("""
               <state id="s">
                 <invoke src="first" autoforward="true"/>
                 <invoke src="second" autoforward="false"/>
               </state>
               """)
             )
  end

  test "validates cancel sendid as an XML ID reference" do
    assert {:error, %Diagnostic{code: :invalid_id, profile_feature: "cancel_element"}} =
             compile_onentry(~s(<cancel sendid="bad id"/>))

    assert {:ok, _chart} = compile_onentry(~s(<cancel sendid="pending"/>))
  end

  test "requires foreach to contain executable content" do
    assert {:error,
            %Diagnostic{
              code: :invalid_element_cardinality,
              profile_feature: "foreach_element"
            }} =
             compile_onentry(~s(<foreach array="items" item="item"/>))

    assert {:ok, _chart} =
             compile_onentry(
               ~s(<foreach array="items" item="item"><raise event="next"/></foreach>)
             )
  end

  defp compile_onentry(executable) do
    SCXML.compile(document(~s(<state id="s"><onentry>#{executable}</onentry></state>)))
  end

  defp document(body) do
    ~s(<scxml xmlns="#{@scxml}" version="1.0">#{body}</scxml>)
  end
end
