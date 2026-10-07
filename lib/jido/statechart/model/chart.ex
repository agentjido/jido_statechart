defmodule Jido.Statechart.Model.Chart do
  @moduledoc """
  An immutable normalized chart.

  States and transitions stay in document order. Lookup indexes contain only
  string identifiers and ordinals. The fingerprint covers normalized semantic
  data and the profile version.
  """

  alias Jido.Statechart.Diagnostic
  alias Jido.Statechart.Model.{Executable, Source, State, Transition}

  @datamodels ["null", "jido"]
  @semantic_fields [
    :id,
    :name,
    :profile_version,
    :datamodel,
    :binding,
    :root_state_ids,
    :states,
    :transitions,
    :metadata,
    :source
  ]
  @stored_fields @semantic_fields ++ [:state_index, :transition_index, :fingerprint]

  defstruct id: nil,
            name: nil,
            profile_version: nil,
            datamodel: nil,
            binding: "early",
            root_state_ids: [],
            states: [],
            transitions: [],
            state_index: %{},
            transition_index: %{},
            metadata: %{},
            source: nil,
            fingerprint: nil

  @type t :: %__MODULE__{}

  @spec new(map()) :: {:ok, t()} | {:error, Diagnostic.t()}
  def new(%__MODULE__{} = chart),
    do: chart |> Map.from_struct() |> Map.take(@semantic_fields) |> new()

  def new(attrs) when is_map(attrs) do
    with :ok <- Diagnostic.validate_fields(attrs, @semantic_fields, [:chart]),
         {:ok, id} <- id(attrs),
         {:ok, name} <- Diagnostic.optional_string(attrs, :name, [:chart]),
         {:ok, profile_version} <-
           Diagnostic.require_string(attrs, :profile_version, [:chart]),
         {:ok, datamodel} <- datamodel(Diagnostic.fetch(attrs, :datamodel)),
         {:ok, binding} <- binding_value(Diagnostic.fetch(attrs, :binding, "early")),
         {:ok, states} <- states(Diagnostic.fetch(attrs, :states, [])),
         {:ok, transitions} <- transitions(Diagnostic.fetch(attrs, :transitions, [])),
         :ok <- unique_ids(states, transitions),
         :ok <- ordered(states, :states),
         :ok <- ordered(transitions, :transitions),
         {:ok, root_state_ids} <-
           root_ids(Diagnostic.fetch(attrs, :root_state_ids, []), states),
         :ok <- state_links(states, root_state_ids),
         :ok <- transition_links(transitions, states),
         :ok <- history_transitions(states, transitions),
         {:ok, metadata} <- metadata(Diagnostic.fetch(attrs, :metadata, %{})),
         :ok <- semantic_metadata(metadata, root_state_ids, states),
         :ok <- null_action_content(datamodel, states, transitions, metadata),
         {:ok, source} <- source(Diagnostic.fetch(attrs, :source)) do
      chart = %__MODULE__{
        id: id,
        name: name,
        profile_version: profile_version,
        datamodel: datamodel,
        binding: binding,
        root_state_ids: root_state_ids,
        states: states,
        transitions: transitions,
        state_index: Map.new(states, &{&1.id, &1.ordinal}),
        transition_index: Map.new(transitions, &{&1.id, &1.ordinal}),
        metadata: metadata,
        source: source
      }

      {:ok, %{chart | fingerprint: fingerprint(chart)}}
    end
  end

  def new(_attrs),
    do: {:error, Diagnostic.new(:invalid_chart, "chart must be a map", path: [:chart])}

  @spec new!(map()) :: t()
  def new!(attrs), do: attrs |> new() |> Diagnostic.unwrap!()

  @doc "Loads a chart from its portable map form."
  @spec load(map()) :: {:ok, t()} | {:error, Diagnostic.t()}
  def load(value) when is_map(value) do
    semantic_keys = @semantic_fields ++ Enum.map(@semantic_fields, &Atom.to_string/1)

    with :ok <- Diagnostic.validate_fields(value, @stored_fields, [:chart]),
         :ok <- required_stored_fields(value),
         {:ok, chart} <- value |> Map.take(semantic_keys) |> new(),
         :ok <- stored_value(value, :state_index, chart.state_index),
         :ok <- stored_value(value, :transition_index, chart.transition_index),
         :ok <- stored_value(value, :fingerprint, chart.fingerprint) do
      {:ok, chart}
    end
  end

  def load(_value),
    do: {:error, Diagnostic.new(:invalid_chart, "stored chart must be a map", path: [:chart])}

  @doc "Returns the portable map form of a chart."
  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = chart) do
    %{
      "id" => chart.id,
      "name" => chart.name,
      "profile_version" => chart.profile_version,
      "datamodel" => chart.datamodel,
      "binding" => chart.binding,
      "root_state_ids" => chart.root_state_ids,
      "states" => Enum.map(chart.states, &State.dump/1),
      "transitions" => Enum.map(chart.transitions, &Transition.dump/1),
      "state_index" => chart.state_index,
      "transition_index" => chart.transition_index,
      "metadata" => chart.metadata,
      "source" => if(chart.source, do: Source.dump(chart.source)),
      "fingerprint" => chart.fingerprint
    }
  end

  @doc "Returns one deterministic generated identifier."
  @spec generated_id(String.t(), [non_neg_integer()], non_neg_integer()) :: String.t()
  def generated_id(kind, path, ordinal)
      when is_binary(kind) and is_list(path) and is_integer(ordinal) and ordinal >= 0 do
    seed = [kind, Enum.join(path, "."), Integer.to_string(ordinal)] |> Enum.join("|")
    suffix = seed |> Diagnostic.digest() |> binary_part(0, 20)
    "__jido_#{safe_kind(kind)}_#{suffix}"
  end

  @doc "Calculates the deterministic semantic fingerprint."
  @spec fingerprint(t()) :: String.t()
  def fingerprint(%__MODULE__{} = chart) do
    Diagnostic.digest(%{
      "id" => chart.id,
      "name" => chart.name,
      "profile_version" => chart.profile_version,
      "datamodel" => chart.datamodel,
      "binding" => chart.binding,
      "root_state_ids" => chart.root_state_ids,
      "states" => Enum.map(chart.states, &State.dump/1),
      "transitions" => Enum.map(chart.transitions, &Transition.dump/1),
      "metadata" => chart.metadata,
      "source" => if(chart.source, do: Source.dump(chart.source))
    })
  end

  @doc false
  @spec legal_transition_targets?(String.t(), [String.t()], [State.t() | map()]) :: boolean()
  def legal_transition_targets?(source_id, targets, states)
      when is_binary(source_id) and is_list(targets) and is_list(states) do
    by_id = Map.new(states, &{&1.id, &1})

    Map.has_key?(by_id, source_id) and
      Enum.all?(targets, &Map.has_key?(by_id, &1)) and
      length(targets) == length(Enum.uniq(targets)) and
      legal_state_spec?(targets, by_id) and
      legal_history_targets?(Map.fetch!(by_id, source_id), targets, by_id)
  end

  def legal_transition_targets?(_source_id, _targets, _states), do: false

  defp id(attrs) do
    with {:ok, id} <- Diagnostic.require_string(attrs, :id, [:chart]),
         :ok <- Diagnostic.validate_id(id, [:chart, :id]),
         do: {:ok, id}
  end

  defp datamodel(value) when value in @datamodels, do: {:ok, value}

  defp datamodel(_value),
    do:
      {:error,
       Diagnostic.new(:invalid_datamodel, "datamodel must be null or jido",
         path: [:chart, :datamodel]
       )}

  defp binding_value(value) when value in ["early", "late"], do: {:ok, value}

  defp binding_value(_value),
    do:
      {:error,
       Diagnostic.new(:invalid_binding, "binding must be early or late", path: [:chart, :binding])}

  defp states(values) when is_list(values) do
    parse_list(values, &State.new/1, :states)
  end

  defp states(_values),
    do: {:error, Diagnostic.new(:invalid_states, "states must be a list", path: [:states])}

  defp transitions(values) when is_list(values) do
    parse_list(values, &Transition.new/1, :transitions)
  end

  defp transitions(_values),
    do:
      {:error,
       Diagnostic.new(:invalid_transitions, "transitions must be a list", path: [:transitions])}

  defp parse_list(values, parser, field) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      case parser.(value) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, diagnostic} -> {:halt, {:error, Diagnostic.prefix(diagnostic, [field, index])}}
      end
    end)
    |> then(fn
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end)
  end

  defp unique_ids(states, transitions) do
    (Enum.map(states, & &1.id) ++ Enum.map(transitions, & &1.id))
    |> Enum.with_index()
    |> Enum.reduce_while(MapSet.new(), fn {id, index}, seen ->
      if MapSet.member?(seen, id) do
        field = if index < length(states), do: :states, else: :transitions
        local_index = if field == :states, do: index, else: index - length(states)

        {:halt,
         {:error,
          Diagnostic.new(:duplicate_id, "chart identifiers must be unique",
            path: [field, local_index, :id]
          )}}
      else
        {:cont, MapSet.put(seen, id)}
      end
    end)
    |> case do
      %MapSet{} -> :ok
      error -> error
    end
  end

  defp ordered(values, field) do
    values
    |> Enum.with_index()
    |> Enum.find(fn {value, index} -> value.ordinal != index end)
    |> case do
      nil ->
        :ok

      {_value, index} ->
        {:error,
         Diagnostic.new(:invalid_ordinal, "#{field} ordinals must be contiguous document order",
           path: [field, index, :ordinal]
         )}
    end
  end

  defp root_ids(values, states) when is_list(values) and values != [] do
    state_ids = MapSet.new(states, & &1.id)

    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, {[], MapSet.new()}}, fn {value, index}, {:ok, {acc, seen}} ->
      cond do
        Diagnostic.validate_id(value, [:root_state_ids, index]) != :ok ->
          {:halt, Diagnostic.validate_id(value, [:root_state_ids, index])}

        not MapSet.member?(state_ids, value) ->
          {:halt,
           {:error,
            Diagnostic.new(:unknown_state, "root state does not exist",
              path: [:root_state_ids, index]
            )}}

        MapSet.member?(seen, value) ->
          {:halt,
           {:error,
            Diagnostic.new(:duplicate_root_state, "root state identifiers must be unique",
              path: [:root_state_ids, index]
            )}}

        true ->
          {:cont, {:ok, {[value | acc], MapSet.put(seen, value)}}}
      end
    end)
    |> then(fn
      {:ok, {ids, _seen}} -> {:ok, Enum.reverse(ids)}
      error -> error
    end)
  end

  defp root_ids([], _states),
    do:
      {:error,
       Diagnostic.new(:invalid_root_states, "chart must contain at least one root state",
         path: [:root_state_ids]
       )}

  defp root_ids(_values, _states),
    do:
      {:error,
       Diagnostic.new(:invalid_root_states, "root state identifiers must be a list",
         path: [:root_state_ids]
       )}

  defp state_links(states, roots) do
    by_id = Map.new(states, &{&1.id, &1})
    root_set = MapSet.new(roots)

    with :ok <-
           states
           |> Enum.with_index()
           |> Enum.reduce_while(:ok, fn {state, index}, :ok ->
             case valid_parent(state, index, by_id, root_set) do
               :ok -> {:cont, :ok}
               {:error, _} = error -> {:halt, error}
             end
           end) do
      states
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {state, index}, :ok ->
        with :ok <- valid_children(state, index, by_id),
             :ok <- valid_initial(state, index, by_id),
             :ok <- parent_lists_child(state, index, by_id),
             :ok <- acyclic_parent(state, index, by_id) do
          {:cont, :ok}
        else
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  defp parent_lists_child(%State{parent: nil}, _index, _by_id), do: :ok

  defp parent_lists_child(%State{id: id, parent: parent}, index, by_id) do
    if id in Map.fetch!(by_id, parent).children do
      :ok
    else
      {:error,
       Diagnostic.new(:invalid_parent, "parent does not list this state as a child",
         path: [:states, index, :parent]
       )}
    end
  end

  defp valid_parent(%State{parent: nil, id: id}, _index, _by_id, roots) do
    if MapSet.member?(roots, id),
      do: :ok,
      else: {:error, Diagnostic.new(:invalid_parent, "top-level state is not a chart root")}
  end

  defp valid_parent(%State{id: id, parent: parent}, index, by_id, roots) do
    cond do
      id == parent ->
        {:error,
         Diagnostic.new(:invalid_parent, "state cannot be its own parent",
           path: [:states, index, :parent]
         )}

      not Map.has_key?(by_id, parent) ->
        {:error,
         Diagnostic.new(:invalid_parent, "parent state does not exist",
           path: [:states, index, :parent]
         )}

      MapSet.member?(roots, id) ->
        {:error,
         Diagnostic.new(:invalid_parent, "root state cannot have a parent",
           path: [:states, index, :parent]
         )}

      true ->
        :ok
    end
  end

  defp valid_children(state, index, by_id) do
    state.children
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {child_id, child_index}, :ok ->
      case Map.get(by_id, child_id) do
        %State{parent: parent} when parent == state.id ->
          {:cont, :ok}

        %State{} ->
          {:halt,
           {:error,
            Diagnostic.new(:invalid_parent, "child does not name this state as parent",
              path: [:states, index, :children, child_index]
            )}}

        nil ->
          {:halt,
           {:error,
            Diagnostic.new(:unknown_state, "child state does not exist",
              path: [:states, index, :children, child_index]
            )}}
      end
    end)
  end

  defp valid_initial(state, index, by_id) do
    valid_descendants? =
      Enum.all?(state.initial, fn initial_id ->
        Map.has_key?(by_id, initial_id) and state.id in state_ancestors(initial_id, by_id)
      end)

    if valid_descendants? and legal_state_spec?(state.initial, by_id) do
      :ok
    else
      {:error,
       Diagnostic.new(
         :invalid_initial,
         "initial targets must be a legal descendant state specification",
         path: [:states, index, :initial]
       )}
    end
  end

  defp legal_state_spec?([], _by_id), do: true
  defp legal_state_spec?([_target], _by_id), do: true

  defp legal_state_spec?(targets, by_id) do
    no_ancestor_pair? =
      Enum.all?(targets, fn target ->
        Enum.all?(targets -- [target], fn other -> target not in state_ancestors(other, by_id) end)
      end)

    lcca = lowest_common_state_ancestor(targets, by_id)

    no_ancestor_pair? and match?(%{kind: :parallel}, Map.get(by_id, lcca)) and
      targets
      |> Enum.map(&state_region_below(&1, lcca, by_id))
      |> then(&(nil not in &1 and length(&1) == length(Enum.uniq(&1))))
  end

  defp lowest_common_state_ancestor([first | rest], by_id) do
    Enum.find(state_ancestors(first, by_id), fn candidate ->
      Enum.all?(rest, &(candidate in state_ancestors(&1, by_id)))
    end)
  end

  defp state_ancestors(id, by_id) do
    case Map.get(by_id, id) do
      %{parent: nil} -> []
      %{parent: parent} -> [parent | state_ancestors(parent, by_id)]
      nil -> []
    end
  end

  defp state_region_below(target, ancestor, by_id) do
    case Map.get(by_id, target) do
      %{parent: ^ancestor} -> target
      %{parent: nil} -> nil
      %{parent: parent} -> state_region_below(parent, ancestor, by_id)
      nil -> nil
    end
  end

  defp acyclic_parent(state, index, by_id) do
    case parent_chain(state.parent, by_id, MapSet.new([state.id])) do
      :ok ->
        :ok

      :cycle ->
        {:error,
         Diagnostic.new(:invalid_parent, "state parent links contain a cycle",
           path: [:states, index, :parent]
         )}
    end
  end

  defp parent_chain(nil, _by_id, _seen), do: :ok

  defp parent_chain(parent, by_id, seen) do
    if MapSet.member?(seen, parent) do
      :cycle
    else
      case Map.get(by_id, parent) do
        nil -> :ok
        state -> parent_chain(state.parent, by_id, MapSet.put(seen, parent))
      end
    end
  end

  defp transition_links(transitions, states) do
    ids = MapSet.new(states, & &1.id)
    by_id = Map.new(transitions, &{&1.id, &1})

    with :ok <-
           transitions
           |> Enum.with_index()
           |> Enum.reduce_while(:ok, fn {transition, index}, :ok ->
             cond do
               not MapSet.member?(ids, transition.source_id) ->
                 {:halt,
                  {:error,
                   Diagnostic.new(:unknown_state, "transition source does not exist",
                     path: [:transitions, index, :source_id]
                   )}}

               invalid_target =
                   Enum.find_index(transition.target_ids, &(not MapSet.member?(ids, &1))) ->
                 {:halt,
                  {:error,
                   Diagnostic.new(:unknown_state, "transition target does not exist",
                     path: [:transitions, index, :target_ids, invalid_target]
                   )}}

               not legal_transition_targets?(
                 transition.source_id,
                 transition.target_ids,
                 states
               ) ->
                 {:halt,
                  {:error,
                   Diagnostic.new(
                     :invalid_transition_targets,
                     "transition targets must be a legal state specification",
                     path: [:transitions, index, :target_ids]
                   )}}

               true ->
                 {:cont, :ok}
             end
           end) do
      states
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {state, state_index}, :ok ->
        state.transition_ids
        |> Enum.with_index()
        |> Enum.reduce_while(:ok, fn {transition_id, transition_index}, :ok ->
          case Map.get(by_id, transition_id) do
            %Transition{source_id: source_id} when source_id == state.id ->
              {:cont, :ok}

            %Transition{} ->
              {:halt,
               {:error,
                Diagnostic.new(
                  :invalid_transition_source,
                  "state lists a transition from another source",
                  path: [:states, state_index, :transition_ids, transition_index]
                )}}

            nil ->
              {:halt,
               {:error,
                Diagnostic.new(:unknown_transition, "state transition does not exist",
                  path: [:states, state_index, :transition_ids, transition_index]
                )}}
          end
        end)
        |> case do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        :ok -> transitions_listed_by_source(transitions, states)
        error -> error
      end
    end
  end

  defp transitions_listed_by_source(transitions, states) do
    states_by_id = Map.new(states, &{&1.id, &1})

    transitions
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {transition, index}, :ok ->
      if transition.id in Map.fetch!(states_by_id, transition.source_id).transition_ids do
        {:cont, :ok}
      else
        {:halt,
         {:error,
          Diagnostic.new(:invalid_transition_source, "source state does not list this transition",
            path: [:transitions, index, :source_id]
          )}}
      end
    end)
  end

  defp history_transitions(states, transitions) do
    by_id = Map.new(transitions, &{&1.id, &1})

    states
    |> Enum.with_index()
    |> Enum.filter(fn {state, _index} ->
      state.kind in [:history_shallow, :history_deep]
    end)
    |> Enum.reduce_while(:ok, fn {state, index}, :ok ->
      valid? =
        case state.transition_ids do
          [transition_id] ->
            case Map.get(by_id, transition_id) do
              %Transition{} = transition ->
                transition.source_id == state.id and transition.target_ids != [] and
                  transition.events == [] and is_nil(transition.condition) and
                  transition.type == :external and ordered_executables?(transition.executable)

              nil ->
                false
            end

          _other ->
            false
        end

      if valid? do
        {:cont, :ok}
      else
        {:halt,
         {:error,
          Diagnostic.new(
            :invalid_history_transition,
            "history state must have one target-only default transition",
            path: [:states, index, :transition_ids]
          )}}
      end
    end)
  end

  defp semantic_metadata(metadata, root_state_ids, states) do
    with {:ok, root_initial} <- required_metadata_value(metadata, :root_initial),
         :ok <- valid_root_initial(root_initial, root_state_ids, states),
         {:ok, initial_content} <-
           required_metadata_value(metadata, :initial_transition_content),
         :ok <- valid_initial_transition_content(initial_content, states) do
      :ok
    end
  end

  defp required_metadata_value(metadata, field) do
    atom? = Map.has_key?(metadata, field)
    string? = Map.has_key?(metadata, Atom.to_string(field))

    cond do
      atom? and string? ->
        {:error,
         Diagnostic.new(metadata_code(field), "normalized metadata field is duplicated",
           path: [:metadata, field]
         )}

      atom? or string? ->
        {:ok, Diagnostic.fetch(metadata, field)}

      true ->
        {:error,
         Diagnostic.new(metadata_code(field), "normalized metadata field is required",
           path: [:metadata, field]
         )}
    end
  end

  defp valid_root_initial(targets, root_state_ids, states)
       when is_list(targets) and targets != [] do
    by_id = Map.new(states, &{&1.id, &1})

    valid_ids? =
      Enum.all?(targets, fn target ->
        is_binary(target) and Map.has_key?(by_id, target)
      end)

    top_level_ids =
      if valid_ids?,
        do: targets |> Enum.map(&top_level_state(&1, by_id)) |> Enum.uniq(),
        else: []

    if valid_ids? and targets == Enum.uniq(targets) and legal_state_spec?(targets, by_id) and
         length(top_level_ids) == 1 and hd(top_level_ids) in root_state_ids do
      :ok
    else
      invalid_root_initial()
    end
  end

  defp valid_root_initial(_targets, _root_state_ids, _states), do: invalid_root_initial()

  defp invalid_root_initial do
    {:error,
     Diagnostic.new(
       :invalid_root_initial,
       "root initial targets must be one known legal state specification",
       path: [:metadata, :root_initial]
     )}
  end

  defp top_level_state(id, by_id) do
    case Map.get(by_id, id) do
      %{parent: nil} -> id
      %{parent: parent} -> top_level_state(parent, by_id)
      nil -> nil
    end
  end

  defp valid_initial_transition_content(content, states)
       when is_map(content) and not is_struct(content) do
    by_id = Map.new(states, &{&1.id, &1})

    content
    |> Enum.reduce_while(:ok, fn {state_id, commands}, :ok ->
      eligible? =
        case Map.get(by_id, state_id) do
          %State{kind: :compound, initial: [_ | _]} -> true
          _other -> false
        end

      cond do
        not eligible? ->
          {:halt, invalid_initial_transition_content("content key is not an eligible state")}

        not is_list(commands) ->
          {:halt, invalid_initial_transition_content("content value must be an executable list")}

        true ->
          case valid_executable_list(commands, state_id) do
            :ok -> {:cont, :ok}
            {:error, _diagnostic} = error -> {:halt, error}
          end
      end
    end)
  end

  defp valid_initial_transition_content(_content, _states) do
    invalid_initial_transition_content("initial transition content must be a map")
  end

  defp valid_executable_list(commands, state_id) do
    commands
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {command, index}, :ok ->
      case Executable.new(command) do
        {:ok, %Executable{ordinal: ^index}} ->
          {:cont, :ok}

        {:ok, _executable} ->
          {:halt,
           invalid_initial_transition_content(
             "executable ordinals must follow document order",
             [state_id, index]
           )}

        {:error, diagnostic} ->
          {:halt,
           {:error,
            Diagnostic.prefix(
              diagnostic,
              [:metadata, :initial_transition_content, state_id, index]
            )}}
      end
    end)
  end

  defp invalid_initial_transition_content(message, suffix \\ []) do
    {:error,
     Diagnostic.new(:invalid_initial_transition_content, message,
       path: [:metadata, :initial_transition_content | suffix]
     )}
  end

  defp metadata_code(:root_initial), do: :invalid_root_initial
  defp metadata_code(:initial_transition_content), do: :invalid_initial_transition_content

  defp ordered_executables?(commands) do
    commands
    |> Enum.with_index()
    |> Enum.all?(fn {command, index} -> command.ordinal == index end)
  end

  defp legal_history_targets?(%{kind: kind, parent: parent}, targets, by_id)
       when kind in [:history_shallow, :history_deep] do
    targets != [] and is_binary(parent) and
      Enum.all?(targets, fn target ->
        target_state = Map.fetch!(by_id, target)

        target_state.kind not in [:history_shallow, :history_deep] and
          case kind do
            :history_shallow -> target_state.parent == parent
            :history_deep -> parent in state_ancestors(target, by_id)
          end
      end)
  end

  defp legal_history_targets?(_source, _targets, _by_id), do: true

  defp null_action_content("null", states, transitions, metadata) do
    initial_commands =
      case Diagnostic.fetch(metadata, :initial_transition_content, %{}) do
        values when is_map(values) -> values |> Map.values() |> List.flatten()
        _other -> []
      end

    commands =
      Enum.flat_map(states, &(&1.on_entry ++ &1.on_exit)) ++
        Enum.flat_map(transitions, & &1.executable) ++ initial_commands

    case Enum.find(commands, &contains_action?/1) do
      nil ->
        :ok

      command ->
        {:error,
         Diagnostic.new(:null_action_forbidden, "The null data model cannot execute Actions",
           path: [:executable],
           location:
             case Map.get(command, :source) do
               %Source{} = source -> Source.dump(source)
               _other -> nil
             end,
           profile_feature: "jido_action_extension"
         )}
    end
  end

  defp null_action_content(_datamodel, _states, _transitions, _metadata), do: :ok

  defp contains_action?(%{kind: :action}), do: true
  defp contains_action?(%{kind: "action"}), do: true

  defp contains_action?(%{children: children}) when is_list(children),
    do: Enum.any?(children, &contains_action?/1)

  defp contains_action?(%{"kind" => "action"}), do: true

  defp contains_action?(%{"children" => children}) when is_list(children),
    do: Enum.any?(children, &contains_action?/1)

  defp contains_action?(_command), do: false

  defp metadata(value) when is_map(value) and not is_struct(value) do
    with :ok <- Diagnostic.portable(value, [:metadata]), do: {:ok, value}
  end

  defp metadata(_value),
    do:
      {:error,
       Diagnostic.new(:non_portable_value, "chart metadata must be a portable map",
         path: [:metadata]
       )}

  defp source(nil), do: {:ok, nil}
  defp source(value), do: Source.new(value)

  defp safe_kind(kind) do
    kind
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/u, "_")
    |> String.trim("_")
    |> case do
      "" -> "item"
      value -> value
    end
  end

  defp required_stored_fields(value) do
    case Enum.find([:state_index, :transition_index, :fingerprint], fn field ->
           not (Map.has_key?(value, field) or Map.has_key?(value, Atom.to_string(field)))
         end) do
      nil ->
        :ok

      field ->
        {:error,
         Diagnostic.new(:missing_stored_field, "stored chart field is required",
           path: [:chart, field]
         )}
    end
  end

  defp stored_value(value, field, expected) do
    if Diagnostic.fetch(value, field) == expected do
      :ok
    else
      {:error,
       Diagnostic.new(:stored_chart_mismatch, "stored chart derived field does not match",
         path: [:chart, field]
       )}
    end
  end
end
