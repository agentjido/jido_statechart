defmodule Jido.Statechart.Error do
  @moduledoc "A statechart failure. Errors never contain a candidate state or effect batch."
  @type t :: %__MODULE__{code: atom(), message: String.t(), path: list(), details: map()}
  defexception [:code, :message, path: [], details: %{}]

  @doc "Builds a typed error result."
  @spec result(atom(), String.t(), list(), map()) :: {:error, t()}
  def result(code, message, path \\ [], details \\ %{}),
    do: {:error, %__MODULE__{code: code, message: message, path: path, details: details}}
end
