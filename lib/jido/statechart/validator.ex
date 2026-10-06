defmodule Jido.Statechart.Validator do
  @moduledoc "Validates normalized definitions and mutable configurations at public boundaries."
  alias Jido.Statechart.{
    Compiler,
    Configuration,
    Data,
    Definition,
    Error,
    Instance,
    Limits,
    State,
    Transition
  }

  @doc "Checks normalized definition integrity and its fingerprint."
  @spec definition(term()) :: :ok | {:error, Error.t()}
  def definition(%Definition{} = definition) do
    with :ok <- bounded_definition(definition),
         {:ok, rebuilt} <- Compiler.compile(Compiler.to_data(definition)) do
      if rebuilt == definition,
        do: :ok,
        else: Error.result(:definition_mismatch, "Normalized definition or fingerprint changed")
    end
  rescue
    _ -> Error.result(:invalid_definition, "Malformed normalized definition")
  end

  def definition(_), do: Error.result(:invalid_definition, "Expected a compiled Definition")

  @doc "Checks a chart instance against a trusted definition."
  @spec instance(Definition.t(), term()) :: :ok | {:error, Error.t()}
  def instance(%Definition{} = definition, %Instance{configuration: config, data: data}) do
    with :ok <- configuration(definition, config),
         true <- is_map(data) and not is_struct(data),
         :ok <- Data.validate(data, definition.limits) do
      :ok
    else
      false -> Error.result(:invalid_data, "Instance data must be a plain map")
      error -> error
    end
  end

  def instance(_, _), do: Error.result(:invalid_configuration, "Expected a chart Instance")

  @doc "Checks the complete active path and checkpoint compatibility."
  @spec configuration(Definition.t(), term()) :: :ok | {:error, Error.t()}
  def configuration(%Definition{} = definition, %Configuration{} = config) do
    cond do
      config.fingerprint != definition.fingerprint ->
        Error.result(
          :definition_mismatch,
          "Configuration fingerprint does not match the definition"
        )

      config.status == :new and config.active == [] ->
        :ok

      not valid_path?(definition, config.active) ->
        Error.result(
          :invalid_configuration,
          "Configuration must contain one complete active path"
        )

      config.status != status(definition, config.active) ->
        Error.result(
          :invalid_configuration,
          "Configuration status does not match the active path"
        )

      true ->
        :ok
    end
  end

  def configuration(_, _),
    do: Error.result(:invalid_configuration, "Expected a chart Configuration")

  @doc false
  def status(definition, [root]),
    do: if(definition.states[root].type == :final, do: :done, else: :running)

  def status(_, _), do: :running

  defp bounded_definition(definition) do
    with {:ok, limits} <- Limits.new(definition.limits),
         true <-
           limits == definition.limits and is_map(definition.states) and
             map_size(definition.states) <= limits.states,
         true <-
           Enum.all?(definition.states, fn
             {_, %State{} = state} ->
               bounded_list?(state.entry, limits.actions_per_list) and
                 bounded_list?(state.exit, limits.actions_per_list) and
                 bounded_list?(state.transitions, limits.transitions) and
                 Enum.all?(state.transitions, fn
                   %Transition{} = transition ->
                     bounded_list?(transition.actions, limits.actions_per_list)

                   _ ->
                     false
                 end)

             _ ->
               false
           end) do
      :ok
    else
      _ -> Error.result(:invalid_definition, "Malformed or over-limit normalized definition")
    end
  end

  defp bounded_list?([], _), do: true
  defp bounded_list?([_ | rest], n) when n > 0, do: bounded_list?(rest, n - 1)
  defp bounded_list?(_, _), do: false

  defp valid_path?(definition, path) when is_list(path) and path != [] do
    bounded_list?(path, definition.limits.active_states) and
      Enum.reduce_while(path, {:ok, nil}, fn id, {:ok, parent} ->
        case Map.get(definition.states, id) do
          %{parent: ^parent} -> {:cont, {:ok, id}}
          _ -> {:halt, :error}
        end
      end) != :error and definition.states[List.last(path)].type in [:atomic, :final]
  rescue
    _ -> false
  end

  defp valid_path?(_, _), do: false
end
