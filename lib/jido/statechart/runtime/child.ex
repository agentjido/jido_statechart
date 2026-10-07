defmodule Jido.Statechart.Runtime.Child do
  @moduledoc "Stable local-child identity and ownership checks."

  alias Jido.Statechart.Diagnostic

  @prefix "jido-sc-"

  @doc "Builds the stable relationship tag for one invoke generation."
  @spec tag(String.t(), String.t(), non_neg_integer()) :: String.t()
  def tag(incarnation, invoke_id, generation)
      when is_binary(incarnation) and is_binary(invoke_id) and is_integer(generation) and
             generation >= 0 do
    digest =
      Diagnostic.digest(%{
        "session_incarnation" => incarnation,
        "invoke_id" => invoke_id,
        "generation" => generation
      })

    @prefix <> String.slice(digest, 0, 40)
  end

  @doc "Checks one public AgentServer child view against committed invoke intent."
  @spec owned?(map(), map()) :: boolean()
  def owned?(child, operation) when is_map(child) and is_map(operation) do
    meta = Map.get(child, :meta, Map.get(child, "meta", %{}))
    correlation = value(operation, :correlation) || %{}

    value(child, :tag) == value(operation, :target) and is_map(meta) and
      value(meta, "jido_statechart_operation_id") == value(operation, :id) and
      value(meta, "jido_statechart_generation") == value(operation, :generation) and
      value(meta, "jido_statechart_invoke_id") ==
        value(correlation, "invoke_id") and
      value(meta, "jido_statechart_session_incarnation") ==
        value(operation, :session_incarnation)
  end

  def owned?(_child, _operation), do: false

  defp value(map, key) when is_atom(key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(map, key), do: Map.get(map, key)
end
