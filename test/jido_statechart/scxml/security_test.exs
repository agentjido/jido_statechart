defmodule Jido.Statechart.SCXML.SecurityTest do
  use ExUnit.Case, async: true

  alias Jido.Statechart.{Diagnostic, Limits, SCXML}

  @prefix ~s(<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">)
  @suffix ~s(<state id="ok"/></scxml>)

  test "rejects forbidden lexical constructs across every chunk boundary" do
    documents = [
      {"dtd", "<!DOCTYPE scxml [<!ENTITY x SYSTEM 'file:///etc/passwd'>]>", :forbidden_dtd},
      {"entity", "<!ENTITY x 'secret'>", :forbidden_entity_declaration},
      {"pi", "<?work fetch='https://example.invalid'?>", :unsupported_processing_instruction},
      {"entity reference", "<state id='x'>&outside;</state>", :unsupported_entity_reference}
    ]

    for {_label, fragment, code} <- documents do
      xml = @prefix <> fragment <> @suffix

      for split <- 0..byte_size(xml) do
        chunks = [binary_part(xml, 0, split), binary_part(xml, split, byte_size(xml) - split)]
        assert {:error, %Diagnostic{code: ^code}} = SCXML.compile_stream(chunks)
      end
    end
  end

  test "rejects invalid UTF-8, unsupported encoding, and external sources" do
    assert {:error, %Diagnostic{code: :invalid_utf8}} = SCXML.compile(<<0xFF, 0xFE, 0x00>>)

    assert {:error, %Diagnostic{code: :unsupported_encoding}} =
             SCXML.compile(~s(<?xml version="1.0" encoding="ISO-8859-1"?>) <> @prefix <> @suffix)

    assert {:error, %Diagnostic{code: :external_source_unsupported, correction: correction}} =
             SCXML.compile(
               @prefix <>
                 ~s(<state id="s"><datamodel><data id="x" src="file:///secret"/></datamodel></state></scxml>)
             )

    refute inspect(correction) =~ "secret"
    assert byte_size(inspect(correction)) < 256
  end

  test "enforces every aggregate XML limit at the boundary" do
    xml = @prefix <> @suffix
    byte_limit = byte_size(xml)

    assert {:ok, _} = SCXML.compile(xml, limits: limit(xml_bytes: byte_limit))

    assert {:error, %Diagnostic{code: :xml_byte_limit}} =
             SCXML.compile(xml, limits: limit(xml_bytes: byte_limit - 1))

    assert {:ok, _} = SCXML.compile(xml, limits: limit(xml_depth: 2))

    assert {:error, %Diagnostic{code: :xml_depth_limit}} =
             SCXML.compile(xml, limits: limit(xml_depth: 1))

    assert {:ok, _} = SCXML.compile(xml, limits: limit(xml_nodes: 2))

    assert {:error, %Diagnostic{code: :xml_node_limit}} =
             SCXML.compile(xml, limits: limit(xml_nodes: 1))

    assert {:ok, _} = SCXML.compile(xml, limits: limit(xml_attributes: 3))

    assert {:error, %Diagnostic{code: :xml_attribute_limit}} =
             SCXML.compile(xml, limits: limit(xml_attributes: 2))

    text_xml =
      @prefix <>
        ~s(<state id="s"><onentry><send><content>abc</content></send></onentry></state></scxml>)

    assert {:ok, _} = SCXML.compile(text_xml, limits: limit(xml_text_bytes: 3))

    assert {:error, %Diagnostic{code: :xml_text_limit}} =
             SCXML.compile(text_xml, limits: limit(xml_text_bytes: 2))
  end

  test "does not create atoms from document names" do
    unknown = "unknown_#{System.unique_integer([:positive])}"
    xml = @prefix <> "<#{unknown}/></scxml>"

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
    assert {:error, %Diagnostic{code: :unknown_profile_element}} = SCXML.compile(xml)
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  test "accepts the safe XML lexical forms" do
    xml =
      <<0xEF, 0xBB, 0xBF>> <>
        ~s(<?xml version="1.0"?>) <>
        ~s(<!-- safe -->) <>
        @prefix <>
        ~s(<state id="s"><onentry><send><content>&lt;&amp;&#65;&#x42;<![CDATA[<c>]]></content></send></onentry></state></scxml>)

    assert {:ok, chart} = SCXML.compile_stream(Enum.map(:binary.bin_to_list(xml), &<<&1>>))
    [state] = chart.states
    [send] = state.on_entry

    assert send.data["content"]["items"] == [
             %{"kind" => "text", "value" => "<&AB"},
             %{"kind" => "cdata", "value" => "<c>"}
           ]
  end

  test "rejects malformed declarations, comments, character references, and XML characters" do
    cases = [
      {~s(<?xml version="1.0") <> @prefix <> @suffix, :invalid_xml_declaration},
      {@prefix <> "<!-- broken" <> @suffix, :invalid_xml_comment},
      {@prefix <> "<!-- bad -- comment -->" <> @suffix, :invalid_xml_comment},
      {@prefix <> "<![CDATA[broken" <> @suffix, :invalid_cdata},
      {@prefix <> "<!ATTLIST state id ID #IMPLIED>" <> @suffix, :forbidden_dtd},
      {@prefix <> "<state id='x'>&broken</state></scxml>", :invalid_entity_reference},
      {@prefix <> "<state id='x'>&#0;</state></scxml>", :invalid_entity_reference},
      {@prefix <> "<state id='x'>&#x110000;</state></scxml>", :invalid_entity_reference},
      {@prefix <> <<0>> <> @suffix, :invalid_xml_character}
    ]

    for {xml, code} <- cases do
      assert {:error, %Diagnostic{code: ^code}} = SCXML.compile(xml)
    end
  end

  test "validates compiler input and options without exposing input" do
    assert {:error, %Diagnostic{code: :invalid_xml_input}} = SCXML.compile(:not_binary)
    assert {:error, %Diagnostic{code: :invalid_xml_input}} = SCXML.compile_stream(nil)
    assert {:error, %Diagnostic{code: :invalid_xml_input}} = SCXML.compile_stream([:not_binary])

    assert {:error, %Diagnostic{code: :invalid_compiler_options}} =
             SCXML.compile(@prefix <> @suffix, unknown: true)

    assert {:error, %Diagnostic{code: :invalid_compiler_options}} =
             SCXML.compile(@prefix <> @suffix, id: "a", id: "b")

    assert {:error, %Diagnostic{code: :invalid_compiler_options}} =
             SCXML.compile_stream([@prefix <> @suffix], [:invalid])

    assert {:error, %Diagnostic{code: :invalid_source_uri}} =
             SCXML.compile(@prefix <> @suffix, source_uri: "")

    assert {:error, %Diagnostic{code: :invalid_source_uri}} =
             SCXML.compile(@prefix <> @suffix, source_uri: String.duplicate("x", 2049))

    assert {:error, %Diagnostic{code: :invalid_id}} =
             SCXML.compile(@prefix <> @suffix, id: "not an id")

    assert {:error, %Diagnostic{code: :limit_out_of_range}} =
             SCXML.compile(@prefix <> @suffix, limits: %{xml_depth: 0})

    assert_raise ArgumentError, ~r/invalid_scxml_root/, fn ->
      SCXML.compile!(~s(<scxml version="1.0"><state id="s"/></scxml>))
    end
  end

  defp limit(overrides) do
    Limits.defaults()
    |> Map.merge(Map.new(overrides))
    |> Limits.new!()
  end
end
