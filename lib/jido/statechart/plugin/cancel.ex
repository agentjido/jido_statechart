defmodule Jido.Statechart.Plugin.Cancel do
  @moduledoc false
  use Jido.Action, name: "statechart_runtime_cancel"

  alias Jido.Plugin.Input
  alias Jido.Statechart.Plugin
  alias Jido.Statechart.Plugin.Commit
  alias Jido.Statechart.Session.Operation

  @impl true
  def run(_params, context) do
    with %Input{
           prepared: %{
             kind: :runtime_cancel,
             session: session,
             operation_id: operation_id,
             target_operation_id: target_id,
             reason: reason,
             signal_id: signal_id
           },
           runtime: %{authenticated_reserved: true}
         } <- get_in(context, [:plugin_inputs, Plugin]),
         %Operation{} = operation <- Map.get(session.operations, operation_id),
         next_revision = session.revision + 1,
         {:ok, operations} <-
           cancel_operations(session.operations, operation, target_id, reason, next_revision),
         next = %{
           session
           | revision: next_revision,
             revision_fence: max(session.revision_fence, next_revision),
             operations: operations
         } do
      {:ok, context.agent_state,
       [
         %Commit{
           session: next,
           expected_revision: session.revision,
           signal_id: signal_id,
           operation: :cancel
         }
       ]}
    else
      _other -> {:error, :invalid_statechart_runtime_cancel}
    end
  end

  defp cancel_operations(
         operations,
         %Operation{kind: :cancel} = cancel,
         target_id,
         reason,
         revision
       ) do
    target = Map.get(operations, target_id)

    cond do
      reason in ["confirm_cancel", "complete_cancel"] ->
        result = %{"canceled" => true, "target_operation_id" => target_id}
        {:ok, Map.put(operations, cancel.id, completed(cancel, revision, result))}

      match?(%Operation{state: :result_unknown}, target) ->
        operations = Map.put(operations, target.id, requested(target))
        {:ok, Map.put(operations, cancel.id, requested(cancel, 1))}

      match?(%Operation{state: :cancel_requested}, target) ->
        {:ok, Map.put(operations, cancel.id, requested(cancel, 1))}

      match?(%Operation{}, target) and not Operation.terminal?(target) ->
        target = canceled(target, revision, reason)
        result = %{"canceled" => true, "target_operation_id" => target_id}

        {:ok,
         operations
         |> Map.put(target.id, target)
         |> Map.put(cancel.id, completed(cancel, revision, result))}

      true ->
        result = %{"canceled" => false, "target_operation_id" => target_id}
        {:ok, Map.put(operations, cancel.id, completed(cancel, revision, result))}
    end
  end

  defp cancel_operations(operations, %Operation{} = target, target_id, reason, revision)
       when target_id == target.id do
    cond do
      Operation.terminal?(target) ->
        {:ok, operations}

      reason == "confirm_cancel" ->
        {:ok, Map.put(operations, target.id, canceled(target, revision, reason))}

      target.state == :result_unknown ->
        {:ok, Map.put(operations, target.id, requested(target))}

      target.state == :cancel_requested ->
        {:ok, operations}

      true ->
        {:ok, Map.put(operations, target.id, canceled(target, revision, reason))}
    end
  end

  defp cancel_operations(_operations, _operation, _target_id, _reason, _revision),
    do: {:error, :operation_mismatch}

  defp canceled(operation, revision, reason) do
    %{
      operation
      | state: :canceled,
        attempt_count: operation.attempt_count,
        next_attempt_at: nil,
        result_revision: max(revision, operation.created_revision),
        result: %{"reason" => reason},
        retention_class: :terminal
    }
  end

  defp requested(operation, minimum_attempts \\ 0) do
    %{
      operation
      | state: :cancel_requested,
        attempt_count: max(operation.attempt_count, minimum_attempts),
        next_attempt_at: nil,
        retention_class: :active
    }
  end

  defp completed(operation, revision, result) do
    %{
      operation
      | state: :confirmed_complete,
        attempt_count: max(operation.attempt_count, 1),
        next_attempt_at: nil,
        result_revision: max(revision, operation.created_revision),
        result: result,
        retention_class: :terminal
    }
  end
end
