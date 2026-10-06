defmodule Jido.Statechart.AgentState do
  @moduledoc false
  alias Jido.Statechart.{Configuration, Definition, Error, Instance, Validator}

  @doc "Checks complete Agent chart and domain state without changing values."
  @spec validate_state(term(), Definition.t(), keyword()) :: :ok | {:error, String.t()}
  def validate_state(state, definition, _options) do
    with {:ok, instance} <- decode_state(state),
         :ok <- Validator.instance(definition, instance) do
      :ok
    else
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  @doc "Converts an interpreter candidate into Agent state fields."
  @spec encode_state(Instance.t()) :: map()
  def encode_state(%Instance{configuration: config, data: data}),
    do: %{
      chart: %{
        fingerprint: config.fingerprint,
        active: config.active,
        status: Atom.to_string(config.status)
      },
      data: data
    }

  @doc "Reads mutable chart configuration without selecting executable code."
  @spec decode_state(term()) :: {:ok, Instance.t()} | {:error, Error.t()}
  def decode_state(%{
        chart: %{fingerprint: fingerprint, active: active, status: status} = chart,
        data: data
      })
      when map_size(chart) == 3 do
    status =
      case status do
        "new" -> :new
        "running" -> :running
        "done" -> :done
        _ -> nil
      end

    if status,
      do:
        {:ok,
         %Instance{
           configuration: %Configuration{fingerprint: fingerprint, active: active, status: status},
           data: data
         }},
      else: Error.result(:invalid_configuration, "Unknown configuration status")
  end

  def decode_state(_), do: Error.result(:invalid_configuration, "Malformed Agent chart state")
end
