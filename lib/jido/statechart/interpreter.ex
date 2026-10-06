defmodule Jido.Statechart.Interpreter do
  @moduledoc """
  Pure run-to-completion interpreter. A failed macrostep returns only an error.
  Entry, exit, guard, reducer, queue, and selection work use fixed budgets.
  Eventless transitions run before the next queued internal event.
  """
  alias Jido.Statechart.{
    Configuration,
    Data,
    Definition,
    Effect,
    Error,
    Event,
    Instance,
    Registry,
    Result,
    Validator
  }

  @doc "Runs initial entry actions and settles the chart."
  @spec init(Definition.t(), map(), Registry.t()) :: {:ok, Result.t()} | {:error, Error.t()}
  def init(definition, data \\ %{}, registry \\ %Registry{})

  def init(%Definition{} = definition, data, registry),
    do: execute(definition, new_instance(definition, data), registry, nil)

  def init(_, _, _), do: Error.result(:invalid_definition, "Expected a compiled Definition")

  @doc "Applies one external event. A new instance initializes in the same bounded macrostep."
  @spec step(Definition.t(), Instance.t(), Event.t(), Registry.t()) ::
          {:ok, Result.t()} | {:error, Error.t()}
  def step(definition, instance, event, registry \\ %Registry{})

  def step(definition, instance, %Event{kind: :external} = event, registry),
    do: execute(definition, instance, registry, event)

  def step(_, _, _, _), do: Error.result(:invalid_event, "Step requires one external Event")

  @doc "Creates an uninitialized value without calling application behavior."
  @spec new_instance(Definition.t(), map()) :: Instance.t()
  def new_instance(%Definition{} = definition, data),
    do: %Instance{
      configuration: %Configuration{fingerprint: definition.fingerprint, active: [], status: :new},
      data: data
    }

  defp execute(definition, instance, registry, event) do
    with :ok <- Validator.definition(definition),
         :ok <- Validator.instance(definition, instance),
         :ok <- Registry.validate(definition, registry),
         :ok <- external_event(event, definition.limits) do
      w = %{
        definition: definition,
        registry: registry,
        active: instance.configuration.active,
        data: instance.data,
        queue: :queue.new(),
        effects: [],
        trace: [],
        stats: %{
          work: 0,
          transitions: 0,
          action_calls: 0,
          guard_calls: 0,
          internal_events: 0,
          effects: 0
        }
      }

      initial_event = %Event{type: "$init", kind: :internal}

      w =
        if instance.configuration.status == :new,
          do:
            w
            |> enter(path(definition, definition.initial), initial_event)
            |> settle(initial_event),
          else: w

      w = if event == nil, do: w, else: process_external(w, event)
      finish(w)
    end
  catch
    {:statechart_error, error} -> {:error, error}
  end

  defp external_event(nil, _), do: :ok

  defp external_event(%Event{kind: :external} = event, limits) do
    case Event.validate(event, limits) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp external_event(_, _), do: Error.result(:invalid_event, "Step requires one external Event")

  defp process_external(w, event) do
    ensure!(
      Validator.status(w.definition, w.active) != :done,
      :chart_done,
      "Chart is already final"
    )

    {transition, w} = select(w, event.type, event)

    ensure!(
      transition != nil,
      :unhandled_event,
      "No enabled transition for the external event",
      %{event: event.type}
    )

    w |> apply_transition(transition, event) |> settle(event)
  end

  defp settle(w, event) do
    {transition, w} = select(w, nil, event)

    cond do
      transition != nil ->
        w |> apply_transition(transition, event) |> settle(event)

      :queue.is_empty(w.queue) ->
        w

      true ->
        {{:value, internal}, queue} = :queue.out(w.queue)
        w = %{tick(w) | queue: queue} |> trace(%{op: :event, event: internal.type})
        {transition, w} = select(w, internal.type, internal)

        w =
          if transition,
            do: apply_transition(w, transition, internal),
            else: trace(w, %{op: :unhandled_internal, event: internal.type})

        settle(w, internal)
    end
  end

  defp select(w, type, event) do
    Enum.reduce_while(Enum.reverse(w.active), {nil, w}, fn id, {nil, w} ->
      w = tick(w)

      {transition, w} =
        Enum.reduce_while(w.definition.states[id].transitions, {nil, w}, fn t, {nil, w} ->
          w = tick(w)

          {matches, w} = event_matches(w, t, type)

          if matches do
            {enabled, w} = guard(w, t.guard, event)
            if enabled, do: {:halt, {t, w}}, else: {:cont, {nil, w}}
          else
            {:cont, {nil, w}}
          end
        end)

      if transition, do: {:halt, {transition, w}}, else: {:cont, {nil, w}}
    end)
  end

  defp event_matches(w, %{event_mode: :exact, event: expected}, type),
    do: {expected == type, w}

  defp event_matches(w, %{event: expected}, nil), do: {expected == nil, w}
  defp event_matches(w, %{event: nil}, _type), do: {false, w}

  defp event_matches(w, transition, type) do
    Enum.reduce_while(transition.event_descriptors, {false, w}, fn descriptor, {false, w} ->
      w = tick(w)

      if Jido.Statechart.EventDescriptor.matches?(descriptor, type),
        do: {:halt, {true, w}},
        else: {:cont, {false, w}}
    end)
  end

  defp guard(w, nil, _), do: {true, w}

  defp guard(w, id, event) do
    w = count(w, :guard_calls, w.definition.limits.macrostep)
    result = invoke(fn -> w.registry.guards[id].(w.data, event) end, id)
    ensure!(is_boolean(result), :invalid_guard_result, "Guard must return a boolean", %{id: id})
    {result, trace(w, %{op: :guard, id: id, enabled: result})}
  end

  defp apply_transition(w, t, event) do
    w =
      count(w, :transitions, w.definition.limits.transitions)
      |> trace(%{
        op: :transition,
        source: t.source,
        target: t.target,
        event: t.event,
        order: t.order
      })

    if t.target == nil do
      actions(w, t.actions, event)
    else
      source = path(w.definition, t.source)
      target = path(w.definition, t.target)
      common = common_prefix(source, target)

      domain =
        cond do
          t.kind == :internal -> source
          common == source or common == target -> Enum.drop(common, -1)
          true -> common
        end

      exits = w.active |> Enum.drop(length(domain)) |> Enum.reverse()

      w =
        Enum.reduce(exits, w, fn id, w ->
          w = tick(w) |> trace(%{op: :exit, state: id})
          w = actions(w, w.definition.states[id].exit, event)
          %{w | active: Enum.drop(w.active, -1)}
        end)

      w |> actions(t.actions, event) |> enter(Enum.drop(target, length(domain)), event)
    end
  end

  defp enter(w, [], _event), do: w

  defp enter(w, [id | rest], event) do
    w = tick(w) |> trace(%{op: :entry, state: id})

    ensure!(
      length(w.active) < w.definition.limits.active_states,
      :limit_exceeded,
      "Active state limit exceeded"
    )

    w = %{w | active: w.active ++ [id]}
    state = w.definition.states[id]
    w = actions(w, state.entry, event)

    cond do
      rest != [] ->
        enter(w, rest, event)

      state.type == :compound ->
        enter(w, [state.initial], event)

      state.type == :final and state.parent != nil ->
        enqueue(w, %Event{type: "done.state." <> state.parent, kind: :internal})

      true ->
        w
    end
  end

  defp actions(w, actions, event), do: Enum.reduce(actions, w, &action(&2, &1, event))

  defp action(w, action, event) do
    w = count(w, :action_calls, w.definition.limits.action_calls)

    case action do
      %{raise: id, data: data} ->
        enqueue(w, %Event{type: id, data: data, kind: :internal})

      %{effect: id, data: data} ->
        effect(w, %Effect{id: id, data: data})

      %{id: id, params: params} ->
        w = trace(w, %{op: :action, id: id})
        result = invoke(fn -> w.registry.reducers[id].(w.data, event, params) end, id)

        case result do
          {:ok, data} ->
            reducer_result(w, data, [])

          {:ok, data, requests} ->
            reducer_result(w, data, requests)

          {:error, _} ->
            fail!(:reducer_failed, "Reducer returned an error", %{id: id})

          _ ->
            fail!(
              :invalid_reducer_result,
              "Reducer must return data and an optional request list",
              %{id: id}
            )
        end
    end
  end

  defp reducer_result(w, data, requests) do
    ensure!(
      is_map(data) and not is_struct(data),
      :invalid_reducer_result,
      "Reducer data must be a plain map"
    )

    unwrap_ok!(Data.validate(data, w.definition.limits))

    ensure!(
      bounded_requests?(
        requests,
        w.definition.limits.action_calls + w.definition.limits.internal_events
      ),
      :limit_exceeded,
      "Reducer request list limit exceeded"
    )

    Enum.reduce(requests, %{w | data: data}, fn
      %Event{kind: :internal} = event, w -> enqueue(w, event)
      %Effect{} = effect, w -> effect(w, effect)
      _, _ -> fail!(:invalid_request, "Reducer requests must be internal Events or Effects")
    end)
  end

  defp enqueue(w, event) do
    unwrap!(Event.validate(event, w.definition.limits))
    w = count(w, :internal_events, w.definition.limits.internal_events)
    %{w | queue: :queue.in(event, w.queue)} |> trace(%{op: :raise, event: event.type})
  end

  defp effect(w, %Effect{id: id, data: data} = effect) do
    ensure!(
      is_binary(id) and byte_size(id) in 1..w.definition.limits.expression_bytes and
        String.valid?(id) and
        is_map(data) and not is_struct(data),
      :invalid_request,
      "Effect requires a bounded string ID and plain data map"
    )

    unwrap_ok!(Data.validate(data, w.definition.limits))
    w = count(w, :effects, w.definition.limits.action_calls)
    %{w | effects: [effect | w.effects]} |> trace(%{op: :effect, id: id})
  end

  defp finish(w) do
    config = %Configuration{
      fingerprint: w.definition.fingerprint,
      active: w.active,
      status: Validator.status(w.definition, w.active)
    }

    {:ok,
     %Result{
       instance: %Instance{configuration: config, data: w.data},
       effects: Enum.reverse(w.effects),
       trace: Enum.reverse(w.trace),
       stats: w.stats
     }}
  end

  defp path(definition, id), do: path(definition, id, [])
  defp path(_, nil, acc), do: acc
  defp path(definition, id, acc), do: path(definition, definition.states[id].parent, [id | acc])
  defp common_prefix([a | left], [a | right]), do: [a | common_prefix(left, right)]
  defp common_prefix(_, _), do: []

  defp count(w, key, limit) do
    ensure!(w.stats[key] < limit, :limit_exceeded, "Macrostep execution limit exceeded", %{
      limit: key
    })

    w = tick(w)
    %{w | stats: Map.update!(w.stats, key, &(&1 + 1))}
  end

  defp tick(w) do
    ensure!(
      w.stats.work < w.definition.limits.macrostep,
      :limit_exceeded,
      "Macrostep work limit exceeded",
      %{limit: :macrostep}
    )

    %{w | stats: Map.update!(w.stats, :work, &(&1 + 1))}
  end

  defp trace(w, item), do: %{w | trace: [item | w.trace]}
  defp bounded_requests?([], _), do: true
  defp bounded_requests?([_ | rest], n) when n > 0, do: bounded_requests?(rest, n - 1)
  defp bounded_requests?(_, _), do: false

  defp invoke(fun, id) do
    fun.()
  rescue
    _ -> fail!(:callback_failed, "Application callback raised", %{id: id})
  catch
    _, _ -> fail!(:callback_failed, "Application callback did not return", %{id: id})
  end

  defp ensure!(true, _, _, _), do: :ok
  defp ensure!(_, code, message, details), do: fail!(code, message, details)
  defp ensure!(condition, code, message), do: ensure!(condition, code, message, %{})

  defp fail!(code, message, details \\ %{}),
    do: throw({:statechart_error, %Error{code: code, message: message, details: details}})

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, error}), do: throw({:statechart_error, error})
  defp unwrap_ok!(:ok), do: :ok
  defp unwrap_ok!({:error, error}), do: throw({:statechart_error, error})
end
