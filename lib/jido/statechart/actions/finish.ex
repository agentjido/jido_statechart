defmodule Jido.Statechart.Actions.Finish do
  @moduledoc "Validates stable state and returns one atomic Statechart Result."

  use Jido.Action, name: "statechart_finish"

  alias Jido.Statechart.{Diagnostic, Result}
  alias Jido.Statechart.Actions.Prepare
  alias Jido.Statechart.Semantics.Macrostep
  alias Jido.Statechart.Session.Operation

  @impl true
  def run(params, context) do
    with :ok <- Prepare.validate_context(context),
         %{state: state} <- params,
         true <- is_map(state) and not is_struct(state),
         {:ok, raw} <- Macrostep.finish(state),
         {:ok, intents, session} <- intents(raw.intents, raw.session),
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

  defp intents(values, session) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      generation = session.operation_counter + index

      case intent(value, session, generation) do
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

  defp intent(%{} = value, session, generation) when not is_struct(value) do
    kind = Diagnostic.fetch(value, :kind)

    with {:ok, operation_kind} <- operation_kind(kind),
         {:ok, target} <- operation_target(operation_kind, value) do
      Operation.new(%{
        session_incarnation: session.incarnation,
        kind: operation_kind,
        target: target,
        payload_digest: Diagnostic.digest(value),
        generation: generation,
        created_revision: session.revision,
        correlation: value
      })
    end
  end

  defp intent(_value, _session, _generation),
    do: {:error, Diagnostic.new(:invalid_runtime_intent, "Runtime intent is invalid")}

  defp operation_kind(kind) when kind in [:send, "send"], do: {:ok, :send}
  defp operation_kind(kind) when kind in [:cancel, "cancel"], do: {:ok, :cancel}

  defp operation_kind(_kind),
    do: {:error, Diagnostic.new(:invalid_operation_kind, "Runtime intent kind is invalid")}

  defp operation_target(:send, value) do
    case Diagnostic.fetch(value, :target) do
      nil -> {:ok, "#_self"}
      target when is_binary(target) and target != "" -> {:ok, target}
      _other -> {:error, Diagnostic.new(:invalid_runtime_target, "Send target is invalid")}
    end
  end

  defp operation_target(:cancel, value) do
    case Diagnostic.fetch(value, :send_id) do
      send_id when is_binary(send_id) and send_id != "" -> {:ok, "send:" <> send_id}
      _other -> {:error, Diagnostic.new(:invalid_runtime_target, "Cancel send ID is invalid")}
    end
  end
end
