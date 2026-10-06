defmodule Jido.Statechart.Compiler do
  @moduledoc "Compiles bounded data into the same normalized model used by the Agent DSL."
  alias Jido.Statechart.{Data, Definition, Error, Limits, State, Transition}

  @doc "Compiles a plain map. Known input keys can be strings or fixed atoms."
  @spec compile(term()) :: {:ok, Definition.t()} | {:error, Error.t()}
  def compile(input) do
    {:ok, build(input)}
  catch
    {:statechart_error, error} -> {:error, error}
  end

  @doc "Compiles a definition or raises a typed error."
  @spec compile!(term()) :: Definition.t() | no_return()
  def compile!(input) do
    case compile(input) do
      {:ok, definition} -> definition
      {:error, error} -> raise error
    end
  end

  @doc "Exports normalized authoring data. This is not a runtime checkpoint."
  @spec to_data(Definition.t()) :: map()
  def to_data(%Definition{} = definition) do
    %{
      id: definition.id,
      version: definition.version,
      initial: definition.initial,
      limits: definition.limits,
      states:
        definition.states
        |> Map.values()
        |> Enum.sort_by(& &1.id)
        |> Enum.map(fn state ->
          %{
            id: state.id,
            parent: state.parent,
            type: state.type,
            initial: state.initial,
            entry: state.entry,
            exit: state.exit,
            transitions:
              state.transitions
              |> Enum.sort_by(& &1.order)
              |> Enum.map(fn t ->
                Map.drop(Map.from_struct(t), [:source, :order])
              end)
          }
        end)
    }
  end

  defp build(input) do
    map!(input, [:id, :version, :initial, :states, :limits], [])
    limits = unwrap!(Limits.new(get(input, :limits, %{})))
    unwrap_ok!(Data.validate(input, limits))

    ensure!(
      byte_size(:erlang.term_to_binary(input)) <= limits.definition_bytes,
      :limit_exceeded,
      "Definition byte limit exceeded",
      []
    )

    id = identity!(get(input, :id), limits, [:id])
    version = identity!(get(input, :version, "1"), limits, [:version])
    initial = identity!(get(input, :initial), limits, [:initial])
    raw_states = list!(get(input, :states), limits.states, [:states])
    ensure!(raw_states != [], :invalid_definition, "A chart must contain states", [:states])

    states =
      raw_states
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {raw, index}, acc ->
        state = state!(raw, limits, [:states, index])
        ensure!(!Map.has_key?(acc, state.id), :duplicate_state, "Duplicate state ID", [state.id])
        Map.put(acc, state.id, state)
      end)

    validate_tree!(states, initial, limits)

    ensure!(
      Enum.reduce(states, 0, fn {_, s}, n -> n + length(s.transitions) end) <= limits.transitions,
      :limit_exceeded,
      "Transition count limit exceeded",
      [:transitions]
    )

    normalized = %Definition{
      id: id,
      version: version,
      initial: initial,
      states: states,
      limits: limits,
      fingerprint: ""
    }

    normalized_data = to_data(normalized)
    unwrap_ok!(Data.validate(normalized_data, limits))

    ensure!(
      byte_size(:erlang.term_to_binary(normalized_data)) <= limits.definition_bytes,
      :limit_exceeded,
      "Normalized definition byte limit exceeded",
      []
    )

    fingerprint =
      normalized_data
      |> canonical()
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    %{normalized | fingerprint: fingerprint}
  end

  defp state!(raw, limits, path) do
    map!(raw, [:id, :parent, :type, :initial, :entry, :exit, :transitions], path)
    id = identity!(get(raw, :id), limits, path ++ [:id])
    type = enum!(get(raw, :type, :atomic), [:atomic, :compound, :final], path ++ [:type])
    parent = optional_id!(get(raw, :parent), limits, path ++ [:parent])
    initial = optional_id!(get(raw, :initial), limits, path ++ [:initial])

    transitions =
      raw
      |> get(:transitions, [])
      |> list!(limits.transitions, path ++ [:transitions])
      |> Enum.with_index()
      |> Enum.map(fn {t, i} -> transition!(t, id, i, limits, path ++ [:transitions, i]) end)
      |> Enum.sort_by(&{-&1.priority, &1.order})

    %State{
      id: id,
      parent: parent,
      type: type,
      initial: initial,
      entry: actions!(get(raw, :entry, []), limits, path ++ [:entry]),
      exit: actions!(get(raw, :exit, []), limits, path ++ [:exit]),
      transitions: transitions
    }
  end

  defp transition!(raw, source, order, limits, path) do
    map!(raw, [:event, :target, :guard, :actions, :priority, :kind], path)
    priority = get(raw, :priority, 0)

    ensure!(
      is_integer(priority) and priority >= -1_000_000 and priority <= 1_000_000,
      :invalid_definition,
      "Priority must be a bounded integer",
      path ++ [:priority]
    )

    %Transition{
      source: source,
      order: order,
      priority: priority,
      event: optional_id!(get(raw, :event), limits, path ++ [:event]),
      target: optional_id!(get(raw, :target), limits, path ++ [:target]),
      guard: optional_id!(get(raw, :guard), limits, path ++ [:guard]),
      actions: actions!(get(raw, :actions, []), limits, path ++ [:actions]),
      kind: enum!(get(raw, :kind, :external), [:external, :internal], path ++ [:kind])
    }
  end

  defp actions!(raw, limits, path) do
    raw
    |> list!(limits.actions_per_list, path)
    |> Enum.with_index()
    |> Enum.map(fn {action, i} ->
      action!(action, limits, path ++ [i])
    end)
  end

  defp action!(id, limits, path) when is_binary(id),
    do: %{id: identity!(id, limits, path), params: %{}}

  defp action!(raw, limits, path) do
    map!(raw, [:id, :params, :raise, :effect, :data], path)
    selectors = Enum.filter([:id, :raise, :effect], &has?(raw, &1))

    ensure!(
      length(selectors) == 1,
      :invalid_definition,
      "Action requires exactly one ID, raise, or effect",
      path
    )

    case selectors do
      [:id] ->
        map!(raw, [:id, :params], path)

        %{
          id: identity!(get(raw, :id), limits, path),
          params: plain_data!(get(raw, :params, %{}), path)
        }

      [:raise] ->
        map!(raw, [:raise, :data], path)
        id = identity!(get(raw, :raise), limits, path)

        ensure!(
          !String.starts_with?(id, ["done.state.", "$"]),
          :invalid_definition,
          "Raised events cannot use reserved identities",
          path
        )

        %{raise: id, data: plain_data!(get(raw, :data, %{}), path)}

      [:effect] ->
        map!(raw, [:effect, :data], path)

        %{
          effect: identity!(get(raw, :effect), limits, path),
          data: plain_data!(get(raw, :data, %{}), path)
        }
    end
  end

  defp validate_tree!(states, initial, limits) do
    ensure!(
      Map.has_key?(states, initial) and states[initial].parent == nil,
      :invalid_initial,
      "Chart initial must name a top-level state",
      [:initial]
    )

    Enum.each(states, fn {id, state} ->
      path = ancestry!(states, id, [], limits.depth)

      ensure!(
        length(path) <= limits.active_states,
        :limit_exceeded,
        "Active state limit exceeded",
        [id]
      )

      children = Enum.filter(states, fn {_, child} -> child.parent == id end)

      if state.type == :compound do
        ensure!(
          byte_size("done.state." <> id) <= limits.expression_bytes,
          :limit_exceeded,
          "Compound completion event identity exceeds its byte limit",
          [id]
        )

        ensure!(
          state.initial != nil and Map.has_key?(states, state.initial) and
            states[state.initial].parent == id,
          :invalid_initial,
          "Compound initial must name an immediate child",
          [id, :initial]
        )
      else
        ensure!(
          children == [] and state.initial == nil,
          :invalid_definition,
          "Atomic and final states cannot have children or initial states",
          [id]
        )
      end

      ensure!(
        state.type != :final or state.transitions == [],
        :invalid_definition,
        "Final states cannot have transitions",
        [id, :transitions]
      )

      Enum.each(state.transitions, fn t ->
        ensure!(
          t.target == nil or Map.has_key?(states, t.target),
          :unknown_target,
          "Unknown transition target",
          [id, t.order]
        )

        if t.kind == :internal and t.target != nil do
          ensure!(
            state.type == :compound and t.target != id and
              id in ancestry!(states, t.target, [], limits.depth),
            :invalid_definition,
            "Internal targeted transition requires a compound source and descendant target",
            [id, t.order]
          )
        end
      end)
    end)
  end

  defp ancestry!(_states, nil, visited, _limit), do: visited

  defp ancestry!(states, id, visited, limit) do
    ensure!(length(visited) < limit, :limit_exceeded, "State depth limit exceeded", [id])
    ensure!(id not in visited, :state_cycle, "State hierarchy has a cycle", [id])
    ensure!(Map.has_key?(states, id), :unknown_parent, "Unknown parent state", [id])
    ancestry!(states, states[id].parent, [id | visited], limit)
  end

  defp plain_data!(value, path) do
    ensure!(
      is_map(value) and not is_struct(value),
      :invalid_definition,
      "Action data must be a plain map",
      path
    )

    value
  end

  defp identity!(value, limits, path) do
    ensure!(
      is_binary(value) and byte_size(value) in 1..limits.expression_bytes and String.valid?(value),
      :invalid_identity,
      "Identity must be a non-empty bounded UTF-8 string",
      path
    )

    value
  end

  defp optional_id!(nil, _, _), do: nil
  defp optional_id!(id, limits, path), do: identity!(id, limits, path)

  defp enum!(value, options, path) do
    case Enum.find(options, &(value == &1 or value == Atom.to_string(&1))) do
      nil -> fail!(:unsupported_feature, "Unsupported state or transition kind", path)
      result -> result
    end
  end

  defp list!(list, limit, path) do
    ensure!(
      is_list(list) and proper_bounded?(list, limit),
      :limit_exceeded,
      "Expected a bounded proper list",
      path
    )

    list
  end

  defp proper_bounded?([], _), do: true
  defp proper_bounded?([_ | rest], n) when n > 0, do: proper_bounded?(rest, n - 1)
  defp proper_bounded?(_, _), do: false

  defp map!(input, fields, path) do
    ensure!(
      is_map(input) and not is_struct(input),
      :invalid_definition,
      "Expected a plain definition map",
      path
    )

    ensure!(
      map_size(input) <= length(fields) * 2,
      :unknown_field,
      "Too many definition fields",
      path
    )

    allowed = fields ++ Enum.map(fields, &Atom.to_string/1)

    ensure!(
      Enum.all?(Map.keys(input), &(&1 in allowed)),
      :unknown_field,
      "Unknown definition field",
      path
    )

    ensure!(
      Enum.all?(
        fields,
        &(not (Map.has_key?(input, &1) and Map.has_key?(input, Atom.to_string(&1))))
      ),
      :duplicate_field,
      "Duplicate field aliases",
      path
    )
  end

  defp has?(input, field),
    do: Map.has_key?(input, field) or Map.has_key?(input, Atom.to_string(field))

  defp get(input, field, default \\ nil),
    do: Map.get(input, field, Map.get(input, Atom.to_string(field), default))

  defp ensure!(true, _, _, _), do: :ok
  defp ensure!(_, code, message, path), do: fail!(code, message, path)

  defp fail!(code, message, path),
    do: throw({:statechart_error, %Error{code: code, message: message, path: path}})

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, error}), do: throw({:statechart_error, error})
  defp unwrap_ok!(:ok), do: :ok
  defp unwrap_ok!({:error, error}), do: throw({:statechart_error, error})

  defp canonical(map) when is_map(map),
    do: map |> Enum.sort() |> Enum.map(fn {k, v} -> {k, canonical(v)} end)

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value), do: value
end
