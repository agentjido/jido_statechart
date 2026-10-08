defmodule Jido.Statechart.Actions.Microstep do
  @moduledoc "Executes one planned semantic microstep inside Flow Iterate."

  use Jido.Action, name: "statechart_microstep"

  alias Jido.Statechart.{Diagnostic, Semantics}
  alias Jido.Statechart.Actions.Prepare

  @impl true
  def run(params, context) do
    with :ok <- Prepare.validate_context(context),
         %{state: state} <- params,
         true <- is_map(state) and not is_struct(state) do
      Semantics.Macrostep.advance(state)
    else
      {:error, _diagnostic} = error -> error
      _other -> {:error, Diagnostic.new(:invalid_flow_state, "Iterate state is invalid")}
    end
  end
end
