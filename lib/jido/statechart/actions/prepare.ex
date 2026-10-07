defmodule Jido.Statechart.Actions.Prepare do
  @moduledoc "Validates macrostep input and creates the plain Iterate workspace."

  use Jido.Action, name: "statechart_prepare"

  alias Jido.Statechart.{Diagnostic, Limits, Registry, Session}
  alias Jido.Statechart.Model.{Chart, Event}
  alias Jido.Statechart.Semantics.Macrostep

  @fields [:operation, :chart, :session, :event, :registry, :limits, :now]
  @protected_context [:chart, "chart", :registry, "registry", :statechart, "statechart"]

  @impl true
  def run(params, context) do
    with :ok <- validate_context(context),
         :ok <- Diagnostic.validate_fields(params, @fields, [:flow, :input]),
         %Chart{} = chart <- Diagnostic.fetch(params, :chart),
         %Session{} = session <- Diagnostic.fetch(params, :session),
         %Registry{} = registry <- Diagnostic.fetch(params, :registry),
         %Limits{} = limits <- Diagnostic.fetch(params, :limits, Limits.default()),
         event = Diagnostic.fetch(params, :event),
         {:ok, operation} <- operation(Diagnostic.fetch(params, :operation), session, event),
         {:ok, now} <- runtime_now(Diagnostic.fetch(params, :now)),
         options = execution_options(registry, limits, now, context) do
      case operation do
        :initialize -> Macrostep.prepare_initialize(chart, session, options)
        :run -> Macrostep.prepare_run(chart, session, event, options)
        :platform -> Macrostep.prepare_platform(chart, session, event, options)
      end
    else
      nil -> {:error, Diagnostic.new(:invalid_flow_input, "Statechart Flow input is incomplete")}
      {:error, _diagnostic} = error -> error
      _other -> {:error, Diagnostic.new(:invalid_flow_input, "Statechart Flow input is invalid")}
    end
  end

  @doc false
  @spec validate_context(map()) :: :ok | {:error, Diagnostic.t()}
  def validate_context(context) when is_map(context) do
    case Enum.find(@protected_context, &Map.has_key?(context, &1)) do
      nil ->
        :ok

      key ->
        {:error,
         Diagnostic.new(:protected_context_override, "Statechart Flow context is protected",
           path: [:context, key]
         )}
    end
  end

  def validate_context(_context),
    do: {:error, Diagnostic.new(:invalid_flow_context, "Statechart Flow context must be a map")}

  defp operation(value, session, event) do
    with {:ok, operation} <- parse_operation(value, session, event),
         :ok <- validate_operation_input(operation, session, event) do
      {:ok, operation}
    end
  end

  defp parse_operation(value, _session, _event) when value in [:initialize, "initialize"],
    do: {:ok, :initialize}

  defp parse_operation(value, _session, _event) when value in [:run, "run"], do: {:ok, :run}

  defp parse_operation(value, _session, _event) when value in [:platform, "platform"],
    do: {:ok, :platform}

  defp parse_operation(nil, %Session{status: :new}, nil), do: {:ok, :initialize}
  defp parse_operation(nil, _session, nil), do: invalid_operation_input("event input is required")
  defp parse_operation(nil, _session, _event), do: {:ok, :run}

  defp parse_operation(_value, _session, _event),
    do: {:error, Diagnostic.new(:invalid_flow_operation, "Flow operation is invalid")}

  defp validate_operation_input(:initialize, %Session{status: :new, configuration: []}, nil),
    do: :ok

  defp validate_operation_input(:initialize, %Session{status: :new, configuration: []}, _event),
    do: invalid_operation_input("initialization cannot include an event")

  defp validate_operation_input(:initialize, _session, _event),
    do: invalid_operation_input("initialization requires a new empty session")

  defp validate_operation_input(:run, %Session{status: :active}, event) when not is_nil(event) do
    with {:ok, _event} <- Event.new_external(event), do: :ok
  end

  defp validate_operation_input(:run, %Session{status: :active}, nil),
    do: invalid_operation_input("run requires an external event")

  defp validate_operation_input(:run, _session, _event),
    do: invalid_operation_input("run requires an active session")

  defp validate_operation_input(:platform, %Session{status: :active}, event)
       when not is_nil(event) do
    with {:ok, %{class: :platform}} <- Event.new(event), do: :ok
  end

  defp validate_operation_input(:platform, _session, _event),
    do: invalid_operation_input("platform run requires an active session and platform event")

  defp invalid_operation_input(message),
    do: {:error, Diagnostic.new(:invalid_flow_input, message, path: [:flow, :input])}

  defp execution_options(registry, limits, now, context) do
    [registry: registry, limits: limits, now: now, deadline: deadline(context)]
  end

  defp runtime_now(nil), do: {:ok, DateTime.utc_now() |> DateTime.to_iso8601()}

  defp runtime_now(value) do
    case Jido.Statechart.Runtime.Timer.datetime(value) do
      {:ok, datetime} -> {:ok, DateTime.to_iso8601(datetime)}
      {:error, _diagnostic} = error -> error
    end
  end

  defp deadline(context) do
    case Jido.Exec.remaining_time(context) do
      :infinity -> :infinity
      nil -> :infinity
      remaining -> System.monotonic_time(:millisecond) + remaining
    end
  end
end
