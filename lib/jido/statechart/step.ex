defmodule Jido.Statechart.Step do
  @moduledoc "One generic Jido Action that returns the complete next Agent state and Directives."
  use Jido.Action, name: "statechart_step"
  alias Jido.Statechart.{AgentState, Definition, Error, Event, Interpreter, Registry}

  @impl Jido.Action
  def run(
        %{
          trusted:
            %{definition: %Definition{}, registry: %Registry{}, effects: effects} = trusted,
          event: %Event{} = event
        },
        %{agent_state: state}
      )
      when is_map(effects) do
    with {:ok, instance} <- AgentState.decode_state(state),
         {:ok, result} <- Interpreter.step(trusted.definition, instance, event, trusted.registry),
         {:ok, directives} <- directives(result.effects, trusted.effects) do
      {:ok, Map.merge(state, AgentState.encode_state(result.instance)), directives}
    end
  end

  def run(_, _),
    do: Error.result(:invalid_turn, "Step requires trusted Turn input and Agent state")

  defp directives(effects, builders) do
    Enum.reduce_while(effects, {:ok, []}, fn effect, {:ok, acc} ->
      case build(effect, builders) do
        {:ok, directive} -> {:cont, {:ok, [directive | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, directives} -> {:ok, Enum.reverse(directives)}
      error -> error
    end
  end

  defp build(effect, builders) do
    case Map.fetch(builders, effect.id) do
      {:ok, builder} ->
        case builder.(effect) do
          {:ok, directive} -> Jido.Agent.Directive.validate(directive)
          _ -> Error.result(:invalid_effect, "Effect builder must return one Directive")
        end

      :error ->
        Error.result(:unknown_effect, "No trusted Directive builder for effect ID", [effect.id])
    end
  rescue
    _ -> Error.result(:invalid_effect, "Directive builder raised or returned an invalid value")
  catch
    _, _ -> Error.result(:invalid_effect, "Directive builder did not return")
  end
end
