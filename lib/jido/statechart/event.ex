defmodule Jido.Statechart.Event do
  @moduledoc "A string event identity and bounded data. External completion events are reserved."
  alias Jido.Statechart.{Data, Error, Limits}
  @type t :: %__MODULE__{type: String.t(), data: map(), kind: :external | :internal}
  @enforce_keys [:type]
  defstruct [:type, data: %{}, kind: :external]

  @doc "Creates an external event."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(type, data \\ %{}), do: validate(%__MODULE__{type: type, data: data}, Limits.defaults())

  @doc false
  def validate(%__MODULE__{type: type, data: data, kind: kind} = event, limits) do
    if is_binary(type) and byte_size(type) in 1..limits.expression_bytes and String.valid?(type) and
         kind in [:internal, :external] and is_map(data) and not is_struct(data) and
         (kind == :internal or not String.starts_with?(type, ["done.state.", "$"])) do
      with :ok <- Data.validate(data, limits), do: {:ok, event}
    else
      Error.result(:invalid_event, "Invalid or reserved event identity")
    end
  end

  def validate(_, _), do: Error.result(:invalid_event, "Expected a statechart Event")
end
