defmodule Jido.Statechart.Plugin.ChildResult do
  @moduledoc false
  use Jido.Action, name: "statechart_child_result"

  alias Jido.Plugin.Input
  alias Jido.Statechart.Model.Event
  alias Jido.Statechart.Plugin
  alias Jido.Statechart.Plugin.Commit
  alias Jido.Statechart.Runtime.Invocation
  alias Jido.Statechart.Session.Operation
  alias Jido.Statechart.{Flow, Result, Session}

  @impl true
  def run(_params, context) do
    with %Input{
           prepared: %{
             kind: :child_result,
             session: session,
             operation_id: operation_id,
             generation: generation,
             child_state: child_state,
             result: result,
             chart: chart,
             limits: limits,
             signal_id: signal_id
           },
           runtime: %{authenticated_reserved: true}
         } <- get_in(context, [:plugin_inputs, Plugin]),
         %Operation{generation: ^generation} = operation <-
           Map.get(session.operations, operation_id),
         {:ok, next, intents, directives} <-
           apply_child_result(session, operation, child_state, result, chart, limits) do
      next_revision = session.revision + 1

      next = %{
        next
        | revision: next_revision,
          revision_fence: max(next.revision_fence, next_revision)
      }

      {:ok, context.agent_state,
       [
         %Commit{
           session: next,
           expected_revision: session.revision,
           signal_id: signal_id,
           operation: :child_result,
           intents: intents
         }
         | directives
       ]}
    else
      {:ignore, %Session{}} -> {:ok, context.agent_state, []}
      {:error, reason} -> {:error, {:invalid_statechart_child_result, reason}}
      _other -> {:error, :invalid_statechart_child_result}
    end
  end

  defp apply_child_result(
         session,
         %Operation{kind: :invoke, state: :not_started} = operation,
         "started",
         result,
         _chart,
         _limits
       ) do
    with {:ok, updated, :applied} <-
           Session.apply_operation_result(
             session,
             operation.id,
             operation.generation,
             :result_unknown,
             %{"outcome" => "started", "value" => result},
             session.revision + 1
           ) do
      {:ok, updated, [], []}
    end
  end

  defp apply_child_result(
         session,
         %Operation{kind: :invoke, state: :result_unknown},
         "started",
         _result,
         _chart,
         _limits
       ) do
    {:ignore, session}
  end

  defp apply_child_result(
         session,
         %Operation{kind: :invoke, state: :cancel_requested},
         state,
         _result,
         _chart,
         _limits
       )
       when state in ["started", "done", "failed"] do
    {:ignore, session}
  end

  defp apply_child_result(
         session,
         %Operation{kind: :invoke} = operation,
         "done",
         result,
         chart,
         limits
       ) do
    with {:ok, updated, disposition} <-
           Session.apply_operation_result(
             session,
             operation.id,
             operation.generation,
             :confirmed_complete,
             %{"outcome" => "done", "value" => result},
             session.revision + 1
           ) do
      if disposition == :applied do
        event =
          Event.new!(%{
            name: "done.invoke.#{operation.correlation["invoke_id"]}",
            class: :platform,
            data: result,
            message_id: operation.id,
            invoke_id: operation.correlation["invoke_id"],
            origin: "/jido/statechart/child",
            origin_type: "jido.statechart",
            session_id: session.id
          })

        with {:ok, next, intents} <- platform_step(updated, event, chart, limits),
             {:ok, stop, next} <- Invocation.completion_stop(operation, next) do
          {:ok, next, intents ++ [stop], []}
        end
      else
        {:ignore, updated}
      end
    end
  end

  defp apply_child_result(
         session,
         %Operation{kind: :invoke} = operation,
         "failed",
         result,
         chart,
         limits
       ) do
    with {:ok, updated, disposition} <-
           Session.apply_operation_result(
             session,
             operation.id,
             operation.generation,
             :permanent_failure,
             %{"outcome" => "failed", "value" => result},
             session.revision + 1
           ) do
      if disposition == :applied do
        event =
          Event.new!(%{
            name: "error.communication",
            class: :platform,
            data: %{"invoke_id" => operation.correlation["invoke_id"], "result" => result},
            message_id: operation.id,
            invoke_id: operation.correlation["invoke_id"],
            origin: "/jido/statechart/child",
            origin_type: "jido.statechart",
            session_id: session.id
          })

        with {:ok, next, intents} <- platform_step(updated, event, chart, limits) do
          if Invocation.child_may_exist?(result) do
            with {:ok, stop, next} <- Invocation.completion_stop(operation, next) do
              {:ok, next, intents ++ [stop], []}
            end
          else
            {:ok, next, intents, []}
          end
        end
      else
        {:ignore, updated}
      end
    end
  end

  defp apply_child_result(
         session,
         %Operation{kind: :child_stop} = stop,
         "failed",
         result,
         chart,
         limits
       ) do
    communication_failure(session, stop, result, chart, limits)
  end

  defp apply_child_result(
         session,
         %Operation{kind: :child_start} = operation,
         "failed",
         result,
         chart,
         limits
       ) do
    communication_failure(session, operation, result, chart, limits)
  end

  defp apply_child_result(
         session,
         %Operation{kind: :child_stop} = stop,
         "stopped",
         result,
         _chart,
         _limits
       ) do
    invoke_id = stop.correlation["invoke_operation_id"]

    with {:ok, updated, stop_disposition} <-
           Session.apply_operation_result(
             session,
             stop.id,
             stop.generation,
             :confirmed_complete,
             %{"outcome" => "stopped", "value" => result},
             session.revision + 1
           ),
         {:ok, updated, invoke_disposition} <-
           cancel_invoke(updated, invoke_id, session.revision + 1) do
      if stop_disposition == :applied or invoke_disposition == :applied,
        do: {:ok, updated, [], []},
        else: {:ignore, updated}
    end
  end

  defp apply_child_result(
         session,
         %Operation{kind: :child_start} = operation,
         "forwarded",
         result,
         _chart,
         _limits
       ) do
    with {:ok, updated, disposition} <-
           Session.apply_operation_result(
             session,
             operation.id,
             operation.generation,
             :confirmed_complete,
             %{"outcome" => "forwarded", "value" => result},
             session.revision + 1
           ) do
      if disposition == :applied,
        do: {:ok, updated, [], []},
        else: {:ignore, updated}
    else
      _other -> {:error, :invalid_statechart_child_result}
    end
  end

  defp apply_child_result(_session, _operation, _state, _result, _chart, _limits),
    do: {:error, :invalid_child_result_transition}

  defp cancel_invoke(session, invoke_id, revision) do
    case Map.get(session.operations, invoke_id) do
      %Operation{state: :cancel_requested} = invoke ->
        Session.apply_operation_result(
          session,
          invoke.id,
          invoke.generation,
          :canceled,
          %{"outcome" => "canceled"},
          revision
        )

      %Operation{} = invoke
      when invoke.state in [:confirmed_complete, :permanent_failure, :canceled] ->
        {:ok, session, :duplicate}

      _other ->
        {:ok, session, :stale}
    end
  end

  defp communication_failure(session, operation, result, chart, limits) do
    with {:ok, updated, disposition} <-
           Session.apply_operation_result(
             session,
             operation.id,
             operation.generation,
             :permanent_failure,
             %{"outcome" => "failed", "value" => result},
             session.revision + 1
           ) do
      if disposition == :applied do
        if updated.status == :active do
          invoke_id = operation.correlation["invoke_id"]

          event =
            Event.new!(%{
              name: "error.communication",
              class: :platform,
              data: %{"invoke_id" => invoke_id, "result" => result},
              message_id: operation.id,
              invoke_id: invoke_id,
              origin: "/jido/statechart/child",
              origin_type: "jido.statechart",
              session_id: session.id
            })

          with {:ok, next, intents} <- platform_step(updated, event, chart, limits) do
            {:ok, next, intents, []}
          end
        else
          {:ok, updated, [], []}
        end
      else
        {:ignore, updated}
      end
    end
  end

  defp platform_step(session, event, chart, limits) do
    case Flow.platform_step(chart.chart(), session, event, chart.registry(), limits: limits) do
      {:ok, %Result{} = result} -> {:ok, result.session, result.intents}
      {:error, _reason} = error -> error
    end
  end
end
