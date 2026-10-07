defmodule Jido.Statechart.Semantics.Trace do
  @moduledoc "Deterministic bounded semantic trace and replay verification."

  alias Jido.Statechart.{DataModel, Diagnostic}
  alias Jido.Statechart.Model.Chart
  alias Jido.Statechart.Session

  @spec append(map(), map(), keyword()) :: {:ok, map()} | {:error, Diagnostic.t()}
  def append(workspace, entry, options) when is_map(workspace) and is_map(entry) do
    with {:ok, limits} <- DataModel.limits(options) do
      if length(workspace.trace) < limits.trace_entries do
        {:ok, %{workspace | trace: workspace.trace ++ [entry]}}
      else
        {:error,
         Diagnostic.new(:trace_limit_exceeded, "Trace entry limit was reached",
           path: [:trace],
           correction: %{"maximum_entries" => limits.trace_entries}
         )}
      end
    end
  end

  @spec microstep(map()) :: map()
  def microstep(workspace) do
    event = get_in(workspace, [:system, "_event", "name"])

    workspace.last_microstep
    |> Map.put("kind", "microstep")
    |> Map.put("event", event)
    |> Map.put("work_count", workspace.work_count)
  end

  @spec discarded(map()) :: map()
  def discarded(event) do
    %{
      "kind" => "event_discarded",
      "event" => event_name(event),
      "class" => event_class(event)
    }
  end

  @spec terminal(map()) :: map()
  def terminal(workspace) do
    event = get_in(workspace, [:system, "_event", "name"])

    workspace.last_microstep
    |> Map.put("kind", "terminal_exit")
    |> Map.put("event", event)
    |> Map.put("work_count", workspace.work_count)
  end

  @spec replay(Chart.t(), Session.t(), map(), [map()], keyword()) ::
          {:ok, map()} | {:error, Diagnostic.t()}
  def replay(%Chart{} = chart, %Session{} = session, event, expected_trace, options) do
    case Jido.Statechart.Semantics.Macrostep.run(chart, session, event, options) do
      {:ok, %{trace: ^expected_trace} = result} ->
        {:ok, result}

      {:ok, _result} ->
        {:error, Diagnostic.new(:trace_replay_mismatch, "Semantic trace replay did not match")}

      {:error, _diagnostic} = error ->
        error
    end
  end

  defp event_name(%{"name" => name}), do: name
  defp event_name(%{name: name}), do: name
  defp event_name(_event), do: nil

  defp event_class(%{"class" => class}), do: class
  defp event_class(%{class: class}) when is_atom(class), do: Atom.to_string(class)
  defp event_class(%{class: class}), do: class
  defp event_class(_event), do: nil
end
