defmodule Jido.Statechart.Semantics.Domain do
  @moduledoc "SCXML transition domains, effective targets, and exit sets."

  alias Jido.Statechart.Model.{Chart, State, Transition}
  alias Jido.Statechart.Semantics.Configuration

  @history_kinds [:history_shallow, :history_deep]

  @spec effective_targets(Chart.t(), Transition.t(), map()) :: [String.t()]
  def effective_targets(%Chart{} = chart, %Transition{} = transition, history) do
    transition.target_ids
    |> Enum.flat_map(&dereference(chart, &1, history, MapSet.new()))
    |> Enum.uniq()
  end

  @spec transition_domain(Chart.t(), Transition.t(), map()) :: String.t() | nil
  def transition_domain(%Chart{}, %Transition{target_ids: []}, _history), do: nil

  def transition_domain(%Chart{} = chart, %Transition{} = transition, history) do
    targets = effective_targets(chart, transition, history)
    source = state(chart, transition.source_id)

    if transition.type == :internal and source.kind == :compound and
         Enum.all?(targets, &Configuration.descendant?(chart, &1, source.id)) do
      source.id
    else
      find_lcca(chart, [source.id | targets])
    end
  end

  @spec exit_set(Chart.t(), [Transition.t()], [String.t()], map()) :: [String.t()]
  def exit_set(%Chart{} = chart, transitions, configuration, history) do
    active = Configuration.active_state_ids(chart, configuration)

    ids =
      Enum.flat_map(transitions, fn
        %Transition{target_ids: []} ->
          []

        transition ->
          domain = transition_domain(chart, transition, history)
          Enum.filter(active, &Configuration.descendant?(chart, &1, domain))
      end)

    Configuration.exit_order(chart, ids)
  end

  defp dereference(chart, id, history, seen) do
    case state(chart, id) do
      %State{kind: kind} = history_state when kind in @history_kinds ->
        if MapSet.member?(seen, id) do
          []
        else
          case Map.get(history, id, []) do
            [] ->
              history_state.transition_ids
              |> Enum.flat_map(fn transition_id ->
                transition = Map.fetch!(Configuration.transition_map(chart), transition_id)

                transition.target_ids
                |> Enum.flat_map(&dereference(chart, &1, history, MapSet.put(seen, id)))
              end)

            saved ->
              Enum.flat_map(saved, &dereference(chart, &1, history, MapSet.put(seen, id)))
          end
        end

      %State{} ->
        [id]
    end
  end

  defp find_lcca(chart, [first | rest]) do
    by_id = Configuration.state_map(chart)

    chart
    |> Configuration.ancestors(first)
    |> Enum.find(fn candidate ->
      Map.fetch!(by_id, candidate).kind == :compound and
        Enum.all?(rest, &Configuration.descendant?(chart, &1, candidate))
    end)
  end

  defp state(chart, id), do: Map.fetch!(Configuration.state_map(chart), id)
end
