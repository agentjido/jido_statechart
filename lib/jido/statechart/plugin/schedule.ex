defmodule Jido.Statechart.Plugin.Schedule do
  @moduledoc false
  use Jido.Action, name: "statechart_runtime_schedule"

  alias Jido.Plugin.Input
  alias Jido.Statechart.Plugin
  alias Jido.Statechart.Plugin.Commit
  alias Jido.Statechart.Runtime.Timer

  @impl true
  def run(params, context) do
    case get_in(context, [:plugin_inputs, Plugin]) do
      %Input{prepared: %{kind: :runtime_cancel}} ->
        Jido.Statechart.Plugin.Cancel.run(params, context)

      %Input{prepared: %{kind: kind}}
      when kind in [:runtime_invoke, :runtime_invoke_forward] ->
        Jido.Statechart.Plugin.Invoke.run(params, context)

      %Input{prepared: %{kind: :runtime_stop_invoke}} ->
        Jido.Statechart.Plugin.StopInvoke.run(params, context)

      _other ->
        schedule(context)
    end
  end

  defp schedule(context) do
    with %Input{
           prepared: %{
             kind: :runtime_schedule,
             session: session,
             operation_id: operation_id,
             generation: generation,
             signal_id: signal_id
           },
           runtime: %{authenticated_reserved: true}
         } <- get_in(context, [:plugin_inputs, Plugin]),
         %{generation: ^generation} = operation <- Map.get(session.operations, operation_id),
         true <- operation.state in [:not_started, :result_unknown, :retryable_failure],
         true <- Timer.due?(operation.next_attempt_at || operation.due_at, DateTime.utc_now()),
         next_revision = session.revision + 1,
         updated = %{
           operation
           | state: :result_unknown,
             attempt_count: operation.attempt_count + 1,
             next_attempt_at: nil
         },
         next =
           %{
             session
             | revision: next_revision,
               revision_fence: max(session.revision_fence, next_revision),
               operations: Map.put(session.operations, operation.id, updated)
           } do
      {:ok, context.agent_state,
       [
         %Commit{
           session: next,
           expected_revision: session.revision,
           signal_id: signal_id,
           operation: :schedule
         }
       ]}
    else
      false -> {:error, :statechart_runtime_operation_not_due}
      _other -> {:error, :invalid_statechart_runtime_schedule}
    end
  end
end
