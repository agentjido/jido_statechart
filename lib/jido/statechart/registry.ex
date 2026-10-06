defmodule Jido.Statechart.Registry do
  @moduledoc """
  Trusted application behavior resolved by stable string IDs.

  Guards receive `(data, event)` and return a boolean. Reducers receive
  `(data, event, params)` and return `{:ok, next_data}` or
  `{:ok, next_data, requests}`. Requests are `Event` values with kind `:internal`
  or `Effect` values. Each callback must be pure, deterministic, and bounded.
  The engine cannot prove these properties for arbitrary application code.
  Change the definition version when callback behavior changes.
  """
  alias Jido.Statechart.{Definition, Error}

  @type t :: %__MODULE__{
          guards: %{String.t() => function()},
          reducers: %{String.t() => function()}
        }
  defstruct guards: %{}, reducers: %{}

  @doc "Builds a registry from application-owned callbacks."
  @spec new(map(), map()) :: {:ok, t()} | {:error, Error.t()}
  def new(guards \\ %{}, reducers \\ %{}) do
    if valid?(guards, 2) and valid?(reducers, 3),
      do: {:ok, %__MODULE__{guards: guards, reducers: reducers}},
      else:
        Error.result(
          :invalid_registry,
          "Registry requires string IDs and callbacks of the correct arity"
        )
  end

  @doc "Checks that each behavior reference in a definition has a trusted callback."
  @spec validate(Definition.t(), term()) :: :ok | {:error, Error.t()}
  def validate(%Definition{} = definition, %__MODULE__{} = registry) do
    with {:ok, _} <- new(registry.guards, registry.reducers) do
      Enum.reduce_while(definition.states, :ok, fn {_, state}, :ok ->
        guards = Enum.map(state.transitions, & &1.guard) |> Enum.reject(&is_nil/1)
        actions = state.entry ++ state.exit ++ Enum.flat_map(state.transitions, & &1.actions)

        missing =
          Enum.find(guards, &(not Map.has_key?(registry.guards, &1))) ||
            Enum.find_value(actions, fn
              %{id: id} -> if not Map.has_key?(registry.reducers, id), do: id
              _ -> nil
            end)

        if missing,
          do:
            {:halt, Error.result(:unknown_behavior, "Unknown application behavior ID", [missing])},
          else: {:cont, :ok}
      end)
    end
  end

  def validate(_, _), do: Error.result(:invalid_registry, "Expected a trusted Registry")

  defp valid?(map, arity) when is_map(map) and not is_struct(map),
    do:
      map_size(map) <= 4096 and
        Enum.all?(map, fn {id, callback} ->
          is_binary(id) and byte_size(id) in 1..4096 and String.valid?(id) and
            is_function(callback, arity)
        end)

  defp valid?(_, _), do: false
end
