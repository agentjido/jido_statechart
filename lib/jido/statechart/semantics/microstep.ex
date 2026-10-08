defmodule Jido.Statechart.Semantics.Microstep do
  @moduledoc "Runs exits, transition content, and entries in SCXML order."

  alias Jido.Statechart.{DataModel, Diagnostic, ExecutableContent}
  alias Jido.Statechart.Model.{Chart, Executable, Transition}
  alias Jido.Statechart.Runtime.Invocation
  alias Jido.Statechart.Semantics.{Completion, Configuration, Domain, EntryExit, History}

  @fatal_data_codes [
    :data_limit_exceeded,
    :expression_limit_exceeded,
    :internal_queue_limit_exceeded
  ]

  @spec run(Chart.t(), map(), [Transition.t()], keyword()) ::
          {:ok, map()} | {:error, Diagnostic.t()}
  def run(%Chart{} = chart, workspace, transitions, options)
      when is_map(workspace) and is_list(transitions) and is_list(options) do
    options =
      if Keyword.keyword?(options),
        do: Keyword.put(options, :data_model, chart.datamodel),
        else: options

    with {:ok, limits} <- DataModel.limits(options),
         :ok <- Configuration.validate(chart, workspace.configuration),
         {:ok, workspace} <- charge(workspace, limits),
         exit_ids =
           Domain.exit_set(chart, transitions, workspace.configuration, workspace.history),
         history = History.save(chart, workspace.configuration, exit_ids, workspace.history),
         workspace = %{workspace | history: history},
         {:ok, workspace} <- execute_exits(chart, exit_ids, workspace, options),
         {:ok, workspace} <- execute_transitions(transitions, workspace, options),
         remaining = Enum.reject(workspace.configuration, &(&1 in exit_ids)),
         plan = EntryExit.entry_plan(chart, transitions, remaining, history),
         {:ok, workspace} <- execute_entries(chart, plan, workspace, options),
         :ok <- Configuration.validate(chart, plan.atomic_ids) do
      {:ok,
       %{
         workspace
         | configuration: plan.atomic_ids,
           active_state_ids: Configuration.active_state_ids(chart, plan.atomic_ids),
           last_microstep: %{
             "exited" => exit_ids,
             "transitions" => Enum.map(transitions, & &1.id),
             "entered" => plan.entry_ids,
             "configuration" => plan.atomic_ids
           }
       }}
    end
  end

  def run(_chart, _workspace, _transitions, _options) do
    {:error, Diagnostic.new(:invalid_semantic_input, "microstep input is invalid")}
  end

  @spec initialize(Chart.t(), map(), keyword()) :: {:ok, map()} | {:error, Diagnostic.t()}
  def initialize(%Chart{} = chart, workspace, options) do
    options =
      if Keyword.keyword?(options),
        do: Keyword.put(options, :data_model, chart.datamodel),
        else: options

    with {:ok, limits} <- DataModel.limits(options),
         {:ok, workspace} <- charge(workspace, limits),
         plan = EntryExit.initial_plan(chart, workspace.history),
         {:ok, workspace} <- execute_entries(chart, plan, workspace, options),
         :ok <- Configuration.validate(chart, plan.atomic_ids) do
      {:ok,
       %{
         workspace
         | configuration: plan.atomic_ids,
           active_state_ids: Configuration.active_state_ids(chart, plan.atomic_ids),
           last_microstep: %{
             "exited" => [],
             "transitions" => [],
             "entered" => plan.entry_ids,
             "configuration" => plan.atomic_ids
           }
       }}
    end
  end

  @doc false
  @spec exit_interpreter(Chart.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Diagnostic.t()}
  def exit_interpreter(%Chart{}, %{configuration: []} = workspace, _options),
    do: {:ok, workspace}

  def exit_interpreter(%Chart{} = chart, workspace, options) do
    exit_ids = Configuration.exit_order(chart, workspace.active_state_ids)

    with {:ok, workspace} <- execute_exits(chart, exit_ids, workspace, options) do
      {:ok,
       %{
         workspace
         | configuration: [],
           active_state_ids: [],
           last_microstep: %{
             "exited" => exit_ids,
             "transitions" => [],
             "entered" => [],
             "configuration" => []
           }
       }}
    end
  end

  defp execute_exits(chart, exit_ids, workspace, options) do
    states = Configuration.state_map(chart)

    Enum.reduce_while(exit_ids, {:ok, workspace}, fn id, {:ok, current} ->
      state = Map.fetch!(states, id)

      case run_content(state.on_exit, current, options) do
        {:ok, next} ->
          case Invocation.exit(chart, id, next, options) do
            {:ok, next} ->
              {:cont, {:ok, %{next | active_state_ids: List.delete(next.active_state_ids, id)}}}

            {:error, _diagnostic} = error ->
              {:halt, error}
          end

        {:error, _diagnostic} = error ->
          {:halt, error}
      end
    end)
  end

  defp execute_transitions(transitions, workspace, options) do
    transitions
    |> Enum.sort_by(& &1.ordinal)
    |> Enum.reduce_while({:ok, workspace}, fn transition, {:ok, current} ->
      case run_content(transition.executable, current, options) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _diagnostic} = error -> {:halt, error}
      end
    end)
  end

  defp execute_entries(chart, plan, workspace, options) do
    states = Configuration.state_map(chart)

    Enum.reduce_while(plan.entry_ids, {:ok, workspace}, fn id, {:ok, current} ->
      state = Map.fetch!(states, id)
      active = Configuration.entry_order(chart, [id | current.active_state_ids])
      current = %{current | active_state_ids: active}

      with {:ok, current} <- initialize_late_data(chart, state, current, options),
           {:ok, current} <- run_content(state.on_entry, current, options),
           {:ok, current} <- initial_content(chart, state, plan, current, options),
           {:ok, current} <- history_content(state, plan, current, options),
           {:ok, current} <- Completion.entered_final(chart, state, current, options),
           {:ok, current} <- Invocation.enter(chart, id, current, options) do
        {:cont, {:ok, current}}
      else
        {:error, _diagnostic} = error -> {:halt, error}
      end
    end)
  end

  defp initial_content(chart, state, plan, workspace, options) do
    if state.id in plan.default_entry_ids do
      chart.metadata
      |> Map.get("initial_transition_content", %{})
      |> Map.get(state.id, [])
      |> load_commands()
      |> run_content(workspace, options)
    else
      {:ok, workspace}
    end
  end

  defp history_content(state, plan, workspace, options) do
    plan.history_content
    |> Map.get(state.id, [])
    |> run_content(workspace, options)
  end

  defp load_commands(commands) do
    Enum.map(commands, fn
      %Executable{} = command -> command
      command -> Executable.new!(command)
    end)
  end

  defp run_content([], workspace, _options), do: {:ok, workspace}

  defp run_content(commands, workspace, options) do
    ExecutableContent.run(commands, workspace, options)
  end

  defp initialize_late_data(%Chart{binding: "late"} = chart, state, workspace, options) do
    if state.data == %{} or state.id in workspace.initialized_data_state_ids do
      {:ok, workspace}
    else
      with {:ok, model} <- DataModel.resolve(chart.datamodel),
           result <-
             model.initialize(
               state.data,
               %{
                 data: workspace.data,
                 system: workspace.system,
                 bindings: workspace.bindings,
                 active_state_ids: workspace.active_state_ids
               },
               options
             ) do
        case result do
          {:ok, initialized} ->
            {:ok,
             %{
               workspace
               | data: Map.merge(workspace.data, initialized),
                 initialized_data_state_ids:
                   record_initialized_data_state(chart, workspace, state.id)
             }}

          {:error, %Diagnostic{code: code} = diagnostic} when code in @fatal_data_codes ->
            {:error, diagnostic}

          {:error, diagnostic} ->
            with {:ok, workspace} <- enqueue_execution_error(workspace, diagnostic, options) do
              {:ok,
               %{
                 workspace
                 | initialized_data_state_ids:
                     record_initialized_data_state(chart, workspace, state.id)
               }}
            end
        end
      end
    end
  end

  defp initialize_late_data(_chart, _state, workspace, _options), do: {:ok, workspace}

  defp record_initialized_data_state(chart, workspace, state_id) do
    Configuration.entry_order(
      chart,
      Enum.uniq(workspace.initialized_data_state_ids ++ [state_id])
    )
  end

  defp enqueue_execution_error(workspace, diagnostic, options) do
    with {:ok, limits} <- DataModel.limits(options) do
      if length(workspace.internal_queue) < limits.internal_queue_events do
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

        {:ok, %{workspace | internal_queue: workspace.internal_queue ++ [event]}}
      else
        {:error,
         Diagnostic.new(:internal_queue_limit_exceeded, "Internal event queue limit was reached")}
      end
    end
  end

  defp charge(workspace, limits) do
    if workspace.work_count < limits.microsteps_per_macrostep do
      {:ok, %{workspace | work_count: workspace.work_count + 1}}
    else
      {:error,
       Diagnostic.new(:microstep_limit_exceeded, "Microstep limit was reached",
         path: [:macrostep],
         correction: %{"maximum_microsteps" => limits.microsteps_per_macrostep}
       )}
    end
  end
end
