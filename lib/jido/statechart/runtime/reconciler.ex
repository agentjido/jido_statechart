defmodule Jido.Statechart.Runtime.Reconciler do
  @moduledoc "Plans bounded convergence from the committed operation ledger."

  alias Jido.Statechart.Runtime.Timer
  alias Jido.Statechart.Session.Operation
  alias Jido.Statechart.{Limits, Session}

  @type action ::
          {:schedule, Operation.t()}
          | {:dispatch, Operation.t()}
          | {:cancel, Operation.t(), Operation.t() | nil}
          | {:cancel_replaced, Operation.t(), Operation.t()}
          | {:cancel_stale, Operation.t(), non_neg_integer()}
          | {:confirm_cancel, Operation.t()}
          | {:complete_cancel, Operation.t()}

  @spec plan(Session.t(), DateTime.t() | String.t(), Limits.t()) :: [action()]
  def plan(%Session{} = session, now, %Limits{} = limits) do
    operations =
      session.operations
      |> Map.values()
      |> Enum.sort_by(&{&1.created_revision, &1.generation, &1.id})

    replacements = replacement_actions(operations, session.operation_high_water)

    canceled_ids =
      MapSet.new(replacements, fn
        {:cancel_replaced, old, _new} -> old.id
        {:cancel_stale, old, _generation} -> old.id
      end)

    cancels = cancel_actions(operations)

    canceled_ids =
      Enum.reduce(cancels, canceled_ids, fn
        {:cancel, _cancel, nil}, ids -> ids
        {:cancel, _cancel, target}, ids -> MapSet.put(ids, target.id)
      end)

    cancellation_work =
      Enum.flat_map(operations, fn
        %Operation{state: :cancel_requested, kind: :cancel} = operation ->
          if active_cancel_target?(operation, operations),
            do: [],
            else: [{:complete_cancel, operation}]

        %Operation{state: :cancel_requested} = operation ->
          [{:confirm_cancel, operation}]

        _operation ->
          []
      end)

    work =
      Enum.flat_map(operations, fn operation ->
        if MapSet.member?(canceled_ids, operation.id) do
          []
        else
          operation_action(operation, now)
        end
      end)

    (replacements ++ cancels ++ cancellation_work ++ work)
    |> Enum.uniq_by(&action_key/1)
    |> Enum.take(limits.reconciliation_batch)
  end

  defp replacement_actions(operations, high_water) do
    deliveries = Enum.filter(operations, &delivery?/1)

    deliveries
    |> Enum.filter(&(replaceable_delivery?(&1) and is_binary(&1.key)))
    |> Enum.flat_map(fn old ->
      newer =
        deliveries
        |> Enum.filter(&(&1.key == old.key and &1.generation > old.generation))
        |> Enum.max_by(& &1.generation, fn -> nil end)

      cond do
        newer ->
          [{:cancel_replaced, old, newer}]

        Map.get(high_water, old.key, old.generation) > old.generation ->
          [{:cancel_stale, old, Map.fetch!(high_water, old.key)}]

        true ->
          []
      end
    end)
    |> Enum.sort_by(fn
      {:cancel_replaced, old, _new} -> old.generation
      {:cancel_stale, old, _generation} -> old.generation
    end)
  end

  defp cancel_actions(operations) do
    deliveries = Enum.filter(operations, &replaceable_delivery?/1)

    operations
    |> Enum.filter(&(&1.kind == :cancel and &1.state == :not_started))
    |> Enum.map(fn cancel ->
      target =
        deliveries
        |> Enum.filter(&(&1.key == cancel.key and &1.generation < cancel.generation))
        |> Enum.max_by(& &1.generation, fn -> nil end)

      {:cancel, cancel, target}
    end)
  end

  defp operation_action(%Operation{kind: :cancel}, _now), do: []

  defp operation_action(%Operation{state: :not_started} = operation, now) do
    if Timer.due?(operation.due_at, now), do: [{:schedule, operation}], else: []
  end

  defp operation_action(
         %Operation{state: :result_unknown, next_attempt_at: nil} = operation,
         _now
       ),
       do: [{:dispatch, operation}]

  defp operation_action(%Operation{state: :result_unknown} = operation, now) do
    if Timer.due?(operation.next_attempt_at, now), do: [{:schedule, operation}], else: []
  end

  defp operation_action(%Operation{state: :retryable_failure} = operation, now) do
    if Timer.due?(operation.next_attempt_at, now), do: [{:schedule, operation}], else: []
  end

  defp operation_action(_operation, _now), do: []

  defp replaceable_delivery?(%Operation{kind: kind, state: state}),
    do: kind in [:send, :timer] and state in [:not_started, :result_unknown, :retryable_failure]

  defp delivery?(%Operation{kind: kind}), do: kind in [:send, :timer]

  defp active_cancel_target?(cancel, operations) do
    Enum.any?(operations, fn operation ->
      operation.kind in [:send, :timer] and operation.key == cancel.key and
        operation.generation < cancel.generation and operation.state == :cancel_requested
    end)
  end

  defp action_key({kind, operation}), do: {kind, operation.id}

  defp action_key({:cancel_stale, operation, generation}),
    do: {:cancel_stale, operation.id, generation}

  defp action_key({kind, operation, target}), do: {kind, operation.id, target && target.id}
end
