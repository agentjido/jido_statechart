defmodule Jido.Statechart.Plugin.Agent do
  @moduledoc false
  use Jido.Action, name: "statechart_agent_commit"

  alias Jido.Plugin.Input
  alias Jido.Statechart.{Plugin, Result}
  alias Jido.Statechart.Plugin.Commit

  @impl true
  def run(%{result: %Result{} = result}, context) do
    with %Input{prepared: prepared} <- get_in(context, [:plugin_inputs, Plugin]),
         %{kind: :macrostep, expected_revision: expected, signal_id: signal_id} <- prepared do
      session = add_receipt(result.session, Map.get(prepared, :receipt_operation_id))

      commit = %Commit{
        session: session,
        expected_revision: expected,
        signal_id: signal_id,
        operation: prepared.operation,
        intents: result.intents
      }

      {:ok, context.agent_state, [commit]}
    else
      _other -> {:error, :invalid_statechart_commit_input}
    end
  end

  def run(_params, _context), do: {:error, :invalid_statechart_result}

  defp add_receipt(session, nil), do: session

  defp add_receipt(session, operation_id) do
    receipts =
      session.received_operation_ids
      |> Kernel.++([operation_id])
      |> Enum.uniq()

    %{session | received_operation_ids: receipts}
  end
end
