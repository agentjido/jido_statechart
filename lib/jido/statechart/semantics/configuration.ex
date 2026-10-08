defmodule Jido.Statechart.Semantics.Configuration do
  @moduledoc "Canonical ordered atomic-state configurations and derived ancestry."

  alias Jido.Statechart.Diagnostic
  alias Jido.Statechart.Model.{Chart, State}

  @atomic_kinds [:atomic, :final]
  @history_kinds [:history_shallow, :history_deep]

  @spec canonical(Chart.t(), [String.t()]) ::
          {:ok, [String.t()]} | {:error, Diagnostic.t()}
  def canonical(%Chart{} = chart, ids) when is_list(ids) do
    by_id = state_map(chart)

    with :ok <- known_atomic_ids(ids, by_id),
         :ok <- unique(ids) do
      ordered = Enum.sort_by(ids, &Map.fetch!(by_id, &1).ordinal)

      case validate(chart, ordered) do
        :ok -> {:ok, ordered}
        {:error, _diagnostic} = error -> error
      end
    end
  end

  def canonical(_chart, _ids), do: invalid_configuration("configuration must be a list")

  @spec validate(Chart.t(), [String.t()]) :: :ok | {:error, Diagnostic.t()}
  def validate(%Chart{} = chart, ids) when is_list(ids) do
    by_id = state_map(chart)

    with :ok <- known_atomic_ids(ids, by_id),
         :ok <- unique(ids),
         :ok <- document_order(ids, by_id),
         :ok <- one_root_region(chart, ids, by_id),
         :ok <- compound_regions(ids, by_id),
         :ok <- parallel_regions(ids, by_id) do
      :ok
    end
  end

  def validate(_chart, _ids), do: illegal_configuration("configuration must be a list")

  @doc false
  @spec validate_region(Chart.t(), [String.t()], String.t()) ::
          :ok | {:error, Diagnostic.t()}
  def validate_region(%Chart{} = chart, ids, parent_id) when is_list(ids) do
    by_id = state_map(chart)

    with %State{} <- Map.get(by_id, parent_id),
         false <- ids == [],
         :ok <- known_atomic_ids(ids, by_id),
         :ok <- unique(ids),
         :ok <- document_order(ids, by_id),
         true <- Enum.all?(ids, &descendant?(chart, &1, parent_id)),
         :ok <- scoped_compound_regions(chart, ids, parent_id, by_id),
         :ok <- scoped_parallel_regions(chart, ids, parent_id, by_id) do
      :ok
    else
      {:error, _diagnostic} = error -> error
      _other -> illegal_configuration("history value is not a legal regional configuration")
    end
  end

  def validate_region(_chart, _ids, _parent_id),
    do: illegal_configuration("history value must be a list")

  @doc "Returns active atomic states and their ancestors in document order."
  @spec active_state_ids(Chart.t(), [String.t()]) :: [String.t()]
  def active_state_ids(%Chart{} = chart, configuration) do
    by_id = state_map(chart)

    configuration
    |> Enum.flat_map(fn id -> [id | ancestors(chart, id)] end)
    |> MapSet.new()
    |> Enum.sort_by(&Map.fetch!(by_id, &1).ordinal)
  end

  @doc "Returns proper ancestors from the parent toward the chart root."
  @spec ancestors(Chart.t(), String.t()) :: [String.t()]
  def ancestors(%Chart{} = chart, id), do: do_ancestors(state_map(chart), id)

  @doc "Returns true when child is a proper descendant of ancestor."
  @spec descendant?(Chart.t(), String.t(), String.t() | nil) :: boolean()
  def descendant?(_chart, _child, nil), do: true

  def descendant?(%Chart{} = chart, child, ancestor) do
    ancestor in ancestors(chart, child)
  end

  @doc "Returns the first direct child region below one ancestor."
  @spec region_below(Chart.t(), String.t(), String.t()) :: String.t() | nil
  def region_below(%Chart{} = chart, target, ancestor) do
    by_id = state_map(chart)
    do_region_below(by_id, target, ancestor)
  end

  @doc "Returns states in W3C entry order."
  @spec entry_order(Chart.t(), [String.t()]) :: [String.t()]
  def entry_order(%Chart{} = chart, ids) do
    by_id = state_map(chart)
    Enum.sort_by(Enum.uniq(ids), &Map.fetch!(by_id, &1).ordinal)
  end

  @doc "Returns states in W3C exit order."
  @spec exit_order(Chart.t(), [String.t()]) :: [String.t()]
  def exit_order(%Chart{} = chart, ids) do
    by_id = state_map(chart)
    Enum.sort_by(Enum.uniq(ids), &Map.fetch!(by_id, &1).ordinal, :desc)
  end

  @doc false
  def state_map(%Chart{} = chart), do: Map.new(chart.states, &{&1.id, &1})

  @doc false
  def transition_map(%Chart{} = chart), do: Map.new(chart.transitions, &{&1.id, &1})

  @doc false
  def real_children(%State{} = state, by_id) do
    Enum.reject(state.children, &(Map.fetch!(by_id, &1).kind in @history_kinds))
  end

  defp known_atomic_ids(ids, by_id) do
    ids
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {id, index}, :ok ->
      case Map.get(by_id, id) do
        %State{kind: kind} when kind in @atomic_kinds ->
          {:cont, :ok}

        %State{} ->
          {:halt,
           invalid_configuration("configuration can contain only atomic or final states", index)}

        nil ->
          {:halt, invalid_configuration("configuration contains an unknown state", index)}
      end
    end)
  end

  defp unique(ids) do
    case duplicate_index(ids) do
      nil -> :ok
      index -> invalid_configuration("configuration contains a duplicate state", index)
    end
  end

  defp duplicate_index(ids) do
    ids
    |> Enum.with_index()
    |> Enum.reduce_while(MapSet.new(), fn {id, index}, seen ->
      if MapSet.member?(seen, id),
        do: {:halt, index},
        else: {:cont, MapSet.put(seen, id)}
    end)
    |> case do
      %MapSet{} -> nil
      index -> index
    end
  end

  defp document_order(ids, by_id) do
    if ids == Enum.sort_by(ids, &Map.fetch!(by_id, &1).ordinal),
      do: :ok,
      else: illegal_configuration("configuration is not in document order")
  end

  defp one_root_region(chart, ids, by_id) do
    active_roots =
      Enum.filter(chart.root_state_ids, fn root ->
        Enum.any?(ids, &(&1 == root or root in do_ancestors(by_id, &1)))
      end)

    if length(active_roots) == 1,
      do: :ok,
      else: illegal_configuration("configuration must activate exactly one chart root")
  end

  defp compound_regions(ids, by_id) do
    active = active_set(ids, by_id)

    by_id
    |> Map.values()
    |> Enum.filter(&(&1.kind == :compound and MapSet.member?(active, &1.id)))
    |> Enum.reduce_while(:ok, fn state, :ok ->
      count =
        state
        |> real_children(by_id)
        |> Enum.count(&MapSet.member?(active, &1))

      if count == 1,
        do: {:cont, :ok},
        else: {:halt, illegal_configuration("active compound state must have one active child")}
    end)
  end

  defp parallel_regions(ids, by_id) do
    active = active_set(ids, by_id)

    by_id
    |> Map.values()
    |> Enum.filter(&(&1.kind == :parallel and MapSet.member?(active, &1.id)))
    |> Enum.reduce_while(:ok, fn state, :ok ->
      complete? = Enum.all?(real_children(state, by_id), &MapSet.member?(active, &1))

      if complete?,
        do: {:cont, :ok},
        else: {:halt, illegal_configuration("active parallel state must activate every region")}
    end)
  end

  defp scoped_compound_regions(chart, ids, parent_id, by_id) do
    active = active_set(ids, by_id)

    by_id
    |> Map.values()
    |> Enum.filter(fn state ->
      state.kind == :compound and MapSet.member?(active, state.id) and
        (state.id == parent_id or descendant?(chart, state.id, parent_id))
    end)
    |> Enum.reduce_while(:ok, fn state, :ok ->
      count =
        state
        |> real_children(by_id)
        |> Enum.count(&MapSet.member?(active, &1))

      if count == 1,
        do: {:cont, :ok},
        else: {:halt, illegal_configuration("active compound state must have one active child")}
    end)
  end

  defp scoped_parallel_regions(chart, ids, parent_id, by_id) do
    active = active_set(ids, by_id)

    by_id
    |> Map.values()
    |> Enum.filter(fn state ->
      state.kind == :parallel and MapSet.member?(active, state.id) and
        (state.id == parent_id or descendant?(chart, state.id, parent_id))
    end)
    |> Enum.reduce_while(:ok, fn state, :ok ->
      complete? = Enum.all?(real_children(state, by_id), &MapSet.member?(active, &1))

      if complete?,
        do: {:cont, :ok},
        else: {:halt, illegal_configuration("active parallel state must activate every region")}
    end)
  end

  defp active_set(ids, by_id) do
    ids
    |> Enum.flat_map(&[&1 | do_ancestors(by_id, &1)])
    |> MapSet.new()
  end

  defp do_ancestors(by_id, id) do
    case Map.get(by_id, id) do
      %State{parent: nil} -> []
      %State{parent: parent} -> [parent | do_ancestors(by_id, parent)]
      nil -> []
    end
  end

  defp do_region_below(by_id, target, ancestor) do
    case Map.get(by_id, target) do
      %State{parent: ^ancestor} -> target
      %State{parent: nil} -> nil
      %State{parent: parent} -> do_region_below(by_id, parent, ancestor)
      nil -> nil
    end
  end

  defp invalid_configuration(message, index \\ nil) do
    path = if is_nil(index), do: [:configuration], else: [:configuration, index]
    {:error, Diagnostic.new(:invalid_configuration, message, path: path)}
  end

  defp illegal_configuration(message) do
    {:error, Diagnostic.new(:illegal_configuration, message, path: [:configuration])}
  end
end
