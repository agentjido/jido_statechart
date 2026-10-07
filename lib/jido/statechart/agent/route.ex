defmodule Jido.Statechart.Agent.Route do
  @moduledoc "The normal static Flow target used by Statechart Agent routes."

  @behaviour Jido.Executable

  alias Jido.Flow.{Ref, Step, Subflow}

  @flow Jido.Flow.new!(
          name: "jido_statechart_agent_route",
          components: [
            Step.new!(name: "prepare", action: __MODULE__.Prepare, params: Ref.input([])),
            Subflow.new!(
              name: "macrostep",
              flow: Jido.Statechart.Flow,
              params: Ref.result("prepare")
            ),
            Step.new!(
              name: "commit",
              action: Jido.Statechart.Plugin.Agent,
              params: %{result: Ref.result("macrostep")}
            )
          ],
          output: Ref.result("commit")
        )

  @doc "Returns the static live-route Flow."
  def flow, do: @flow

  @doc false
  @impl Jido.Executable
  def __jido_executable__, do: Jido.Executable.flow(__MODULE__)

  @doc false
  @impl Jido.Executable
  def validate_params(params) when is_map(params), do: {:ok, params}

  def validate_params(_params),
    do: {:error, Jido.Action.Error.validation_error("Statechart Agent route input must be a map")}

  @doc false
  @impl Jido.Executable
  def validate_output(output) when is_map(output) and not is_struct(output), do: {:ok, output}

  def validate_output(_output),
    do:
      {:error, Jido.Action.Error.validation_error("Statechart Agent route output must be state")}

  @doc "Compiles the static live-route Flow."
  def compiled, do: Jido.Flow.compile!(@flow)
end

defmodule Jido.Statechart.Agent.Route.Reserved do
  @moduledoc false
  use Jido.Action, name: "statechart_agent_reserved_signal"

  alias Jido.Plugin.Input
  alias Jido.Statechart.Plugin

  @impl true
  def run(_params, context) do
    case get_in(context, [:plugin_inputs, Plugin]) do
      %Input{
        prepared: %{kind: :reserved_rejection, reason: reason},
        runtime: %{authenticated_reserved: true}
      } ->
        {:error, reason}

      _other ->
        {:error, :invalid_statechart_reserved_input}
    end
  end
end

defmodule Jido.Statechart.Agent.Route.ChildLifecycle do
  @moduledoc false
  use Jido.Action, name: "statechart_agent_child_lifecycle"

  alias Jido.Plugin.Input
  alias Jido.Statechart.Plugin

  @impl true
  def run(_params, context) do
    case get_in(context, [:plugin_inputs, Plugin]) do
      %Input{prepared: %{kind: :child_lifecycle}} -> {:ok, context.agent_state, []}
      _other -> {:error, :invalid_statechart_child_lifecycle_input}
    end
  end
end

defmodule Jido.Statechart.Agent.Route.Prepare do
  @moduledoc false
  use Jido.Action, name: "statechart_agent_route_prepare"

  alias Jido.Plugin.Input
  alias Jido.Statechart.Plugin

  @impl true
  def run(_params, context) do
    with %Input{prepared: prepared} <- get_in(context, [:plugin_inputs, Plugin]),
         %{
           kind: :macrostep,
           chart: chart,
           session: session,
           event: event,
           operation: operation,
           limits: limits
         } <- prepared,
         :ok <- authenticated(operation, get_in(context, [:plugin_inputs, Plugin])) do
      {:ok,
       %{
         operation: operation,
         chart: chart.chart(),
         registry: chart.registry(),
         session: session,
         event: event,
         limits: limits
       }}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_statechart_prepared_input}
    end
  end

  defp authenticated(:initialize, %Input{runtime: %{authenticated_reserved: true}}), do: :ok
  defp authenticated(:initialize, _input), do: {:error, :statechart_live_initialization_required}
  defp authenticated(:run, _input), do: :ok
end

defmodule Jido.Statechart.Agent.Route.Cleanup do
  @moduledoc false
  use Jido.Action, name: "statechart_agent_cleanup"

  alias Jido.Agent.Directive
  alias Jido.Plugin.Input
  alias Jido.Statechart.Plugin
  alias Jido.Statechart.Plugin.Commit

  @impl true
  def run(_params, context) do
    with %Input{
           prepared: %{kind: :cleanup, session: session, signal_id: signal_id},
           runtime: %{authenticated_reserved: true}
         } <- get_in(context, [:plugin_inputs, Plugin]),
         true <- session.status == :completed,
         true <- Plugin.cleanup_complete?(session) do
      next = %{
        session
        | status: :stopped,
          revision: session.revision + 1,
          revision_fence: max(session.revision_fence, session.revision + 1)
      }

      commit = %Commit{
        session: next,
        expected_revision: session.revision,
        signal_id: signal_id,
        operation: :cleanup
      }

      {:ok, context.agent_state, [commit, Directive.stop(:normal)]}
    else
      false -> {:error, :statechart_cleanup_not_complete}
      _other -> {:error, :invalid_statechart_cleanup_input}
    end
  end
end
