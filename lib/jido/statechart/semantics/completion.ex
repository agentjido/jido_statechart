defmodule Jido.Statechart.Semantics.Completion do
  @moduledoc "Final-state completion events and top-level completion data."

  alias Jido.Statechart.{DataModel, Diagnostic}
  alias Jido.Statechart.Model.{Chart, State}
  alias Jido.Statechart.Semantics.Configuration

  @fatal_codes [:data_limit_exceeded, :expression_limit_exceeded, :internal_queue_limit_exceeded]

  @spec entered_final(Chart.t(), State.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Diagnostic.t()}
  def entered_final(%Chart{} = chart, %State{kind: :final} = state, workspace, options) do
    if is_nil(state.parent) do
      with {:ok, data, workspace} <- done_data(chart, state, workspace, options) do
        {:ok, %{workspace | status: :completed, completion_data: data}}
      end
    else
      parent = fetch_state(chart, state.parent)

      with {:ok, data, workspace} <- done_data(chart, state, workspace, options),
           {:ok, workspace} <- enqueue(workspace, "done.state." <> parent.id, data, options),
           {:ok, workspace} <- parallel_completion(chart, state, workspace, options) do
        {:ok, workspace}
      end
    end
  end

  def entered_final(_chart, _state, workspace, _options), do: {:ok, workspace}

  @spec in_final?(Chart.t(), String.t(), [String.t()]) :: boolean()
  def in_final?(%Chart{} = chart, state_id, active_state_ids) do
    state = fetch_state(chart, state_id)
    active = MapSet.new(active_state_ids)

    case state.kind do
      :compound ->
        Enum.any?(state.children, fn child_id ->
          child = fetch_state(chart, child_id)
          child.kind == :final and MapSet.member?(active, child_id)
        end)

      :parallel ->
        state
        |> Configuration.real_children(Configuration.state_map(chart))
        |> Enum.all?(&in_final?(chart, &1, active_state_ids))

      _other ->
        false
    end
  end

  defp parallel_completion(chart, state, workspace, options) do
    chart
    |> Configuration.ancestors(state.id)
    |> Enum.map(&fetch_state(chart, &1))
    |> Enum.filter(&(&1.kind == :parallel))
    |> Enum.reduce_while({:ok, workspace}, fn parallel, {:ok, current} ->
      event = "done.state." <> parallel.id

      cond do
        not in_final?(chart, parallel.id, current.active_state_ids) ->
          {:cont, {:ok, current}}

        Enum.any?(current.internal_queue, &(event_name(&1) == event)) ->
          {:cont, {:ok, current}}

        true ->
          case enqueue(current, event, nil, options) do
            {:ok, next} -> {:cont, {:ok, next}}
            {:error, _diagnostic} = error -> {:halt, error}
          end
      end
    end)
  end

  defp done_data(_chart, %State{done_data: nil}, workspace, _options),
    do: {:ok, nil, workspace}

  defp done_data(chart, state, workspace, options) do
    with {:ok, model} <- DataModel.resolve(chart.datamodel) do
      environment = %{
        data: workspace.data,
        system: workspace.system,
        bindings: workspace.bindings,
        active_state_ids: workspace.active_state_ids
      }

      case model.construct(state.done_data, environment, options) do
        {:ok, value} ->
          {:ok, value, workspace}

        {:error, %Diagnostic{code: code} = diagnostic} when code in @fatal_codes ->
          {:error, diagnostic}

        {:error, diagnostic} ->
          with {:ok, workspace} <- execution_error(workspace, diagnostic, options) do
            {:ok, nil, workspace}
          end
      end
    end
  end

  defp execution_error(workspace, diagnostic, options) do
    data = %{"code" => Atom.to_string(diagnostic.code), "message" => diagnostic.message}
    enqueue(workspace, "error.execution", data, options, "platform")
  end

  defp enqueue(workspace, name, data, options, event_class \\ "internal") do
    with {:ok, limits} <- DataModel.limits(options) do
      if length(workspace.internal_queue) < limits.internal_queue_events do
        event = %{
          "name" => name,
          "class" => event_class,
          "data" => data,
          "message_id" => nil,
          "send_id" => nil,
          "origin" => nil,
          "origin_type" => nil,
          "invoke_id" => nil,
          "turn_id" => nil,
          "session_id" => workspace.system["_sessionid"]
        }

        {:ok, %{workspace | internal_queue: workspace.internal_queue ++ [event]}}
      else
        {:error,
         Diagnostic.new(:internal_queue_limit_exceeded, "Internal event queue limit was reached")}
      end
    end
  end

  defp fetch_state(chart, id), do: Map.fetch!(Configuration.state_map(chart), id)

  defp event_name(%{"name" => name}), do: name
  defp event_name(%{name: name}), do: name
  defp event_name(_event), do: nil
end
