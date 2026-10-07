defmodule Jido.Statechart do
  @moduledoc """
  Public contracts for the Jido SCXML 1.0 Profile.

  Compiler and execution entry points are added by their owning implementation
  units. This module currently exposes the stable profile and safe inspection
  values that those entry points use.
  """

  alias Jido.Statechart.{Diagnostic, Flow, Profile, Registry, Session}
  alias Jido.Statechart.Model.Chart

  @doc "Returns the machine-readable Jido SCXML capability manifest."
  @spec capabilities() :: map()
  def capabilities, do: Profile.manifest()

  @doc "Initializes one new session through the canonical Statechart Flow."
  @spec initialize(Chart.t(), Session.t(), Registry.t() | keyword()) :: Jido.Exec.exec_result()
  def initialize(%Chart{} = chart, %Session{} = session, %Registry{} = registry),
    do: Flow.initialize(chart, session, registry)

  def initialize(%Chart{} = chart, %Session{} = session, options) do
    with :ok <- validate_root_options(options),
         %Registry{} = registry <- Keyword.get(options, :registry) do
      Flow.initialize(chart, session, registry, Keyword.delete(options, :registry))
    else
      {:error, _diagnostic} = error -> error
      _other -> {:error, Diagnostic.new(:invalid_registry, "A trusted Registry is required")}
    end
  end

  @doc "Runs one external event through the canonical Statechart Flow."
  @spec step(Chart.t(), Session.t(), map(), Registry.t() | keyword()) :: Jido.Exec.exec_result()
  def step(%Chart{} = chart, %Session{} = session, event, %Registry{} = registry),
    do: Flow.step(chart, session, event, registry)

  def step(%Chart{} = chart, %Session{} = session, event, options) do
    with :ok <- validate_root_options(options),
         %Registry{} = registry <- Keyword.get(options, :registry) do
      Flow.step(chart, session, event, registry, Keyword.delete(options, :registry))
    else
      {:error, _diagnostic} = error -> error
      _other -> {:error, Diagnostic.new(:invalid_registry, "A trusted Registry is required")}
    end
  end

  @doc "Alias for `step/4`."
  @spec run(Chart.t(), Session.t(), map(), Registry.t() | keyword()) :: Jido.Exec.exec_result()
  def run(%Chart{} = chart, %Session{} = session, event, registry_or_options),
    do: step(chart, session, event, registry_or_options)

  defp validate_root_options(options),
    do: Flow.validate_options(options, [:registry | Flow.runtime_option_keys()])

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
      "generated_id_counter" => session.generated_id_counter,
      "operation_counter" => session.operation_counter,
      "configuration" => session.configuration,
      "history" => session.history,
      "completed" => session.status in [:completed, :cleaning, :stopped],
      "trace_entries" => length(session.trace),
      "pending_intent_ids" => pending_ids
    }
  end
end
