defmodule Jido.Statechart.Chart do
  @moduledoc "Builds a Flow-executable module with a package-owned chart and Registry."

  alias Jido.Statechart.{Diagnostic, Limits, Registry, Session}
  alias Jido.Statechart.Model.Chart, as: ModelChart

  @caller_fields [:operation, :session, :event, :limits, :now]
  @protected_fields [:chart, "chart", :registry, "registry", :context, "context"]
  @use_option_keys [:chart, :registry]

  @doc "Defines a chart module from compile-time chart and Registry expressions."
  defmacro __using__(options) do
    unless is_list(options) and Keyword.keyword?(options) do
      raise ArgumentError, "Jido.Statechart.Chart options must be a keyword list"
    end

    keys = Keyword.keys(options)

    if length(keys) != MapSet.size(MapSet.new(keys)) do
      raise ArgumentError, "Jido.Statechart.Chart options must not contain duplicate keys"
    end

    case Enum.find(keys, &(&1 not in @use_option_keys)) do
      nil ->
        :ok

      unknown ->
        raise ArgumentError, "Jido.Statechart.Chart has an unknown option: #{inspect(unknown)}"
    end

    chart = Keyword.fetch!(options, :chart)
    registry = Keyword.fetch!(options, :registry)

    quote location: :keep do
      @behaviour Jido.Executable

      @doc "Returns this module's normalized chart."
      @spec chart() :: Jido.Statechart.Model.Chart.t()
      def chart, do: unquote(chart)

      @doc "Returns this module's trusted Registry."
      @spec registry() :: Jido.Statechart.Registry.t()
      def registry, do: unquote(registry)

      @doc "Returns the canonical Statechart macrostep Flow."
      @spec flow() :: Jido.Flow.t()
      def flow, do: Jido.Statechart.Flow.flow()

      @doc false
      @impl Jido.Executable
      def __jido_executable__, do: Jido.Executable.flow(__MODULE__)

      @doc false
      @impl Jido.Executable
      def validate_params(params) do
        case Jido.Statechart.Chart.bind_input(params, chart(), registry()) do
          {:ok, bound} ->
            {:ok, bound}

          {:error, diagnostic} ->
            {:error,
             Jido.Action.Error.validation_error(diagnostic.message, %{
               code: diagnostic.code,
               path: diagnostic.path
             })}
        end
      end

      @doc false
      @impl Jido.Executable
      def validate_output(%Jido.Statechart.Result{} = result),
        do: Jido.Statechart.Result.new(result)

      def validate_output(_output),
        do: {:error, Jido.Action.Error.validation_error("Statechart output must be a Result")}

      @doc "Builds bound input for this chart module."
      @spec flow_input(Jido.Statechart.Session.t(), Jido.Statechart.Model.Event.t() | map() | nil) ::
              map()
      def flow_input(session, event \\ nil) do
        params = %{session: session, event: event}

        case Jido.Statechart.Chart.bind_input(params, chart(), registry()) do
          {:ok, bound} -> bound
          {:error, diagnostic} -> raise ArgumentError, "#{diagnostic.code}: #{diagnostic.message}"
        end
      end

      @doc "Initializes one new session through the canonical Flow."
      def initialize(%Jido.Statechart.Session{} = session, options \\ []) do
        params = %{operation: :initialize, session: session, event: nil}
        Jido.Statechart.Chart.execute(__MODULE__, params, options)
      end

      @doc "Runs one external event through the canonical Flow."
      def run(%Jido.Statechart.Session{} = session, event, options \\ []) do
        params = %{operation: :run, session: session, event: event}
        Jido.Statechart.Chart.execute(__MODULE__, params, options)
      end

      @doc "Compiles the canonical Statechart Flow."
      def compiled, do: Jido.Flow.compile!(flow())
    end
  end

  @doc false
  @spec bind_input(map(), ModelChart.t(), Registry.t()) ::
          {:ok, map()} | {:error, Diagnostic.t()}
  def bind_input(params, %ModelChart{} = chart, %Registry{} = registry) when is_map(params) do
    with :ok <- reject_protected(params),
         :ok <- Diagnostic.validate_fields(params, @caller_fields, [:flow, :input]),
         %Session{} <- Diagnostic.fetch(params, :session),
         %Limits{} = limits <- Diagnostic.fetch(params, :limits, Limits.default()) do
      {:ok,
       %{
         operation: Diagnostic.fetch(params, :operation),
         chart: chart,
         session: Diagnostic.fetch(params, :session),
         event: Diagnostic.fetch(params, :event),
         registry: registry,
         limits: limits,
         now: Diagnostic.fetch(params, :now)
       }}
    else
      {:error, _diagnostic} = error -> error
      _other -> {:error, Diagnostic.new(:invalid_flow_input, "Chart Flow input is invalid")}
    end
  end

  def bind_input(_params, _chart, _registry),
    do: {:error, Diagnostic.new(:invalid_flow_input, "Chart Flow input must be a map")}

  @doc false
  def execute(module, params, options) when is_atom(module) and is_map(params) do
    with :ok <- Jido.Statechart.Flow.validate_options(options) do
      params =
        case Keyword.fetch(options, :limits) do
          {:ok, limits} -> Map.put(params, :limits, limits)
          :error -> params
        end

      params =
        case Keyword.fetch(options, :now) do
          {:ok, now} -> Map.put(params, :now, now)
          :error -> params
        end

      Jido.Statechart.Flow.execute(module, params, options)
    end
  end

  defp reject_protected(params) do
    case Enum.find(@protected_fields, &Map.has_key?(params, &1)) do
      nil ->
        :ok

      field ->
        {:error,
         Diagnostic.new(:protected_flow_input, "Chart and Registry input is module-owned",
           path: [:flow, :input, field]
         )}
    end
  end
end
