defmodule Jido.Statechart.Checkpoint do
  @moduledoc "Portable core checkpoints. Stored data never selects a behavior module or registry."
  alias Jido.Statechart.{Configuration, Data, Definition, Error, Instance, Validator}

  @doc "Saves a compatible chart instance as a plain map with fixed string keys."
  @spec dump(Definition.t(), Instance.t()) :: {:ok, map()} | {:error, Error.t()}
  def dump(definition, instance) do
    with :ok <- Validator.definition(definition),
         :ok <- Validator.instance(definition, instance) do
      config = instance.configuration

      {:ok,
       %{
         "version" => 1,
         "fingerprint" => config.fingerprint,
         "active" => config.active,
         "status" => Atom.to_string(config.status),
         "data" => instance.data
       }}
    end
  end

  @doc "Loads mutable state against the supplied trusted definition. No actions run."
  @spec load(Definition.t(), term()) :: {:ok, Instance.t()} | {:error, Error.t()}
  def load(definition, payload) do
    with :ok <- Validator.definition(definition),
         :ok <- Data.validate(payload, definition.limits),
         {:ok, instance} <- decode(payload),
         :ok <- Validator.instance(definition, instance) do
      {:ok, instance}
    end
  end

  defp decode(
         %{
           "version" => 1,
           "fingerprint" => fingerprint,
           "active" => active,
           "status" => status,
           "data" => data
         } = payload
       )
       when map_size(payload) == 5 do
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
      else: Error.result(:invalid_checkpoint, "Unknown checkpoint status")
  end

  defp decode(_), do: Error.result(:invalid_checkpoint, "Malformed core checkpoint")
end
