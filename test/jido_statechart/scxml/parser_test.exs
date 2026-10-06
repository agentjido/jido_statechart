defmodule Jido.Statechart.SCXML.ParserTest do
  use ExUnit.Case, async: true

  alias Jido.Statechart.{Diagnostic, SCXML}
  alias Jido.Statechart.Model.Chart

  @fixture Path.expand("../../fixtures/scxml/namespaces.scxml", __DIR__)

  test "compiles one-shot and arbitrarily chunked input to the same chart" do
    xml = File.read!(@fixture)

    assert {:ok, one_shot} = SCXML.compile(xml, source_uri: "memory://namespaces.scxml")

    for width <- 1..17 do
      chunks = for <<chunk::binary-size(^width) <- xml>>, do: chunk
      consumed = IO.iodata_length(chunks)
      chunks = chunks ++ [binary_part(xml, consumed, byte_size(xml) - consumed)]

      assert {:ok, streamed} =
               SCXML.compile_stream(chunks, source_uri: "memory://namespaces.scxml")

      assert Chart.dump(streamed) == Chart.dump(one_shot)
    end

    assert Enum.map(one_shot.states, &{&1.id, &1.ordinal, &1.kind}) == [
             {"root", 0, :compound},
             {"left", 1, :atomic},
             {"right", 2, :atomic}
           ]

    assert Enum.map(one_shot.transitions, &{&1.source_id, &1.target_ids, &1.events}) == [
             {"left", ["right"], ["advance"]}
           ]
  end

  test "generates deterministic IDs and ordinals for omitted IDs" do
    xml = """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
      <state>
        <transition event="next" target="done"/>
      </state>
      <final id="done"/>
    </scxml>
    """

    assert {:ok, first} = SCXML.compile(xml)
    assert {:ok, second} = SCXML.compile_stream(Enum.map(:binary.bin_to_list(xml), &<<&1>>))
    assert Chart.dump(first) == Chart.dump(second)

    [generated, done] = first.states
    assert generated.generated
    assert String.starts_with?(generated.id, "__jido_state_")
    assert [generated.ordinal, done.ordinal] == [0, 1]
    assert [%{generated: true, ordinal: 0}] = first.transitions
  end

  test "returns a source-aware diagnostic for malformed XML" do
    assert {:error,
            %Diagnostic{
              code: :invalid_xml,
              path: ["scxml", 0],
              location: %{"uri" => "memory://bad.scxml"}
            }} =
             SCXML.compile(
               ~s(<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0"><state></scxml>),
               source_uri: "memory://bad.scxml"
             )
  end

  test "normalizes one-shot and chunked diagnostics" do
    xml =
      ~s(<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0"><state id="bad id"/></scxml>)

    assert {:error, one_shot} = SCXML.compile(xml, source_uri: "memory://bad.scxml")

    chunks = Enum.map(:binary.bin_to_list(xml), &<<&1>>)
    assert {:error, streamed} = SCXML.compile_stream(chunks, source_uri: "memory://bad.scxml")
    assert streamed == one_shot
  end
end
