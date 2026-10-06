defmodule Jido.Statechart.Data do
  @moduledoc false
  alias Jido.Statechart.Error

  def validate(value, limits) do
    case walk(value, limits.data_nodes, limits.data_bytes, 0) do
      {:ok, _, _} ->
        :ok

      _ ->
        Error.result(
          :invalid_data,
          "Data must be bounded portable maps, lists, and scalar values"
        )
    end
  end

  defp walk(_, n, b, d) when n <= 0 or b < 0 or d > 64, do: :error

  defp walk(value, n, b, _) when is_binary(value) do
    if byte_size(value) <= b and String.valid?(value),
      do: {:ok, n - 1, b - byte_size(value)},
      else: :error
  end

  defp walk(value, n, b, _)
       when is_integer(value) and value >= -9_223_372_036_854_775_808 and
              value <= 9_223_372_036_854_775_807,
       do: scalar(n, b, byte_size(Integer.to_string(value)))

  defp walk(value, n, b, _) when is_float(value), do: scalar(n, b, 8)

  defp walk(value, n, b, _) when is_atom(value),
    do: scalar(n, b, byte_size(Atom.to_string(value)))

  defp walk(value, n, b, d)
       when is_map(value) and not is_struct(value) and map_size(value) <= div(n - 1, 2),
       do: items(Map.to_list(value), n - 1, b, d + 1)

  defp walk(value, n, b, d) when is_list(value), do: list(value, n - 1, b, d + 1)
  defp walk(_, _, _, _), do: :error
  defp scalar(n, b, size) when b >= size, do: {:ok, n - 1, b - size}
  defp scalar(_, _, _), do: :error
  defp items([], n, b, _), do: {:ok, n, b}

  defp items([{k, v} | rest], n, b, d) when is_binary(k) or is_atom(k) do
    with {:ok, n, b} <- walk(k, n, b, d),
         {:ok, n, b} <- walk(v, n, b, d),
         do: items(rest, n, b, d)
  end

  defp items(_, _, _, _), do: :error
  defp list([], n, b, _), do: {:ok, n, b}

  defp list([v | rest], n, b, d) do
    with {:ok, n, b} <- walk(v, n, b, d), do: list(rest, n, b, d)
  end

  defp list(_, _, _, _), do: :error
end
