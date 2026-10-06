defmodule Jido.Statechart do
  @moduledoc """
  Public contracts for the Jido SCXML 1.0 Profile.

  Compiler and execution entry points are added by their owning implementation
  units. This module currently exposes the stable profile and safe inspection
  values that those entry points use.
  """

  alias Jido.Statechart.{Profile, Session}
  alias Jido.Statechart.Model.Chart

  @doc "Returns the machine-readable Jido SCXML capability manifest."
  @spec capabilities() :: map()
  def capabilities, do: Profile.manifest()

  @doc "Returns safe identity and size data for a normalized chart."
  @spec inspect_chart(Chart.t()) :: map()
  def inspect_chart(%Chart{} = chart) do
    %{
      "id" => chart.id,
      "name" => chart.name,
      "fingerprint" => chart.fingerprint,
      "profile_version" => chart.profile_version,
      "datamodel" => chart.datamodel,
      "state_count" => length(chart.states),
      "transition_count" => length(chart.transitions)
    }
  end

  @doc "Returns safe stable state without operation payloads or trace data."
  @spec inspect_session(Session.t()) :: map()
  def inspect_session(%Session{} = session) do
    pending_ids =
      session.operations
      |> Map.values()
      |> Enum.reject(&Session.Operation.terminal?/1)
      |> Enum.map(& &1.id)
      |> Enum.sort()

    %{
      "id" => session.id,
      "incarnation" => session.incarnation,
      "chart_fingerprint" => session.chart_fingerprint,
      "profile_version" => session.profile_version,
      "status" => Atom.to_string(session.status),
      "revision" => session.revision,
      "configuration" => session.configuration,
      "history" => session.history,
      "completed" => session.status in [:completed, :cleaning, :stopped],
      "trace_entries" => length(session.trace),
      "pending_intent_ids" => pending_ids
    }
  end
end
