defmodule Jido.Statechart.Plugin.RuntimeResult do
  @moduledoc false
  use Jido.Action, name: "statechart_runtime_result"

  alias Jido.Plugin.Input
  alias Jido.Statechart.{Flow, Plugin, Result}
  alias Jido.Statechart.Model.Event
  alias Jido.Statechart.Plugin.Commit
  alias Jido.Statechart.Session

  @impl true
  def run(_params, context) do
    with %Input{
           prepared:
             %{
               kind: :runtime_result,
               session: session,
               operation_id: operation_id,
               generation: generation,
               result_state: result_state,
               result: result,
               signal_id: signal_id
             } = prepared,
           runtime: %{authenticated_reserved: true}
         } <- get_in(context, [:plugin_inputs, Plugin]) do
      if match?(%{state: :canceled}, Map.get(session.operations, operation_id)) do
        commit(session, session, signal_id, context)
      else
        chart = Map.get(prepared, :chart)
        limits = Map.get(prepared, :limits)

        apply_result(
          session,
          operation_id,
          generation,
          result_state,
          result,
          chart,
          limits,
          signal_id,
          context
        )
      end
    else
      _other -> {:error, :invalid_statechart_runtime_result}
    end
  end

  defp apply_result(
         session,
         operation_id,
         generation,
         result_state,
         result,
         chart,
         limits,
         signal_id,
         context
       ) do
    with next_revision = session.revision + 1,
         {:ok, updated, _disposition} <-
           Session.apply_operation_result(
             session,
             operation_id,
             generation,
             result_state,
             result,
             next_revision
           ),
         {:ok, next, intents} <-
           complete_turn(
             updated,
             operation_id,
             result_state,
             result,
             chart,
             limits,
             next_revision
           ) do
      commit(session, next, intents, signal_id, context)
    else
      _other -> {:error, :invalid_statechart_runtime_result}
    end
  end

  defp commit(previous, next, signal_id, context),
    do: commit(previous, next, [], signal_id, context)

  defp commit(previous, next, intents, signal_id, context) do
    next_revision = previous.revision + 1

    next = %{
      next
      | revision: next_revision,
        revision_fence: max(next.revision_fence, next_revision)
    }

    {:ok, context.agent_state,
     [
       %Commit{
         session: next,
         expected_revision: previous.revision,
         signal_id: signal_id,
         operation: :runtime_result,
         intents: intents
       }
     ]}
  end

  defp complete_turn(
         %{status: :active} = session,
         operation_id,
         :permanent_failure,
         result,
         chart,
         limits,
         _next_revision
       ) do
    event =
      Event.new!(%{
        name: "error.communication",
        class: :platform,
        data: %{"operation_id" => operation_id, "result" => result},
        message_id: operation_id,
        origin: "/jido/statechart/runtime",
        origin_type: "jido.statechart",
        session_id: session.id
      })

    case Flow.platform_step(chart.chart(), session, event, chart.registry(), limits: limits) do
      {:ok, %Result{} = flow_result} ->
        {:ok, flow_result.session, flow_result.intents}

      {:error, _reason} = error ->
        error
    end
  end

  defp complete_turn(session, _operation_id, _state, _result, _chart, _limits, next_revision) do
    {:ok,
     %{
       session
       | revision: next_revision,
         revision_fence: max(session.revision_fence, next_revision)
     }, []}
  end
end
