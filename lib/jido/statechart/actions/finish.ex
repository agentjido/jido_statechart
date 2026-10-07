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

    with {:ok, values} <- allocate_descendants(values, session, limits) do
      materialize_intents(values, session, registry, limits, now)
    end
  end

  defp materialize_intents(values, session, registry, limits, now) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      generation = session.operation_counter + index

      case Intent.from_semantic(value, session, registry, limits, now,
             generation: generation,
             created_revision: session.revision,
             prior_operations: Enum.reverse(acc)
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

        reserved =
          Enum.reduce(operations, 0, fn operation, total ->
            total + Map.get(operation.correlation, "reserved_descendants", 0)
          end)

        {:ok, operations,
         %{
           session
           | operation_counter: session.operation_counter + length(values),
             invocation_descendants_used: session.invocation_descendants_used + reserved
         }}

      error ->
        error
    end)
  end

  defp allocate_descendants(values, session, limits) do
    invoke_count =
      Enum.count(values, &invoke_intent?/1)

    available =
      (session.invocation_remaining_descendants || limits.total_descendants) -
        session.invocation_descendants_used

    cond do
      invoke_count == 0 ->
        {:ok, values}

      invoke_count > available ->
        {:error,
         Diagnostic.new(
           :invocation_descendant_limit_exceeded,
           "Invocation descendant budget was exhausted"
         )}

      true ->
        base = div(available, invoke_count)
        extra = rem(available, invoke_count)

        {values, _index} =
          Enum.map_reduce(values, 0, fn value, index ->
            if invoke_intent?(value) do
              reservation = base + if(index < extra, do: 1, else: 0)
              {Map.put(value, "reserved_descendants", reservation), index + 1}
            else
              {value, index}
            end
          end)

        {:ok, values}
    end
  end

  defp invoke_intent?(value) when is_map(value),
    do: Diagnostic.fetch(value, :kind) in [:invoke, "invoke"]

  defp invoke_intent?(_value), do: false
end
