defmodule Jido.Statechart.Semantics.Selection do
  @moduledoc "Optimal enabled transition selection from W3C SCXML 1.0 section 3.13."

  alias Jido.Statechart.{DataModel, Diagnostic}
  alias Jido.Statechart.Model.{Chart, Event, Transition}
  alias Jido.Statechart.Semantics.{Configuration, Domain}

  @fatal_condition_codes [
    :data_limit_exceeded,
    :expression_limit_exceeded,
    :internal_queue_limit_exceeded
  ]

  @spec select(Chart.t(), [String.t()], Event.t() | map() | nil, map(), keyword()) ::
          {:ok, [Transition.t()], map()} | {:error, Diagnostic.t()}
  def select(%Chart{} = chart, configuration, event, workspace, options)
      when is_map(workspace) and is_list(options) do
    with :ok <- Configuration.validate(chart, configuration),
         {:ok, model} <- DataModel.resolve(chart.datamodel),
         {:ok, limits} <- DataModel.limits(options),
         {:ok, event_name} <- event_name(event),
         workspace <- prepare_workspace(chart, configuration, event, workspace),
         {:ok, candidates, workspace} <-
           candidates(chart, configuration, event_name, workspace, model, options, limits) do
      {:ok, remove_conflicts(chart, candidates, configuration, workspace.history), workspace}
    end
  end

  def select(_chart, _configuration, _event, _workspace, _options) do
    {:error, Diagnostic.new(:invalid_semantic_input, "transition selection input is invalid")}
  end

  @doc "Returns true when one SCXML event descriptor matches an event name."
  @spec event_match?(String.t(), String.t()) :: boolean()
  def event_match?("*", name), do: is_binary(name) and name != ""

  def event_match?(descriptor, name) when is_binary(descriptor) and is_binary(name) do
    prefix =
      if String.ends_with?(descriptor, ".*"),
        do: String.trim_trailing(descriptor, ".*"),
        else: descriptor

    name == prefix or String.starts_with?(name, prefix <> ".")
  end

  def event_match?(_descriptor, _name), do: false

  defp candidates(chart, configuration, event_name, workspace, model, options, limits) do
    transitions = Configuration.transition_map(chart)
    states = Configuration.state_map(chart)

    Enum.reduce_while(configuration, {:ok, {[], MapSet.new(), workspace}}, fn atomic_id,
                                                                              {:ok,
                                                                               {selected, seen,
                                                                                current}} ->
      sources = [atomic_id | Configuration.ancestors(chart, atomic_id)]

      case first_enabled(
             sources,
             states,
             transitions,
             event_name,
             current,
             model,
             options,
             limits
           ) do
        {:ok, nil, next} ->
          {:cont, {:ok, {selected, seen, next}}}

        {:ok, transition, next} ->
          if MapSet.member?(seen, transition.id) do
            {:cont, {:ok, {selected, seen, next}}}
          else
            {:cont, {:ok, {selected ++ [transition], MapSet.put(seen, transition.id), next}}}
          end

        {:error, _diagnostic} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, {selected, _seen, next}} -> {:ok, selected, next}
      {:error, _diagnostic} = error -> error
    end
  end

  defp first_enabled([], _states, _transitions, _event, workspace, _model, _options, _limits),
    do: {:ok, nil, workspace}

  defp first_enabled(
         [source_id | rest],
         states,
         transitions,
         event,
         workspace,
         model,
         options,
         limits
       ) do
    state = Map.fetch!(states, source_id)

    case enabled_in_state(
           state.transition_ids,
           transitions,
           event,
           workspace,
           model,
           options,
           limits
         ) do
      {:ok, nil, next} ->
        first_enabled(rest, states, transitions, event, next, model, options, limits)

      result ->
        result
    end
  end

  defp enabled_in_state(ids, transitions, event, workspace, model, options, limits) do
    Enum.reduce_while(ids, {:ok, nil, workspace}, fn id, {:ok, nil, current} ->
      transition = Map.fetch!(transitions, id)

      if trigger_match?(transition, event) do
        case condition_match(transition, current, model, options, limits) do
          {:ok, true, next} -> {:halt, {:ok, transition, next}}
          {:ok, false, next} -> {:cont, {:ok, nil, next}}
          {:error, _diagnostic} = error -> {:halt, error}
        end
      else
        {:cont, {:ok, nil, current}}
      end
    end)
  end

  defp trigger_match?(%Transition{events: []}, nil), do: true
  defp trigger_match?(%Transition{events: []}, _event), do: false
  defp trigger_match?(_transition, nil), do: false

  defp trigger_match?(transition, event),
    do: Enum.any?(transition.events, &event_match?(&1, event))

  defp condition_match(%Transition{condition: nil}, workspace, _model, _options, _limits),
    do: {:ok, true, workspace}

  defp condition_match(transition, workspace, model, options, limits) do
    environment = %{
      data: workspace.data,
      system: workspace.system,
      bindings: workspace.bindings,
      active_state_ids: workspace.active_state_ids
    }

    case model.condition(transition.condition, environment, options) do
      {:ok, value} ->
        {:ok, value, workspace}

      {:error, %Diagnostic{code: code} = diagnostic} when code in @fatal_condition_codes ->
        {:error, diagnostic}

      {:error, diagnostic} ->
        execution_error(workspace, diagnostic, limits)
    end
  end

  defp execution_error(workspace, diagnostic, limits) do
    event = %{
      "name" => "error.execution",
      "class" => "platform",
      "data" => %{"code" => Atom.to_string(diagnostic.code), "message" => diagnostic.message},
      "message_id" => nil,
      "send_id" => nil,
      "origin" => nil,
      "origin_type" => nil,
      "invoke_id" => nil,
      "turn_id" => nil,
      "session_id" => workspace.system["_sessionid"]
    }

    if length(workspace.internal_queue) < limits.internal_queue_events do
      {:ok, false, %{workspace | internal_queue: workspace.internal_queue ++ [event]}}
    else
      {:error,
       Diagnostic.new(:internal_queue_limit_exceeded, "Internal event queue limit was reached")}
    end
  end

  defp remove_conflicts(chart, candidates, configuration, history) do
    Enum.reduce(candidates, [], fn transition, filtered ->
      exit = MapSet.new(Domain.exit_set(chart, [transition], configuration, history))

      {preempted?, removals} =
        Enum.reduce_while(filtered, {false, []}, fn existing, {_preempted, removals} ->
          existing_exit = MapSet.new(Domain.exit_set(chart, [existing], configuration, history))

          if MapSet.disjoint?(exit, existing_exit) do
            {:cont, {false, removals}}
          else
            if Configuration.descendant?(chart, transition.source_id, existing.source_id) do
              {:cont, {false, [existing.id | removals]}}
            else
              {:halt, {true, removals}}
            end
          end
        end)

      if preempted? do
        filtered
      else
        Enum.reject(filtered, &(&1.id in removals)) ++ [transition]
      end
    end)
  end

  defp event_name(nil), do: {:ok, nil}
  defp event_name(%Event{name: name}), do: {:ok, name}
  defp event_name(%{name: name}) when is_binary(name), do: {:ok, name}
  defp event_name(%{"name" => name}) when is_binary(name), do: {:ok, name}

  defp event_name(_event),
    do: {:error, Diagnostic.new(:invalid_event, "semantic event is invalid")}

  defp prepare_workspace(chart, configuration, event, workspace) do
    prepared =
      Map.merge(
        %{
          data: %{},
          system: %{},
          bindings: %{},
          active_state_ids: [],
          internal_queue: [],
          history: %{}
        },
        workspace
      )
      |> Map.put(:active_state_ids, Configuration.active_state_ids(chart, configuration))

    if is_nil(event) do
      prepared
    else
      Map.update!(prepared, :system, &Map.put(&1, "_event", event_value(event)))
    end
  end

  defp event_value(%Event{} = event), do: Event.dump(event)
  defp event_value(event) when is_map(event), do: stringify_event(event)

  defp stringify_event(event) do
    Map.new(event, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end
end
