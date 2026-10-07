defmodule Jido.Statechart.Agent.Extension do
  @moduledoc """
  Lowers `statechart:` Agent route targets to the normal Statechart Route Flow.

  A chart module stays separate from an Agent module. One Agent can bind one
  chart module, and the Statechart Plugin owns the one live session.
  """

  @behaviour Jido.Agent.Extension
  use Spark.Dsl.Extension

  alias Jido.Agent.Authoring
  alias Jido.Agent.Extension.RouteTarget
  alias Jido.Statechart.Agent
  alias Jido.Statechart.Agent.Route
  alias Jido.Statechart.Plugin

  @impl Jido.Agent.Extension
  def route_target_options, do: [:statechart]

  @impl Jido.Agent.Extension
  def lower_agent(config, entities) do
    with {:ok, routes, charts} <- lower_routes(Map.get(config, :routes, [])),
         {:ok, chart} <- one_chart(charts),
         {:ok, plugins} <- bind_plugin(Map.get(config, :plugins, []), chart),
         {:ok, routes} <- add_runtime_routes(routes) do
      {:ok, %{config | routes: routes, plugins: plugins}, entities}
    end
  end

  defp lower_routes(routes) when is_list(routes) do
    routes
    |> Enum.reduce_while({:ok, [], []}, fn route, {:ok, lowered, charts} ->
      case lower_route(route) do
        {:ok, route, nil} -> {:cont, {:ok, [route | lowered], charts}}
        {:ok, route, chart} -> {:cont, {:ok, [route | lowered], [chart | charts]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, lowered, charts} -> {:ok, Enum.reverse(lowered), Enum.reverse(charts)}
      error -> error
    end
  end

  defp lower_routes(value),
    do: Authoring.error("Statechart Agent routes must be a list", %{routes: value})

  defp lower_route(%{target: {%RouteTarget{} = target, defaults}} = route) do
    with {:ok, chart} <- owned_chart(target),
         do: {:ok, %{route | target: {Route, defaults}}, chart}
  end

  defp lower_route(%{target: %RouteTarget{} = target} = route) do
    with {:ok, chart} <- owned_chart(target), do: {:ok, %{route | target: Route}, chart}
  end

  defp lower_route(route), do: {:ok, route, nil}

  defp owned_chart(%RouteTarget{extension: __MODULE__, option: :statechart, value: chart}) do
    if chart_module?(chart) do
      {:ok, chart}
    else
      Authoring.error("Statechart Agent route requires a compiled chart module", %{chart: chart})
    end
  end

  defp owned_chart(target),
    do: Authoring.error("Statechart Agent route target has another owner", %{target: target})

  defp one_chart([]),
    do: Authoring.error("Statechart Agent extension requires one statechart route")

  defp one_chart([chart | charts]) do
    if Enum.all?(charts, &(&1 == chart)),
      do: {:ok, chart},
      else:
        Authoring.error("One Agent cannot own more than one statechart", %{
          charts: [chart | charts]
        })
  end

  defp bind_plugin(plugins, chart) when is_list(plugins) do
    matches =
      Enum.with_index(plugins)
      |> Enum.filter(fn {declaration, _index} -> plugin?(declaration) end)

    case matches do
      [] ->
        {:ok, plugins ++ [{Plugin, [chart: chart]}]}

      [{{Plugin, options}, index}] when is_list(options) ->
        with {:ok, options} <- put_chart(options, chart) do
          {:ok, List.replace_at(plugins, index, {Plugin, options})}
        end

      [{Plugin, index}] ->
        {:ok, List.replace_at(plugins, index, {Plugin, [chart: chart]})}

      _other ->
        Authoring.error("Statechart Plugin declaration is invalid or duplicated")
    end
  end

  defp bind_plugin(value, _chart),
    do: Authoring.error("Statechart Agent Plugins must be a list", %{plugins: value})

  defp plugin?(Plugin), do: true
  defp plugin?({Plugin, _options}), do: true
  defp plugin?(_declaration), do: false

  defp put_chart(options, chart) do
    case Keyword.fetch(options, :chart) do
      :error ->
        {:ok, Keyword.put(options, :chart, chart)}

      {:ok, ^chart} ->
        {:ok, options}

      {:ok, other} ->
        Authoring.error("Statechart Plugin chart conflicts with its route", %{chart: other})
    end
  end

  defp add_runtime_routes(routes) do
    runtime_paths = Agent.reserved_signal_types() ++ Agent.child_lifecycle_signal_types()

    with :ok <- available(routes, runtime_paths),
         {:ok, runtime_routes} <- runtime_routes(),
         {:ok, fallback} <- fallback(routes) do
      {:ok, routes ++ runtime_routes ++ List.wrap(fallback)}
    end
  end

  defp available(routes, paths) do
    case Enum.find(paths, fn path -> Enum.any?(routes, &(&1.path == path)) end) do
      nil ->
        :ok

      path ->
        Authoring.error("Statechart reserved Signal route conflicts with an authored route", %{
          path: path
        })
    end
  end

  defp runtime_routes do
    (Agent.reserved_signal_types() ++ Agent.child_lifecycle_signal_types())
    |> Enum.reduce_while({:ok, []}, fn type, {:ok, routes} ->
      target =
        cond do
          type == Agent.initialization_signal_type() -> Route
          type == Agent.cleanup_signal_type() -> Route.Cleanup
          type == Agent.reconciliation_signal_type() -> Jido.Statechart.Plugin.Schedule
          type == Agent.delivery_signal_type() -> Jido.Statechart.Plugin.RuntimeResult
          type == Agent.child_signal_type() -> Jido.Statechart.Plugin.ChildResult
          type in Agent.child_lifecycle_signal_types() -> Route.ChildLifecycle
          true -> Route.Reserved
        end

      case Authoring.route(type, target) do
        {:ok, route} -> {:cont, {:ok, [route | routes]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, routes} -> {:ok, Enum.reverse(routes)}
      {:error, _reason} = error -> error
    end
  end

  defp fallback(routes) do
    if Enum.any?(routes, &(&1.path == "**")), do: {:ok, nil}, else: Authoring.route("**", Route)
  end

  defp chart_module?(module) when is_atom(module) and not is_nil(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :chart, 0) and
      function_exported?(module, :registry, 0)
  end

  defp chart_module?(_module), do: false
end
