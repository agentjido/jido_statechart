defmodule Jido.Statechart.Semantics.EntryExit do
  @moduledoc "Pure exit and entry planning for one SCXML microstep."

  alias Jido.Statechart.Diagnostic
  alias Jido.Statechart.Model.{Chart, Transition}
  alias Jido.Statechart.Semantics.{Configuration, Domain}

  @history_kinds [:history_shallow, :history_deep]

  @type entry_plan :: %{
          atomic_ids: [String.t()],
          entry_ids: [String.t()],
          default_entry_ids: [String.t()],
          history_content: %{optional(String.t()) => list()}
        }

  @spec initial_plan(Chart.t(), map()) :: entry_plan()
  def initial_plan(%Chart{} = chart, history) do
    targets = Diagnostic.fetch(chart.metadata, :root_initial, chart.root_state_ids)
    targets = if is_list(targets), do: targets, else: []
    build_plan(chart, [{targets, nil}], [], history)
  end

  @spec entry_plan(Chart.t(), [Transition.t()], [String.t()], map()) :: entry_plan()
  def entry_plan(%Chart{} = chart, transitions, remaining_configuration, history) do
    target_groups =
      transitions
      |> Enum.reject(&(&1.target_ids == []))
      |> Enum.map(&{&1.target_ids, Domain.transition_domain(chart, &1, history)})

    build_plan(chart, target_groups, remaining_configuration, history)
  end

  defp build_plan(chart, target_groups, remaining, history) do
    initial = %{atoms: [], defaults: [], history_content: %{}}

    expanded =
      Enum.reduce(target_groups, initial, fn {targets, _domain}, acc ->
        Enum.reduce(targets, acc, &expand(chart, &1, history, &2, MapSet.new()))
      end)

    atoms = fill_parallel_regions(chart, remaining ++ expanded.atoms, history, expanded)
    new_atoms = Configuration.entry_order(chart, Enum.uniq(atoms.atoms))
    all_atomic = Configuration.entry_order(chart, Enum.uniq(remaining ++ new_atoms))
    remaining_active = MapSet.new(Configuration.active_state_ids(chart, remaining))

    domains_by_atom =
      Enum.flat_map(target_groups, fn {targets, domain} ->
        local =
          Enum.reduce(targets, initial, &expand(chart, &1, history, &2, MapSet.new())).atoms

        Enum.map(local, &{&1, domain})
      end)

    domain_for = Map.new(domains_by_atom)

    unordered_entry_ids =
      new_atoms
      |> Enum.flat_map(fn atomic ->
        domain = Map.get(domain_for, atomic)

        [atomic | Configuration.ancestors(chart, atomic)]
        |> Enum.take_while(&(&1 != domain))
      end)
      |> Enum.reject(&MapSet.member?(remaining_active, &1))

    entry_ids = Configuration.entry_order(chart, unordered_entry_ids)

    %{
      atomic_ids: all_atomic,
      entry_ids: entry_ids,
      default_entry_ids: Enum.uniq(atoms.defaults),
      history_content: atoms.history_content
    }
  end

  defp expand(chart, id, history, acc, seen) do
    if MapSet.member?(seen, id) do
      acc
    else
      case fetch_state(chart, id) do
        nil ->
          acc

        state ->
          seen = MapSet.put(seen, id)

          case state.kind do
            kind when kind in [:atomic, :final] ->
              %{acc | atoms: acc.atoms ++ [id]}

            :compound ->
              acc = %{acc | defaults: acc.defaults ++ [id]}
              Enum.reduce(state.initial, acc, &expand(chart, &1, history, &2, seen))

            :parallel ->
              state
              |> Configuration.real_children(Configuration.state_map(chart))
              |> Enum.reduce(acc, &expand(chart, &1, history, &2, seen))

            kind when kind in @history_kinds ->
              history_targets(chart, state, history, acc, seen)
          end
      end
    end
  end

  defp history_targets(chart, state, history, acc, seen) do
    case Map.get(history, state.id, []) do
      [] ->
        case history_transition(chart, state) do
          nil ->
            acc

          transition ->
            next =
              if transition.executable == [] do
                acc
              else
                %{
                  acc
                  | history_content:
                      Map.put(acc.history_content, state.parent, transition.executable)
                }
              end

            Enum.reduce(transition.target_ids, next, &expand(chart, &1, history, &2, seen))
        end

      saved ->
        Enum.reduce(saved, acc, &expand(chart, &1, history, &2, seen))
    end
  end

  defp fill_parallel_regions(chart, coverage, history, acc) do
    by_id = Configuration.state_map(chart)
    active = MapSet.new(coverage)

    missing =
      coverage
      |> Enum.flat_map(&Configuration.ancestors(chart, &1))
      |> Enum.uniq()
      |> Enum.flat_map(fn id ->
        case Map.get(by_id, id) do
          %{kind: :parallel} = state ->
            state
            |> Configuration.real_children(by_id)
            |> Enum.reject(fn child ->
              Enum.any?(active, &(&1 == child or Configuration.descendant?(chart, &1, child)))
            end)

          _other ->
            []
        end
      end)

    if missing == [] do
      acc
    else
      next = Enum.reduce(missing, acc, &expand(chart, &1, history, &2, MapSet.new()))
      fill_parallel_regions(chart, coverage ++ next.atoms, history, next)
    end
  end

  defp history_transition(chart, state) do
    transitions = Configuration.transition_map(chart)

    case state.transition_ids do
      [transition_id] -> Map.get(transitions, transition_id)
      _other -> nil
    end
  end

  defp fetch_state(chart, id), do: Map.get(Configuration.state_map(chart), id)
end
