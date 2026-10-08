defmodule Jido.Statechart.Plugin.Commit do
  @moduledoc "Carries one complete stable session to the Statechart Plugin reducer."

  use Jido.Agent.Directive

  alias Jido.Statechart.Session
  alias Jido.Statechart.Session.Operation

  @enforce_keys [:session, :expected_revision, :signal_id, :operation]
  defstruct @enforce_keys ++ [intents: []]

  @type t :: %__MODULE__{
          session: Session.t(),
          expected_revision: non_neg_integer() | nil,
          signal_id: String.t(),
          operation:
            :initialize
            | :run
            | :cleanup
            | :schedule
            | :cancel
            | :runtime_result
            | :invoke
            | :stop_invoke
            | :child_result,
          intents: [Operation.t()]
        }

  @impl Jido.Agent.Directive
  def validate(%__MODULE__{} = directive) do
    with {:ok, session} <- Session.new(directive.session),
         {:ok, intents} <- intents(directive.intents),
         true <-
           is_nil(directive.expected_revision) or
             (is_integer(directive.expected_revision) and directive.expected_revision >= 0),
         true <-
           is_binary(directive.signal_id) and directive.signal_id != "" and
             String.valid?(directive.signal_id),
         true <-
           directive.operation in [
             :initialize,
             :run,
             :cleanup,
             :schedule,
             :cancel,
             :runtime_result,
             :invoke,
             :stop_invoke,
             :child_result
           ] do
      {:ok, %{directive | session: session, intents: intents}}
    else
      _other -> {:error, :invalid_statechart_commit}
    end
  end

  def validate(_value), do: {:error, :invalid_statechart_commit}

  defp intents(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case Operation.new(value) do
        {:ok, operation} -> {:cont, {:ok, [operation | acc]}}
        {:error, _diagnostic} -> {:halt, {:error, :invalid_statechart_commit}}
      end
    end)
    |> case do
      {:ok, operations} -> {:ok, Enum.reverse(operations)}
      {:error, _reason} = error -> error
    end
  end

  defp intents(_values), do: {:error, :invalid_statechart_commit}
end
