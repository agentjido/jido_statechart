defmodule Jido.Statechart.Location do
  @moduledoc "Parses and updates string-keyed Jido data locations."

  alias Jido.Statechart.Diagnostic

  @segment ~r/^[A-Za-z_][A-Za-z0-9_-]*$/u

  @doc "Parses one dotted location without creating atoms."
  @spec parse(term()) :: {:ok, [String.t()]} | {:error, Diagnostic.t()}
  def parse(location) when is_binary(location) and byte_size(location) in 1..4_096 do
    segments = String.split(location, ".")

    if String.valid?(location) and length(segments) <= 64 and
         Enum.all?(segments, &(byte_size(&1) in 1..255 and Regex.match?(@segment, &1))) do
      {:ok, segments}
    else
      invalid()
    end
  end

  def parse(_location), do: invalid()

  @doc "Reads an existing location from a string-keyed map."
  @spec fetch(map(), String.t() | [String.t()]) :: {:ok, term()} | {:error, Diagnostic.t()}
  def fetch(data, location) when is_binary(location) do
    with {:ok, segments} <- parse(location), do: fetch(data, segments)
  end

  def fetch(data, segments) when is_map(data) and is_list(segments) do
    Enum.reduce_while(segments, {:ok, data}, fn segment, {:ok, current} ->
      if is_map(current) and not is_struct(current) do
        case Map.fetch(current, segment) do
          {:ok, value} -> {:cont, {:ok, value}}
          :error -> {:halt, missing(segments)}
        end
      else
        {:halt, missing(segments)}
      end
    end)
  end

  def fetch(_data, location), do: missing(List.wrap(location))

  @doc "Replaces one existing location. Missing paths are not created."
  @spec put(map(), String.t() | [String.t()], term()) ::
          {:ok, map()} | {:error, Diagnostic.t()}
  def put(data, location, value) when is_binary(location) do
    with {:ok, segments} <- parse(location), do: put(data, segments, value)
  end

  def put(data, segments, value) when is_map(data) and is_list(segments) do
    with {:ok, _existing} <- fetch(data, segments), do: do_put(data, segments, value)
  end

  def put(_data, location, _value), do: missing(List.wrap(location))

  defp do_put(_data, [], value), do: {:ok, value}

  defp do_put(data, [segment | rest], value) do
    with {:ok, updated} <- do_put(Map.fetch!(data, segment), rest, value) do
      {:ok, Map.put(data, segment, updated)}
    end
  end

  defp invalid do
    {:error,
     Diagnostic.new(:invalid_location, "Location must contain only dotted string keys",
       path: [:location]
     )}
  end

  defp missing(segments) do
    location =
      if Enum.all?(segments, &is_binary/1), do: Enum.join(segments, "."), else: "<invalid>"

    {:error,
     Diagnostic.new(:missing_location, "Location does not exist",
       path: [:location],
       correction: %{"location" => location}
     )}
  end
end
