defmodule Jido.Statechart.SCXML.ReviewRegressionTest do
  use ExUnit.Case, async: true

  alias Jido.Statechart.{Diagnostic, SCXML}
  alias Jido.Statechart.Model.Chart

  @scxml "http://www.w3.org/2005/07/scxml"

  test "encodes ordered if partitions, including a nested if" do
    xml =
      document("""
      <state id="s">
        <onentry>
          <if cond="first">
            <log label="first"/>
            <elseif cond="second"/>
            <if cond="nested">
              <raise event="nested.yes"/>
              <else/>
              <log label="nested.no"/>
            </if>
            <else/>
            <cancel sendid="pending"/>
          </if>
        </onentry>
      </state>
      """)

    assert {:ok, chart} = SCXML.compile(xml)
    [conditional] = hd(chart.states).on_entry

    assert Enum.map(conditional.children, & &1.kind) == [:log, :if, :cancel]

    assert conditional.data["branches"] == [
             %{"kind" => "if", "condition" => "first", "start" => 0, "count" => 1},
             %{"kind" => "elseif", "condition" => "second", "start" => 1, "count" => 1},
             %{"kind" => "else", "condition" => nil, "start" => 2, "count" => 1}
           ]

    nested = Enum.at(conditional.children, 1)

    assert nested.data["branches"] == [
             %{"kind" => "if", "condition" => "nested", "start" => 0, "count" => 1},
             %{"kind" => "else", "condition" => nil, "start" => 1, "count" => 1}
           ]
  end

  test "rejects W3C cardinality and mutual exclusion violations before lowering" do
    cases = [
      {:data_value, ~s(<datamodel><data id="x" expr="value"><v/></data></datamodel>)},
      {:content_value,
       ~s(<onentry><send><content expr="value">inline</content></send></onentry>)},
      {:param_missing, ~s(<onentry><send event="x"><param name="p"/></send></onentry>)},
      {:param_both,
       ~s(<onentry><send event="x"><param name="p" expr="x" location="y"/></send></onentry>)},
      {:send_event, ~s(<onentry><send event="x" eventexpr="y"/></onentry>)},
      {:send_internal_delay,
       ~s(<onentry><send event="x" target="_internal" delay="1s"/></onentry>)},
      {:send_content_count,
       ~s(<onentry><send><content>one</content><content>two</content></send></onentry>)},
      {:send_content_params,
       ~s(<onentry><send><content>one</content><param name="p" expr="x"/></send></onentry>)},
      {:donedata_choice,
       ~s(<final id="f"><donedata><content>x</content><param name="p" expr="x"/></donedata></final>)},
      {:donedata_count, ~s(<final id="f"><donedata/><donedata/></final>)},
      {:invoke_source, ~s(<invoke type="scxml" src="child" srcexpr="child_expr"/>)},
      {:invoke_content, ~s(<invoke type="scxml" src="child"><content>inline</content></invoke>)},
      {:invoke_namelist,
       ~s(<invoke type="scxml" src="child" namelist="x"><param name="p" expr="x"/></invoke>)},
      {:invoke_content_count,
       ~s(<invoke type="scxml"><content>one</content><content>two</content></invoke>)},
      {:invoke_finalize_count,
       ~s(<invoke type="scxml" src="child"><finalize/><finalize/></invoke>)},
      {:datamodel_count, ~s(<datamodel/><datamodel/>)}
    ]

    for {label, body} <- cases do
      assert {:error, %Diagnostic{code: code}} = SCXML.compile(state_document(body)),
             inspect(label)

      assert code in [:invalid_element_cardinality, :mutually_exclusive_content], inspect(label)
    end
  end

  test "requires an event when send has content" do
    assert {:error, %Diagnostic{code: :invalid_element_cardinality}} =
             SCXML.compile(
               state_document(~s(<onentry><send><content>body</content></send></onentry>))
             )
  end

  test "preserves one ordered mixed-content sequence across CDATA, elements, and chunks" do
    xml =
      document("""
      <state id="s">
        <onentry>
          <send event="content"><content>one<![CDATA[<two>]]><item xmlns="urn:data">three</item>four</content></send>
        </onentry>
      </state>
      """)

    assert {:ok, one_shot} = SCXML.compile(xml)
    assert {:ok, chunked} = SCXML.compile_stream(Enum.map(:binary.bin_to_list(xml), &<<&1>>))
    assert Chart.dump(one_shot) == Chart.dump(chunked)

    [send] = hd(one_shot.states).on_entry

    assert send.data["content"]["items"] == [
             %{"kind" => "text", "value" => "one"},
             %{"kind" => "cdata", "value" => "<two>"},
             %{
               "kind" => "element",
               "value" => %{
                 "name" => %{"namespace" => "urn:data", "local" => "item"},
                 "attributes" => [],
                 "content" => [%{"kind" => "text", "value" => "three"}]
               }
             },
             %{"kind" => "text", "value" => "four"}
           ]
  end

  test "validates all authored XML IDs and document-wide collisions with generated state IDs" do
    invalid = [
      ~s(<state id="bad id"/>),
      ~s(<state id="s"><history id="bad id"><transition target="s"/></history></state>),
      ~s(<final id="bad id"/>),
      ~s(<state id="s"><onentry><send id="bad id" event="x"/></onentry></state>),
      ~s(<state id="s"><invoke id="bad id" type="scxml" src="child"/></state>)
    ]

    for body <- invalid do
      assert {:error, %Diagnostic{code: :invalid_id}} = SCXML.compile(document(body))
    end

    generated = Jido.Statechart.Model.Chart.generated_id("state", [0, 0], 0)

    assert {:error, %Diagnostic{code: :duplicate_id}} =
             SCXML.compile(
               document(~s(<state><onentry><send id="#{generated}" event="x"/></onentry></state>))
             )
  end

  test "stops input enumeration as soon as a forbidden declaration is known" do
    owner = self()

    chunks =
      ["<!DO", "CTYPE scxml>", "after-forbidden"]
      |> Stream.map(fn chunk ->
        if chunk == "after-forbidden", do: send(owner, :enumerated_after_forbidden)
        chunk
      end)

    assert {:error, %Diagnostic{code: :forbidden_dtd}} = SCXML.compile_stream(chunks)
    refute_received :enumerated_after_forbidden
  end

  test "normalizes a default namespace undeclaration and permits a nested rebind" do
    xml =
      document("""
      <state id="s">
        <onentry>
          <send event="content"><content><plain xmlns=""><child/><bound xmlns="#{@scxml}"><leaf/></bound></plain></content></send>
        </onentry>
      </state>
      """)

    assert {:ok, chart} = SCXML.compile(xml)
    [send] = hd(chart.states).on_entry
    [%{"kind" => "element", "value" => plain}] = send.data["content"]["items"]
    assert plain["name"]["namespace"] == nil

    [child, rebound] = plain["content"]
    assert child["value"]["name"]["namespace"] == nil
    assert rebound["value"]["name"]["namespace"] == @scxml
    assert hd(rebound["value"]["content"])["value"]["name"]["namespace"] == @scxml
  end

  test "attaches a profile feature to every public compiler diagnostic" do
    failures = [
      fn -> SCXML.compile(:not_xml) end,
      fn -> SCXML.compile_stream(["<!DOCTYPE scxml>"]) end,
      fn -> SCXML.compile(~s(<s:scxml version="1.0"/>)) end,
      fn -> SCXML.compile(document(~s(<state id="bad id"/>))) end,
      fn -> SCXML.compile(document(~s(<state id="same"/><state id="same"/>))) end,
      fn -> SCXML.compile(document(~s(<state id="s"/>)), unknown: true) end
    ]

    for failure <- failures do
      assert {:error, %Diagnostic{profile_feature: feature}} = failure.()
      assert is_binary(feature) and feature != ""
    end
  end

  defp state_document(body), do: document(~s(<state id="s">#{body}</state>))

  defp document(body) do
    ~s(<scxml xmlns="#{@scxml}" version="1.0">#{body}</scxml>)
  end
end
