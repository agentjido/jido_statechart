defmodule Jido.Statechart.Semantics.History do
  @moduledoc "Shallow and deep history values stored by history-state identifier."

  alias Jido.Statechart.Diagnostic
  alias Jido.Statechart.Model.{Chart, State}
  alias Jido.Statechart.Semantics.Configuration

  @history_kinds [:history_shallow, :history_deep]

  @spec validate(Chart.t(), map()) :: :ok | {:error, Diagnostic.t()}
  def validate(%Chart{} = chart, history) when is_map(history) do
    by_id = Configuration.state_map(chart)

    history
    |> Enum.reduce_while(:ok, fn {history_id, value}, :ok ->
      case Map.get(by_id, history_id) do
        %State{kind: kind, parent: parent} = history_state
        when kind in @history_kinds and is_binary(parent) ->
          case validate_value(chart, history_state, value, by_id) do
            :ok -> {:cont, :ok}
            {:error, _diagnostic} = error -> {:halt, error}
          end

        _other ->
          {:halt, invalid_history("history key must name a history state", history_id)}
      end
    end)
  end

  def validate(_chart, _history), do: invalid_history("history must be a map")

  @spec save(Chart.t(), [String.t()], [String.t()], map()) :: map()
  def save(%Chart{} = chart, configuration, exit_ids, history) do
    by_id = Configuration.state_map(chart)
    active = MapSet.new(Configuration.active_state_ids(chart, configuration))

    Enum.reduce(exit_ids, history, fn state_id, values ->
      state = Map.fetch!(by_id, state_id)

      state.children
      |> Enum.map(&Map.fetch!(by_id, &1))
      |> Enum.filter(&(&1.kind in @history_kinds))
      |> Enum.reduce(values, fn history_state, acc ->
        saved = history_value(chart, state, history_state, configuration, active)
        Map.put(acc, history_state.id, saved)
      end)
    end)
  end

  defp history_value(chart, parent, %State{kind: :history_deep}, configuration, _active) do
    ids = Enum.filter(configuration, &Configuration.descendant?(chart, &1, parent.id))
    Configuration.entry_order(chart, ids)
  end

  defp history_value(chart, parent, %State{kind: :history_shallow}, _configuration, active) do
    by_id = Configuration.state_map(chart)

    ids =
      parent
      |> Configuration.real_children(by_id)
      |> Enum.filter(&MapSet.member?(active, &1))

    Configuration.entry_order(chart, ids)
  end

  defp validate_value(chart, history_state, value, by_id)
       when is_list(value) and value != [] do
    parent = Map.fetch!(by_id, history_state.parent)

    cond do
      Enum.uniq(value) != value ->
        invalid_history("history value contains duplicate states", history_state.id)

      Enum.any?(value, &(not is_binary(&1) or not Map.has_key?(by_id, &1))) ->
        invalid_history("history value contains an unknown state", history_state.id)

      value != Configuration.entry_order(chart, value) ->
        invalid_history("history value is not in document order", history_state.id)

      history_state.kind == :history_shallow ->
        validate_shallow(parent, value, by_id, history_state.id)

      true ->
        case Configuration.validate_region(chart, value, parent.id) do
          :ok ->
            :ok

          {:error, _diagnostic} ->
            invalid_history("deep history value is not legal", history_state.id)
        end
    end
  end

  defp validate_value(_chart, history_state, _value, _by_id),
    do: invalid_history("history value must be a nonempty state list", history_state.id)

  defp validate_shallow(parent, value, by_id, history_id) do
    children = Configuration.real_children(parent, by_id)

    legal? =
      case parent.kind do
        :parallel -> value == children
        :compound -> length(value) == 1 and hd(value) in children
        _other -> false
      end

    if legal?,
      do: :ok,
      else: invalid_history("shallow history value is not legal", history_id)
  end

  defp invalid_history(message, history_id \\ nil) do
    path = if history_id, do: [:history, history_id], else: [:history]
    {:error, Diagnostic.new(:invalid_history, message, path: path)}
  end
end
