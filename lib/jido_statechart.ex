defmodule Jido.Statechart do
  @moduledoc """
  Defines an SCXML chart for use with `Jido.Statechart.Plugin`.

  The optional registry binds chart names to trusted guards, Actions, and child
  Agent modules. Chart text always refers to those bindings by string.
  """

  @doc "Defines a chart module from a compiled chart and an optional registry."
  defmacro __using__(options) do
    chart = Keyword.fetch!(options, :chart)
    registry = Keyword.get(options, :registry, {:%{}, [], []})

    quote do
      import Jido.Statechart, only: [sigil_SCXML: 2]

      @chart unquote(chart)
      @registry unquote(registry)
      def chart, do: @chart
      def registry, do: @registry
    end
  end

  @doc "Compiles literal SCXML at compile time."
  defmacro sigil_SCXML({:<<>>, _, [xml]}, []) when is_binary(xml) do
    xml |> compile!() |> Macro.escape()
  end

  defmacro sigil_SCXML(_, []), do: raise(ArgumentError, "~SCXML requires literal XML")
  defmacro sigil_SCXML(_, _), do: raise(ArgumentError, "~SCXML takes no modifiers")

  @doc "Compiles SCXML read at runtime, including SCXML from test templates."
  defdelegate compile!(xml), to: Jido.Statechart.SCXML

  @doc "Starts a chart session in a running Agent. Pass `:http_location` to enable Basic HTTP."
  def initialize(server, data \\ %{}, opts \\ []) when is_map(data) do
    with :ok <- Jido.AgentServer.await_ready(server) do
      Jido.AgentServer.call(server, initialization_signal(data, nil, opts[:http_location]))
    end
  end

  @doc false
  def initialization_signal(data, parent \\ nil, http_location \\ nil) do
    Jido.Signal.new!(
      "statechart.initialize",
      %{data: data, parent: parent, http_location: http_location},
      source: "/statechart"
    )
  end

  @doc "Reads the committed chart session from a running Agent."
  def session(server), do: Jido.AgentServer.snapshot(server).agent.state.statechart.session
end
