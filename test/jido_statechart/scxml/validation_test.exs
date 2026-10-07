defmodule Jido.Statechart.SCXML.ValidationTest do
  use ExUnit.Case, async: true

  alias Jido.Statechart.{Diagnostic, SCXML}

  @uri "http://www.w3.org/2005/07/scxml"

  test "rejects unsupported root contracts" do
    cases = [
      {~s(<scxml version="1.0"><state id="s"/></scxml>), :invalid_scxml_root},
      {~s(<scxml xmlns="#{@uri}"><state id="s"/></scxml>), :missing_required_attribute},
      {document("", version: "2.0"), :unsupported_scxml_version},
      {document("", datamodel: "ecmascript"), :unsupported_datamodel},
      {document("", binding: "other"), :unsupported_binding},
      {~s(<scxml xmlns="#{@uri}" version="1.0"><datamodel/></scxml>), :missing_root_state}
    ]

    for {xml, code} <- cases do
      assert {:error, %Diagnostic{code: ^code}} = SCXML.compile(xml)
    end
  end

  test "rejects unsupported elements, attributes, placement, and text" do
    cases = [
      {body(~s(<state id="s" unknown="x"/>)), :unknown_profile_attribute},
      {body(~s(<state xmlns:x="urn:x" x:value="x" id="s"/>)), :unknown_profile_attribute},
      {body(~s(<state id="s"><script>unsafe</script></state>)), :unsupported_script},
      {body(~s(<state id="s"><data id="x"/></state>)), :invalid_element_placement},
      {body(~s(<state id="s">unexpected</state>)), :unexpected_xml_text},
      {body(~s(<state id="s"><foreign xmlns="urn:foreign"/></state>)), :unknown_profile_element},
      {body(~s(<state id="s"><scxml version="1.0"/></state>)), :invalid_element_placement}
    ]

    for {xml, code} <- cases do
      assert {:error, %Diagnostic{code: ^code}} = SCXML.compile(xml)
    end
  end

  test "rejects invalid state, transition, and data declarations" do
    cases = [
      {body(~s(<state id="bad id"/>)), :invalid_id},
      {body(~s(<state id="s"><history type="sideways"/></state>)), :invalid_history_type},
      {body(~s(<state id="s"><transition type="sideways"/></state>)), :invalid_transition_type},
      {body(~s(<state id="s"><transition event=""/></state>)), :invalid_attribute_value},
      {body(~s(<state id="s"><datamodel><data/></datamodel></state>)),
       :missing_required_attribute},
      {body(~s(<state id="s"><datamodel><data id="user.name"/></datamodel></state>)),
       :invalid_id},
      {body(~s(<state id="s"><onentry><raise/></onentry></state>)), :missing_required_attribute},
      {body(~s(<state id="s"><onentry><if/></onentry></state>)), :missing_required_attribute},
      {body(~s(<state id="s"><onentry><if cond="x"><elseif/></if></onentry></state>)),
       :missing_required_attribute},
      {body(~s(<state id="s"><onentry><foreach item="x"/></onentry></state>)),
       :missing_required_attribute},
      {body(~s(<state id="s"><onentry><foreach array="x"/></onentry></state>)),
       :missing_required_attribute},
      {body(~s(<state id="s"><onentry><assign/></onentry></state>)), :missing_required_attribute},
      {body(~s(<state id="s"><onentry><cancel/></onentry></state>)), :invalid_cancel},
      {body(~s(<state id="s"><onentry><cancel sendid="a" sendidexpr="b"/></onentry></state>)),
       :invalid_cancel},
      {body(~s(<state id="s"><invoke type="scxml" src="file:///secret"/></state>)),
       :external_source_unsupported},
      {body(~s(<state id="s"><transition target="a a"/></state>)), :invalid_id_list}
    ]

    for {xml, code} <- cases do
      assert {:error, %Diagnostic{code: ^code}} = SCXML.compile(xml)
    end
  end

  test "reserves the system-generated identifier prefix from authors" do
    prefix = "__jido_scxml_generated_"

    for xml <- [
          body(~s(<state id="#{prefix}state"/>)),
          body(
            ~s(<state id="s"><onentry><send event="work" id="#{prefix}send"/></onentry></state>)
          )
        ] do
      assert {:error, %Diagnostic{code: :reserved_generated_id}} = SCXML.compile(xml)
    end
  end

  test "rejects ambiguous initial and history declarations" do
    cases = [
      body(
        ~s(<state id="s" initial="a"><initial><transition target="a"/></initial><state id="a"/></state>)
      ),
      body(~s(<state id="s"><initial/></state>)),
      body(~s(<state id="s"><initial><transition/></initial></state>)),
      body(~s(<state id="s"><initial><transition event="x" target="s"/></initial></state>)),
      body(
        ~s(<state id="s"><history><transition target="s"/><transition target="s"/></history></state>)
      )
    ]

    for xml <- cases do
      assert {:error, %Diagnostic{code: code}} = SCXML.compile(xml)
      assert code in [:invalid_initial, :invalid_history]
    end
  end

  test "validates Jido action extension as data only" do
    assert {:ok, chart} =
             body(
               ~s(<state id="s"><onentry><j:action xmlns:j="urn:jido:statechart:1" id="work"/></onentry></state>)
             )
             |> SCXML.compile()

    assert [%{kind: :action, data: %{"id" => "work"}}] = hd(chart.states).on_entry

    assert {:error, %Diagnostic{code: :missing_required_attribute}} =
             body(
               ~s(<state id="s"><onentry><j:action xmlns:j="urn:jido:statechart:1"/></onentry></state>)
             )
             |> SCXML.compile()

    assert {:error, %Diagnostic{code: :invalid_element_placement}} =
             body(~s(<j:action xmlns:j="urn:jido:statechart:1" id="work"/><state id="s"/>))
             |> SCXML.compile()
  end

  defp body(value), do: ~s(<scxml xmlns="#{@uri}" version="1.0">#{value}</scxml>)

  defp document(body, attrs) do
    attrs = Keyword.put_new(attrs, :version, "1.0")
    attributes = Enum.map_join(attrs, " ", fn {name, value} -> ~s(#{name}="#{value}") end)
    ~s(<scxml xmlns="#{@uri}" #{attributes}><state id="s"/>#{body}</scxml>)
  end
end
