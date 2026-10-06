defmodule Jido.Statechart.Limits do
  @moduledoc "Hard engine bounds. A definition can lower a bound, but cannot raise it."
  alias Jido.Statechart.Error

  @defaults %{
    states: 512,
    depth: 32,
    active_states: 32,
    transitions: 4096,
    actions_per_list: 256,
    action_calls: 512,
    internal_events: 128,
    macrostep: 1024,
    expression_bytes: 4096,
    definition_bytes: 1_048_576,
    data_nodes: 65_536,
    data_bytes: 1_048_576
  }
  @type t :: %{atom() => pos_integer()}

  @doc "Returns the fixed maximum bounds."
  @spec defaults() :: t()
  def defaults, do: @defaults

  @doc "Validates optional lower bounds with fixed atom or string field names."
  @spec new(term()) :: {:ok, t()} | {:error, Error.t()}
  def new(input \\ %{})

  def new(input) when is_map(input) and not is_struct(input) do
    if map_size(input) > map_size(@defaults) or
         Enum.any?(
           Map.keys(@defaults),
           &(Map.has_key?(input, &1) and Map.has_key?(input, Atom.to_string(&1)))
         ) do
      Error.result(:invalid_limit, "Duplicate or unknown execution limits")
    else
      parse(input)
    end
  end

  def new(_), do: Error.result(:invalid_limit, "Limits must be a plain map")

  defp parse(input) do
    Enum.reduce_while(input, {:ok, @defaults}, fn {key, value}, {:ok, acc} ->
      field = Enum.find(Map.keys(@defaults), &(key == &1 or key == Atom.to_string(&1)))

      if field && is_integer(value) && value > 0 && value <= @defaults[field],
        do: {:cont, {:ok, Map.put(acc, field, value)}},
        else: {:halt, Error.result(:invalid_limit, "Invalid execution limit", [key])}
    end)
  end
end
