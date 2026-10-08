defmodule Jido.Statechart.Plugin.StopInvoke do
  @moduledoc false
  use Jido.Action, name: "statechart_runtime_stop_invoke"

  alias Jido.Plugin.Input
  alias Jido.Statechart.Plugin
  alias Jido.Statechart.Plugin.{Commit, OwnedChildControl}
  alias Jido.Statechart.Session.Operation

  @impl true
  def run(_params, context) do
    with %Input{
           prepared: %{
             kind: :runtime_stop_invoke,
             session: session,
             operation_id: operation_id,
             generation: generation,
             signal_id: signal_id
           },
           runtime: %{authenticated_reserved: true}
         } <- get_in(context, [:plugin_inputs, Plugin]),
         %Operation{kind: :child_stop, generation: ^generation} = stop <-
           Map.get(session.operations, operation_id),
         true <- stop.state in [:not_started, :result_unknown],
         invoke_id when is_binary(invoke_id) <- stop.correlation["invoke_operation_id"],
         %{kind: :invoke} = invoke <-
           Map.get(session.operations, invoke_id) ||
             Map.get(session.operation_tombstones, invoke_id),
         true <- invoke.target == stop.target,
         next_revision = session.revision + 1,
         operations =
           session.operations
           |> Map.put(
             stop.id,
             attempted(
               stop,
               Map.fetch!(get_in(context, [:plugin_inputs, Plugin]).prepared, :retry_backoff_ms),
               next_revision
             )
           )
           |> maybe_cancel_invoke(invoke),
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
           operation: :stop_invoke
         },
         %OwnedChildControl{
           action: :stop,
           tag: stop.target,
           invoke_operation_id: stop.correlation["invoke_operation_id"],
           invoke_generation: stop.correlation["invoke_generation"],
           invoke_id: stop.correlation["invoke_id"],
           session_incarnation: stop.session_incarnation,
           control_operation_id: stop.id
         }
       ]}
    else
      false -> {:error, :statechart_invocation_stop_no_longer_desired}
      _other -> {:error, :invalid_statechart_runtime_stop_invoke}
    end
  end

  defp attempted(%Operation{} = operation, backoff, revision) do
    attempt = operation.attempt_count + 1
    delay = min(backoff * Integer.pow(2, max(attempt - 1, 0)), 60_000)
    due = DateTime.utc_now() |> DateTime.add(delay, :millisecond) |> DateTime.to_iso8601()

    %{
      operation
      | state: :result_unknown,
        attempt_count: attempt,
        next_attempt_at: due,
        result: %{"attempt" => attempt, "next_attempt_at" => due, "outcome" => "control_attempt"},
        result_revision: revision
    }
  end

  defp maybe_cancel_invoke(operations, %Operation{} = invoke),
    do: Map.put(operations, invoke.id, cancel_requested(invoke))

  defp maybe_cancel_invoke(operations, _terminal_invoke), do: operations

  defp cancel_requested(%Operation{} = operation) do
    if Operation.terminal?(operation) do
      operation
    else
      %{
        operation
        | state: :cancel_requested,
          attempt_count: max(operation.attempt_count, 1),
          next_attempt_at: nil,
          retention_class: :active
      }
    end
  end
end
