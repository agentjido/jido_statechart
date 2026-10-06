defmodule Jido.Statechart.SCXML.Handler do
  @moduledoc false
  import Jido.Statechart.SCXML.Validation, only: [ensure!: 3]
  alias Jido.Statechart.SCXML.Security

  @scxml "http://www.w3.org/2005/07/scxml"
  @jido "urn:jido:statechart:1"
  @xml "http://www.w3.org/XML/1998/namespace"
  @xmlns "http://www.w3.org/2000/xmlns/"

  def handle_event(:start_document, prolog, state) do
    ensure!(
      Keyword.get(prolog, :version, "1.0") == "1.0",
      :unsupported_xml,
      "Only XML 1.0 is supported"
    )

    encoding = prolog |> Keyword.get(:encoding, "UTF-8") |> String.upcase()
    ensure!(encoding == "UTF-8", :unsupported_xml, "Only UTF-8 XML is supported")
    {:ok, state}
  end

  def handle_event(:start_element, {raw_name, attributes}, state) do
    limits = state.limits
    ensure!(state.elements < limits.elements, :limit_exceeded, "XML element limit exceeded")
    ensure!(length(state.stack) < limits.depth, :limit_exceeded, "XML depth limit exceeded")

    ensure!(
      length(attributes) <= limits.attributes,
      :limit_exceeded,
      "XML attribute count limit exceeded"
    )

    ensure!(state.stack != [] or state.root == nil, :invalid_xml, "XML requires one root element")
    name!(raw_name, limits)

    names =
      Enum.map(attributes, fn {name, value} ->
        name!(name, limits)
        Security.characters!(value)

        ensure!(
          byte_size(value) <= limits.attribute_bytes,
          :limit_exceeded,
          "XML attribute byte limit exceeded"
        )

        name
      end)

    ensure!(length(names) == length(Enum.uniq(names)), :invalid_xml, "Duplicate XML attribute")

    inherited =
      case state.stack do
        [%{namespaces: namespaces} | _] -> namespaces
        [] -> %{"xml" => @xml}
      end

    namespaces = Enum.reduce(attributes, inherited, &namespace!/2)
    name = expand!(raw_name, namespaces, true)
    ensure!(supported?(name), :unsupported_xml, "Unsupported XML element: " <> raw_name)

    attrs =
      Enum.reduce(attributes, %{}, fn {key, value}, acc ->
        if key == "xmlns" or String.starts_with?(key, "xmlns:") do
          acc
        else
          key = expand!(key, namespaces, false)
          ensure!(!Map.has_key?(acc, key), :invalid_xml, "Duplicate expanded XML attribute")
          Map.put(acc, key, value)
        end
      end)

    frame = %{raw_name: raw_name, name: name, attrs: attrs, children: [], namespaces: namespaces}
    {:ok, %{state | stack: [frame | state.stack], elements: state.elements + 1}}
  end

  def handle_event(:end_element, raw_name, %{stack: [frame | rest]} = state) do
    ensure!(frame.raw_name == raw_name, :invalid_xml, "XML closing tag does not match")
    node = %{name: frame.name, attrs: frame.attrs, children: Enum.reverse(frame.children)}

    case rest do
      [] ->
        {:ok, %{state | stack: [], root: node}}

      [parent | ancestors] ->
        {:ok, %{state | stack: [%{parent | children: [node | parent.children]} | ancestors]}}
    end
  end

  def handle_event(:characters, text, state) do
    Security.characters!(text)
    bytes = state.text_bytes + byte_size(text)
    ensure!(bytes <= state.limits.text_bytes, :limit_exceeded, "XML text byte limit exceeded")

    ensure!(
      Regex.match?(~r/\A[ \t\r\n]*\z/, text),
      :unsupported_xml,
      "SCXML text content is not supported"
    )

    {:ok, %{state | text_bytes: bytes}}
  end

  def handle_event(:cdata, _, _state),
    do: ensure!(false, :unsupported_xml, "CDATA is not supported")

  def handle_event(:end_document, _, state), do: {:ok, state}

  defp supported?({@scxml, name}),
    do: name in ["scxml", "state", "final", "transition", "initial", "onentry", "onexit", "raise"]

  defp supported?({@jido, name}), do: name in ["action", "effect"]
  defp supported?(_), do: false

  defp name!(name, limits) do
    ensure!(byte_size(name) <= limits.name_bytes, :limit_exceeded, "XML name byte limit exceeded")

    ensure!(
      Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_.-]*(?::[A-Za-z_][A-Za-z0-9_.-]*)?\z/, name),
      :unsupported_xml,
      "XML names must use the supported ASCII name syntax"
    )
  end

  defp namespace!({"xmlns", uri}, acc) do
    ensure!(uri not in [@xml, @xmlns], :invalid_xml, "Reserved namespace binding")
    Map.put(acc, "", uri)
  end

  defp namespace!({"xmlns:" <> prefix, uri}, acc) do
    ensure!(
      prefix != "xmlns" and uri != "" and uri != @xmlns and
        ((prefix == "xml" and uri == @xml) or (prefix != "xml" and uri != @xml)),
      :invalid_xml,
      "Invalid namespace binding"
    )

    Map.put(acc, prefix, uri)
  end

  defp namespace!(_, acc), do: acc

  defp expand!(name, namespaces, element?) do
    case String.split(name, ":") do
      [local] ->
        {if(element?, do: Map.get(namespaces, ""), else: nil), local}

      [prefix, local] ->
        ensure!(Map.has_key?(namespaces, prefix), :invalid_xml, "Unbound XML namespace prefix")
        {namespaces[prefix], local}
    end
  end
end
