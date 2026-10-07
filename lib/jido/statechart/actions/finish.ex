defmodule Jido.Statechart.Actions.Finish do
  @moduledoc "Validates stable state and returns one atomic Statechart Result."

  use Jido.Action, name: "statechart_finish"

  alias Jido.Statechart.Runtime.Intent
  alias Jido.Statechart.{Diagnostic, Result}
  alias Jido.Statechart.Actions.Prepare
  alias Jido.Statechart.Semantics.Macrostep

  @impl true
  def run(params, context) do
    with :ok <- Prepare.validate_context(context),
         %{state: state} <- params,
         true <- is_map(state) and not is_struct(state),
         {:ok, raw} <- Macrostep.finish(state),
         {:ok, intents, session} <- intents(raw.intents, raw.session, state.options),
         {:ok, result} <-
           Result.new(%{
             session: session,
             intents: intents,
             trace: raw.trace,
             operation_counts: raw.operation_counts
           }) do
      {:ok, result}
    else
      {:error, _diagnostic} = error -> error
      _other -> {:error, Diagnostic.new(:invalid_flow_state, "Finish state is invalid")}
    end
  end

  defp intents(values, session, options) do
    registry = Keyword.fetch!(options, :registry)
    limits = Keyword.fetch!(options, :limits)
    now = Keyword.get(options, :now, DateTime.utc_now())

    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      generation = session.operation_counter + index

      case Intent.from_semantic(value, session, registry, limits, now,
             generation: generation,
             created_revision: session.revision
           ) do
        {:ok, operation} ->
          {:cont, {:ok, [operation | acc]}}

        {:error, diagnostic} ->
          {:halt, {:error, Diagnostic.prefix(diagnostic, [:intents, index])}}
      end
    end)
    |> then(fn
      {:ok, operations} ->
        operations = Enum.reverse(operations)

        {:ok, operations,
         %{session | operation_counter: session.operation_counter + length(values)}}

      error ->
        error
    end)
  end
end
