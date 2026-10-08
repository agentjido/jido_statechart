defmodule Jido.Statechart.Flow do
  @moduledoc "The canonical static Jido Flow for one bounded Statechart macrostep."

  @behaviour Jido.Executable

  alias Jido.Flow.{Iterate, Ref, Step}
  alias Jido.Statechart.Actions.{Finish, Microstep, Prepare}
  alias Jido.Statechart.{Limits, Registry, Result, Session}
  alias Jido.Statechart.Model.{Chart, Event}

  @exec_option_keys [:timeout, :max_concurrency, :max_continuations, :task_supervisor]
  @runtime_option_keys [:limits, :now, :context | @exec_option_keys]
  @input_option_keys [:operation, :limits, :now]

  @flow Jido.Flow.new!(
          name: "jido_statechart_macrostep",
          components: [
            Step.new!(name: "prepare", action: Prepare, params: Ref.input([])),
            Iterate.new!(
              name: "microstep",
              action: Microstep,
              params: %{state: Ref.state([])},
              state: [
                schema: [],
                initial: Ref.result("prepare"),
                update: Ref.body_result([])
              ],
              completion: Ref.state(:complete),
              max_iterations: 10_000
            ),
            Step.new!(
              name: "finish",
              action: Finish,
              params: %{state: Ref.result("microstep", [:state])}
            )
          ],
          output: Ref.result("finish")
        )

  @doc "Returns the one canonical macrostep Flow."
  @spec flow() :: Jido.Flow.t()
  def flow, do: @flow

  @doc false
  @impl Jido.Executable
  def __jido_executable__, do: Jido.Executable.flow(__MODULE__)

  @doc false
  @impl Jido.Executable
  def validate_params(params) when is_map(params), do: {:ok, params}

  def validate_params(_params),
    do: {:error, Jido.Action.Error.validation_error("Statechart Flow input must be a map")}

  @doc false
  @impl Jido.Executable
  def validate_output(%Result{} = output), do: Result.new(output)

  def validate_output(_output),
    do: {:error, Jido.Action.Error.validation_error("Statechart Flow output must be a Result")}

  @doc "Compiles the canonical macrostep Flow."
  @spec compiled() :: Jido.Flow.Compiled.t()
  def compiled, do: Jido.Flow.compile!(@flow)

  @doc "Runs the canonical Flow with default Exec options."
  @spec run(map(), map()) :: Jido.Exec.exec_result()
  def run(params, context), do: Jido.Exec.run(__MODULE__, params, context)

  @doc "Builds generic Flow input for initialization or one external event."
  @spec input(Chart.t(), Session.t(), Event.t() | map() | nil, Registry.t(), keyword()) :: map()
  def input(%Chart{} = chart, %Session{} = session, event, %Registry{} = registry, options \\ []) do
    validate_input_options!(options)
    operation = Keyword.get(options, :operation, inferred_operation(session, event))
    limits = Keyword.get(options, :limits, Limits.default())
    now = Keyword.get(options, :now)

    %{
      operation: operation,
      chart: chart,
      session: session,
      event: event,
      registry: registry,
      limits: limits,
      now: now
    }
  end

  @doc "Runs initialization through the canonical Flow."
  @spec initialize(Chart.t(), Session.t(), Registry.t(), keyword()) :: Jido.Exec.exec_result()
  def initialize(%Chart{} = chart, %Session{} = session, %Registry{} = registry, options \\ []) do
    with :ok <- validate_options(options) do
      input_options =
        options |> Keyword.take([:limits, :now]) |> Keyword.put(:operation, :initialize)

      execute(__MODULE__, input(chart, session, nil, registry, input_options), options)
    end
  end

  @doc "Runs one external event through the canonical Flow."
  @spec step(Chart.t(), Session.t(), Event.t() | map(), Registry.t(), keyword()) ::
          Jido.Exec.exec_result()
  def step(%Chart{} = chart, %Session{} = session, event, %Registry{} = registry, options \\ []) do
    with :ok <- validate_options(options) do
      input_options = options |> Keyword.take([:limits, :now]) |> Keyword.put(:operation, :run)
      execute(__MODULE__, input(chart, session, event, registry, input_options), options)
    end
  end

  @doc false
  @spec platform_step(Chart.t(), Session.t(), Event.t() | map(), Registry.t(), keyword()) ::
          Jido.Exec.exec_result()
  def platform_step(
        %Chart{} = chart,
        %Session{} = session,
        event,
        %Registry{} = registry,
        options \\ []
      ) do
    with :ok <- validate_options(options) do
      input_options =
        options |> Keyword.take([:limits, :now]) |> Keyword.put(:operation, :platform)

      execute(__MODULE__, input(chart, session, event, registry, input_options), options)
    end
  end

  @doc false
  @spec execute(module(), map(), term()) :: Jido.Exec.exec_result() | {:error, term()}
  def execute(module, input, options) when is_atom(module) and is_map(input) do
    with :ok <- validate_options(options) do
      context = Keyword.get(options, :context, %{})
      exec_options = Keyword.take(options, @exec_option_keys)
      Jido.Exec.run(module, input, context, exec_options)
    end
  end

  @doc false
  @spec validate_options(term(), [atom()]) :: :ok | {:error, Jido.Statechart.Diagnostic.t()}
  def validate_options(options, allowed \\ @runtime_option_keys) do
    cond do
      not is_list(options) or not Keyword.keyword?(options) ->
        invalid_options("Flow options must be a keyword list")

      length(Keyword.keys(options)) != MapSet.size(MapSet.new(Keyword.keys(options))) ->
        invalid_options("Flow options must not contain duplicate keys")

      unknown = Enum.find(Keyword.keys(options), &(&1 not in allowed)) ->
        invalid_options("Flow has an unknown option: #{inspect(unknown)}", [:options, unknown])

      true ->
        :ok
    end
  end

  @doc false
  @spec runtime_option_keys() :: [atom()]
  def runtime_option_keys, do: @runtime_option_keys

  defp validate_input_options!(options) do
    case validate_options(options, @input_option_keys) do
      :ok ->
        :ok

      {:error, diagnostic} ->
        detail =
          if diagnostic.path == [],
            do: diagnostic.message,
            else: "#{diagnostic.message}: #{inspect(diagnostic.path)}"

        raise ArgumentError, detail
    end
  end

  defp invalid_options(message, path \\ [:options]),
    do: {:error, Jido.Statechart.Diagnostic.new(:invalid_flow_options, message, path: path)}

  defp inferred_operation(%Session{status: :new}, nil), do: :initialize
  defp inferred_operation(_session, _event), do: :run
end
