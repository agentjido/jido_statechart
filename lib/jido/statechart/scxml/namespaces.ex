defmodule Jido.Statechart.SCXML.Namespaces do
  @moduledoc false

  alias Jido.Statechart.Diagnostic

  @xml "http://www.w3.org/XML/1998/namespace"
  @xmlns "http://www.w3.org/2000/xmlns/"

  @spec initial_scope() :: map()
  def initial_scope, do: %{"xml" => @xml}

  @spec expand(String.t(), map(), boolean(), [term()]) ::
          {:ok, {String.t() | nil, String.t()}} | {:error, Diagnostic.t()}
  def expand(raw_name, scope, element?, path) when is_binary(raw_name) do
    case String.split(raw_name, ":") do
      [local] when local != "" ->
        {:ok, {if(element?, do: Map.get(scope, ""), else: nil), local}}

      [prefix, local] when prefix != "" and local != "" ->
        case Map.fetch(scope, prefix) do
          {:ok, uri} ->
            {:ok, {uri, local}}

          :error ->
            {:error,
             diagnostic(
               :undeclared_namespace_prefix,
               "XML namespace prefix is not declared",
               path: path,
               correction: %{"declare_prefix" => true}
             )}
        end

      _ ->
        {:error, diagnostic(:invalid_xml_name, "XML qualified name is invalid", path: path)}
    end
  end

  @spec declarations([{String.t(), String.t()}], map(), [term()]) ::
          {:ok, map(), [{String.t(), String.t()}]} | {:error, Diagnostic.t()}
  def declarations(attributes, inherited, path) do
    attributes
    |> Enum.reduce_while({:ok, inherited, [], MapSet.new()}, fn {name, value},
                                                                {:ok, scope, normal, raw_seen} ->
      if MapSet.member?(raw_seen, name) do
        {:halt, duplicate(path)}
      else
        seen = MapSet.put(raw_seen, name)

        case declaration(name, value, scope, path) do
          {:ok, next_scope} -> {:cont, {:ok, next_scope, normal, seen}}
          :normal -> {:cont, {:ok, scope, [{name, value} | normal], seen}}
          {:error, _} = error -> {:halt, error}
        end
      end
    end)
    |> case do
      {:ok, scope, normal, _seen} -> {:ok, scope, Enum.reverse(normal)}
      error -> error
    end
  end

  defp declaration("xmlns", uri, scope, path) do
    cond do
      uri == "" -> {:ok, Map.delete(scope, "")}
      uri in [@xml, @xmlns] -> invalid_binding(path)
      true -> {:ok, Map.put(scope, "", uri)}
    end
  end

  defp declaration("xmlns:" <> prefix, uri, scope, path) do
    valid? =
      prefix != "" and prefix != "xmlns" and uri != "" and uri != @xmlns and
        ((prefix == "xml" and uri == @xml) or (prefix != "xml" and uri != @xml))

    if valid?, do: {:ok, Map.put(scope, prefix, uri)}, else: invalid_binding(path)
  end

  defp declaration(_name, _uri, _scope, _path), do: :normal

  defp invalid_binding(path) do
    {:error,
     diagnostic(:invalid_namespace_binding, "XML namespace binding is invalid", path: path)}
  end

  defp duplicate(path) do
    {:error, diagnostic(:duplicate_attribute, "XML attribute is duplicated", path: path)}
  end

  defp diagnostic(code, message, opts) do
    Diagnostic.new(code, message, Keyword.put_new(opts, :profile_feature, "restricted_xml"))
  end
end
