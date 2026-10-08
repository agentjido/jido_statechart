defmodule Jido.Statechart.Plugin.Invoke do
  @moduledoc false
  use Jido.Action, name: "statechart_runtime_invoke"

  alias Jido.Agent.Directive
  alias Jido.Plugin.Input
  alias Jido.Statechart.Plugin
  alias Jido.Statechart.Plugin.{ChildControlAck, Commit, OwnedChildControl}
  alias Jido.Statechart.Runtime.Invocation
  alias Jido.Statechart.Session.Operation

  @impl true
  def run(_params, context) do
    case get_in(context, [:plugin_inputs, Plugin]) do
      %Input{prepared: %{kind: :runtime_invoke_forward}} -> forward(context)
      _other -> spawn_control(context)
    end
  end

  defp spawn_control(context) do
    with %Input{
           prepared: %{
             kind: :runtime_invoke,
             session: session,
             operation_id: operation_id,
             generation: generation,
             registry: registry,
             signal_id: signal_id
           },
           runtime: %{authenticated_reserved: true}
         } <- get_in(context, [:plugin_inputs, Plugin]),
         %Operation{kind: :invoke, generation: ^generation} = operation <-
           Map.get(session.operations, operation_id),
         true <- operation.state in [:not_started, :result_unknown],
         true <- desired?(operation, session),
         {:ok, entry} <-
           Invocation.capability(
             registry,
             operation.correlation["capability"],
             operation.correlation["type"]
           ),
         next_revision = session.revision + 1,
         updated =
           attempted(
             operation,
             Map.fetch!(get_in(context, [:plugin_inputs, Plugin]).prepared, :retry_backoff_ms),
             next_revision
           ),
         next = %{
           session
           | revision: next_revision,
             revision_fence: max(session.revision_fence, next_revision),
             operations: Map.put(session.operations, operation.id, updated)
         },
         directive <- spawn_directive(entry, operation) do
      {:ok, context.agent_state,
       [
         %Commit{
           session: next,
           expected_revision: session.revision,
           signal_id: signal_id,
           operation: :invoke
         },
         directive
       ]}
    else
      false -> {:error, :statechart_invocation_no_longer_desired}
      _other -> {:error, :invalid_statechart_runtime_invoke}
    end
  end

  defp forward(context) do
    with %Input{
           prepared: %{
             kind: :runtime_invoke_forward,
             session: session,
             operation_id: operation_id,
             generation: generation,
             signal_id: signal_id
           },
           runtime: %{authenticated_reserved: true}
         } <- get_in(context, [:plugin_inputs, Plugin]),
         %Operation{
           kind: :child_start,
           generation: ^generation,
           correlation: %{"kind" => "invoke_send"} = correlation
         } = operation <- Map.get(session.operations, operation_id),
         true <- operation.state in [:not_started, :result_unknown],
         event when is_map(event) <- correlation["event"],
         name when is_binary(name) <- event["name"],
         {:ok, signal} <-
           Jido.Signal.new(name, event["data"],
             id: operation.id,
             source: "/jido/statechart/invoke"
           ),
         {:ok, signal} <-
           Jido.Signal.put_context(signal, "jidoscinvokeid", correlation["invoke_id"]),
         next_revision = session.revision + 1,
         next = %{
           session
           | revision: next_revision,
             revision_fence: max(session.revision_fence, next_revision),
             operations:
               Map.put(
                 session.operations,
                 operation.id,
                 attempted(
                   operation,
                   Map.fetch!(
                     get_in(context, [:plugin_inputs, Plugin]).prepared,
                     :retry_backoff_ms
                   ),
                   next_revision
                 )
               )
         } do
      {:ok, context.agent_state,
       [
         %Commit{
           session: next,
           expected_revision: session.revision,
           signal_id: signal_id,
           operation: :invoke
         },
         owned_control(:emit, operation, correlation, signal),
         %ChildControlAck{
           session_incarnation: operation.session_incarnation,
           operation_id: operation.id,
           generation: operation.generation
         }
       ]}
    else
      false -> {:error, :statechart_invocation_forward_no_longer_desired}
      _other -> {:error, :invalid_statechart_runtime_invoke_forward}
    end
  end

  defp desired?(operation, session) do
    owner = operation.correlation["owner_state_id"]

    not Enum.any?(session.operations, fn
      {_id, %Operation{kind: :child_stop, correlation: correlation} = stop} ->
        correlation["invoke_operation_id"] == operation.id and
          not Operation.terminal?(stop)

      _other ->
        false
    end) and is_binary(owner)
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

  defp spawn_directive(entry, operation) do
    input = operation.correlation["input"]
    input_mode = Map.get(entry.metadata, "input_mode", "metadata")

    options =
      if input_mode == "initial_state" and is_map(input) and map_size(input) > 0,
        do: [opts: %{initial_state: input}],
        else: []

    meta = %{
      "jido_statechart_operation_id" => operation.id,
      "jido_statechart_session_incarnation" => operation.session_incarnation,
      "jido_statechart_generation" => operation.generation,
      "jido_statechart_invoke_id" => operation.correlation["invoke_id"],
      "jido_statechart_input" => input,
      "jido_statechart_ancestry" => operation.correlation["ancestry"],
      "jido_statechart_depth" => operation.correlation["depth"],
      "jido_statechart_remaining_descendants" => operation.correlation["remaining_descendants"]
    }

    Directive.spawn_child(
      entry.handler,
      operation.target,
      options ++ [meta: meta, restart: :temporary]
    )
  end

  defp owned_control(action, operation, correlation, signal) do
    %OwnedChildControl{
      action: action,
      tag: operation.target,
      invoke_operation_id: correlation["invoke_operation_id"],
      invoke_generation: correlation["invoke_generation"],
      invoke_id: correlation["invoke_id"],
      session_incarnation: operation.session_incarnation,
      control_operation_id: operation.id,
      signal: signal
    }
  end
end
