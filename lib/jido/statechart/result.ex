defmodule Jido.Statechart.Result do
  @moduledoc "The portable output of one bounded statechart macrostep."

  alias Jido.Statechart.{Diagnostic, Session}
  alias Jido.Statechart.Session.Operation

  @fields [:session, :intents, :trace, :operation_counts]

  defstruct session: nil, intents: [], trace: [], operation_counts: %{}

  @type t :: %__MODULE__{
          session: Session.t(),
          intents: [Operation.t()],
          trace: [term()],
          operation_counts: map()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Diagnostic.t()}
  def new(attrs) when is_map(attrs) do
    with :ok <- Diagnostic.validate_fields(attrs, @fields, [:result]),
         {:ok, session} <- session(Diagnostic.fetch(attrs, :session)),
         {:ok, intents} <- intents(Diagnostic.fetch(attrs, :intents, [])),
         {:ok, trace} <- portable_list(Diagnostic.fetch(attrs, :trace, []), :trace),
         {:ok, counts} <- counts(Diagnostic.fetch(attrs, :operation_counts, %{})) do
      {:ok,
       %__MODULE__{session: session, intents: intents, trace: trace, operation_counts: counts}}
    end
  end

  def new(_attrs),
    do: {:error, Diagnostic.new(:invalid_result, "result must be a map", path: [:result])}

  @spec new!(map()) :: t()
  def new!(attrs), do: attrs |> new() |> Diagnostic.unwrap!()

  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = result) do
    %{
      "session" => Session.dump(result.session),
      "intents" => Enum.map(result.intents, &Operation.dump/1),
      "trace" => result.trace,
      "operation_counts" => result.operation_counts
    }
  end

  defp session(%Session{} = session), do: Session.new(session)
  defp session(value), do: Session.load(value)

  defp intents(values) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      parser = if match?(%Operation{}, value), do: &Operation.new/1, else: &Operation.load/1

      case parser.(value) do
        {:ok, intent} ->
          {:cont, {:ok, [intent | acc]}}

        {:error, diagnostic} ->
          {:halt, {:error, Diagnostic.prefix(diagnostic, [:result, :intents, index])}}
      end
    end)
    |> then(fn
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end)
  end

  defp intents(_values),
    do: {:error, Diagnostic.new(:invalid_result, "result intents must be a list")}

  defp portable_list(value, field) when is_list(value) do
    with :ok <- Diagnostic.portable(value, [:result, field]), do: {:ok, value}
  end

  defp portable_list(_value, field),
    do:
      {:error,
       Diagnostic.new(:invalid_result, "result field must be a list", path: [:result, field])}

  defp counts(value) when is_map(value) and not is_struct(value) do
    if Enum.all?(value, fn {key, count} ->
         (is_atom(key) or is_binary(key)) and is_integer(count) and count >= 0
       end) do
      {:ok, value}
    else
      {:error, Diagnostic.new(:invalid_result, "operation counts are invalid")}
    end
  end

  defp counts(_value),
    do: {:error, Diagnostic.new(:invalid_result, "operation counts must be a map")}
end
