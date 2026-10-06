defmodule Jido.Statechart.SCXML.NamespaceTest do
  use ExUnit.Case, async: true

  alias Jido.Statechart.{Diagnostic, SCXML}
  alias Jido.Statechart.Model.Chart

  @uri "http://www.w3.org/2005/07/scxml"

  test "default, prefixed, nested, and shadowed bindings have expanded-name parity" do
    default = ~s(<scxml xmlns="#{@uri}" version="1.0"><state id="s"/></scxml>)

    prefixed =
      ~s(<s:scxml xmlns:s="#{@uri}" version="1.0"><s:state id="s"/></s:scxml>)

    nested =
      ~s(<scxml xmlns="#{@uri}" xmlns:x="urn:outer" version="1.0"><state xmlns:x="urn:inner" id="s"/></scxml>)

    for xml <- [default, prefixed, nested] do
      assert {:ok, chart} = SCXML.compile(xml)
      assert [%{id: "s", kind: :atomic}] = chart.states

      semantic = Chart.dump(chart) |> Map.drop(["fingerprint", "source"])

      assert semantic ==
               default
               |> SCXML.compile!()
               |> Chart.dump()
               |> Map.drop(["fingerprint", "source"])
    end
  end

  test "rejects undeclared prefixes and invalid reserved bindings" do
    assert {:error, %Diagnostic{code: :undeclared_namespace_prefix}} =
             SCXML.compile(~s(<s:scxml version="1.0"><s:state id="s"/></s:scxml>))

    assert {:error, %Diagnostic{code: :invalid_namespace_binding}} =
             SCXML.compile(
               ~s(<scxml xmlns="#{@uri}" xmlns:xml="urn:not-xml" version="1.0"><state id="s"/></scxml>)
             )

    assert {:error, %Diagnostic{code: :duplicate_attribute}} =
             SCXML.compile(
               ~s(<scxml xmlns="#{@uri}" xmlns:a="urn:x" xmlns:b="urn:x" version="1.0" a:x="1" b:x="2"><state id="s"/></scxml>)
             )

    assert {:error, %Diagnostic{code: :invalid_namespace_binding}} =
             SCXML.compile(
               ~s(<scxml xmlns="#{@uri}" xmlns:xmlns="urn:x" version="1.0"><state id="s"/></scxml>)
             )

    assert {:error, %Diagnostic{code: :invalid_namespace_binding}} =
             SCXML.compile(
               ~s(<scxml xmlns="#{@uri}" xmlns:p="" version="1.0"><state id="s"/></scxml>)
             )

    assert {:error, %Diagnostic{code: :undeclared_namespace_prefix}} =
             SCXML.compile(~s(<scxml xmlns="#{@uri}" version="1.0"><state p:id="s"/></scxml>))
  end
end
