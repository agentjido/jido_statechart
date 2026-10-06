defmodule Jido.Statechart.SCXML.Handler do
  @moduledoc false
  @behaviour Saxy.Handler

  alias Jido.Statechart.{Diagnostic, Limits}
  alias Jido.Statechart.SCXML.Namespaces

  @type state :: %{
          limits: Limits.t(),
          source_uri: String.t() | nil,
          stack: [map()],
          root: map() | nil,
          nodes: non_neg_integer(),
          attributes: non_neg_integer(),
          text_bytes: non_neg_integer(),
          error: Diagnostic.t() | nil
        }

  @spec initial(Limits.t(), String.t() | nil) :: state()
  def initial(%Limits{} = limits, source_uri) do
    %{
      limits: limits,
      source_uri: source_uri,
      stack: [],
      root: nil,
      nodes: 0,
      attributes: 0,
      text_bytes: 0,
      error: nil
    }
  end

  @impl true
  def handle_event(_event, _data, %{error: %Diagnostic{}} = state), do: {:stop, state}

  def handle_event(:start_document, prolog, state) do
    version = Keyword.get(prolog, :version) || "1.0"
    encoding = Keyword.get(prolog, :encoding) || "UTF-8"

    cond do
      version != "1.0" ->
        stop(state, :unsupported_xml_version, "The Jido SCXML Profile accepts XML 1.0 only",
          profile_feature: "restricted_xml"
        )

      String.upcase(encoding) != "UTF-8" ->
        stop(state, :unsupported_encoding, "The Jido SCXML Profile accepts UTF-8 XML only",
          profile_feature: "restricted_xml"
        )

      true ->
        {:ok, state}
    end
  end

  def handle_event(:start_element, {raw_name, raw_attributes}, state) do
    path = next_path(state, raw_name)
    depth = length(state.stack) + 1
    node_count = state.nodes + 1
    attribute_count = state.attributes + length(raw_attributes)

    cond do
      state.stack == [] and state.root != nil ->
        stop(state, :multiple_xml_roots, "XML must contain one root element", path: path)

      depth > state.limits.xml_depth ->
        limit(
          state,
          :xml_depth_limit,
          "XML depth limit is exceeded",
          path,
          state.limits.xml_depth
        )

      node_count > state.limits.xml_nodes ->
        limit(state, :xml_node_limit, "XML node limit is exceeded", path, state.limits.xml_nodes)

      attribute_count > state.limits.xml_attributes ->
        limit(
          state,
          :xml_attribute_limit,
          "XML attribute limit is exceeded",
          path,
          state.limits.xml_attributes
        )

      true ->
        start_element(state, raw_name, raw_attributes, path, node_count, attribute_count)
    end
  end

  def handle_event(:end_element, raw_name, %{stack: [frame | rest]} = state) do
    if frame.raw_name == raw_name do
      node = %{
        name: frame.name,
        attributes: frame.attributes,
        content: frame.content |> Enum.reverse() |> normalize_text(),
        source: source(state, frame.path)
      }

      case rest do
        [] ->
          {:ok, %{state | stack: [], root: node}}

        [parent | ancestors] ->
          {:ok, %{state | stack: [append(parent, {:element, node}) | ancestors]}}
      end
    else
      stop(state, :invalid_xml, "XML closing element does not match", path: frame.path)
    end
  end

  def handle_event(:end_element, _raw_name, state),
    do: stop(state, :invalid_xml, "XML closing element has no open element")

  def handle_event(event, text, state) when event in [:characters, :cdata] do
    bytes = state.text_bytes + byte_size(text)

    if bytes > state.limits.xml_text_bytes do
      path =
        case state.stack do
          [frame | _] -> frame.path
          [] -> []
        end

      limit(
        state,
        :xml_text_limit,
        "XML text limit is exceeded",
        path,
        state.limits.xml_text_bytes
      )
    else
      text(state, event, text, bytes)
    end
  end

  def handle_event(:end_document, _data, %{stack: [], root: root} = state) when root != nil,
    do: {:ok, state}

  def handle_event(:end_document, _data, state),
    do: stop(state, :invalid_xml, "XML document is incomplete")

  defp start_element(state, raw_name, raw_attributes, path, nodes, attributes) do
    inherited =
      case state.stack do
        [frame | _] -> frame.namespaces
        [] -> Namespaces.initial_scope()
      end

    with {:ok, namespaces, normal_attributes} <-
           Namespaces.declarations(raw_attributes, inherited, path),
         {:ok, name} <- Namespaces.expand(raw_name, namespaces, true, path),
         {:ok, expanded_attributes} <-
           expand_attributes(normal_attributes, namespaces, path) do
      {stack, path} = bump_parent(state.stack, path)

      frame = %{
        raw_name: raw_name,
        name: name,
        attributes: expanded_attributes,
        content: [],
        namespaces: namespaces,
        path: path,
        child_counts: %{}
      }

      {:ok, %{state | stack: [frame | stack], nodes: nodes, attributes: attributes}}
    else
      {:error, diagnostic} -> {:stop, %{state | error: locate(diagnostic, state, path)}}
    end
  end

  defp expand_attributes(attributes, namespaces, path) do
    attributes
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn {raw_name, value}, {:ok, acc, seen} ->
      case Namespaces.expand(raw_name, namespaces, false, path) do
        {:ok, name} ->
          if MapSet.member?(seen, name) do
            {:halt,
             {:error,
              Diagnostic.new(:duplicate_attribute, "Expanded XML attribute is duplicated",
                path: path
              )}}
          else
            attribute = %{name: name, value: value, raw_name: raw_name}
            {:cont, {:ok, [attribute | acc], MapSet.put(seen, name)}}
          end

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, attributes, _seen} -> {:ok, Enum.reverse(attributes)}
      error -> error
    end
  end

  defp text(state, event, text, bytes) do
    kind = if(event == :cdata, do: :cdata, else: :text)

    case state.stack do
      [frame | rest] ->
        {:ok, %{state | stack: [append(frame, {kind, text}) | rest], text_bytes: bytes}}

      [] ->
        if String.trim(text) == "" do
          {:ok, %{state | text_bytes: bytes}}
        else
          stop(state, :invalid_xml, "XML text is outside the root element")
        end
    end
  end

  defp append(frame, {_kind, ""}), do: frame

  defp append(%{content: [{kind, previous} | rest]} = frame, {kind, text})
       when kind in [:text, :cdata],
       do: %{frame | content: [{kind, previous <> text} | rest]}

  defp append(frame, item), do: %{frame | content: [item | frame.content]}

  defp normalize_text(content), do: content

  defp next_path(%{stack: []}, raw_name), do: [path_segment(raw_name), 0]

  defp next_path(%{stack: [parent | _]}, raw_name) do
    name = path_segment(raw_name)
    parent.path ++ [name, Map.get(parent.child_counts, name, 0)]
  end

  defp bump_parent([], path), do: {[], path}

  defp bump_parent([parent | ancestors], path) do
    name = Enum.at(path, -2)
    parent = %{parent | child_counts: Map.update(parent.child_counts, name, 1, &(&1 + 1))}
    {[parent | ancestors], path}
  end

  defp local(raw_name), do: raw_name |> String.split(":") |> List.last()

  defp path_segment(raw_name) do
    name = local(raw_name)
    if byte_size(name) <= 128, do: name, else: utf8_prefix(name, 128)
  end

  defp utf8_prefix(name, bytes) do
    candidate = binary_part(name, 0, bytes)
    if String.valid?(candidate), do: candidate, else: utf8_prefix(name, bytes - 1)
  end

  defp source(state, path) do
    %{
      uri: state.source_uri,
      path: path,
      line: nil,
      column: nil,
      byte_offset: nil
    }
  end

  defp limit(state, code, message, path, maximum) do
    stop(state, code, message,
      path: path,
      profile_feature: "restricted_xml",
      correction: %{"maximum" => maximum}
    )
  end

  defp stop(state, code, message, opts \\ []) do
    opts = Keyword.put_new(opts, :profile_feature, "restricted_xml")

    diagnostic =
      code |> Diagnostic.new(message, opts) |> locate(state, Keyword.get(opts, :path, []))

    {:stop, %{state | error: diagnostic}}
  end

  defp locate(%Diagnostic{} = diagnostic, state, path) do
    %{
      diagnostic
      | path: if(diagnostic.path == [], do: path, else: diagnostic.path),
        location: %{"uri" => state.source_uri},
        profile_feature: diagnostic.profile_feature || "restricted_xml"
    }
  end
end
