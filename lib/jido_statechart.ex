defmodule Jido.Statechart do
  @moduledoc """
  Defines an SCXML chart for use with `Jido.Statechart.Plugin`.

  The optional registry binds chart names to trusted guards, Actions, and child
  Agent modules. Chart text always refers to those bindings by string.
  """

  alias Jido.AgentServer
  alias Jido.Statechart.{Error, SCXML}

  @xml_schema Zoi.string()

  @typedoc "A compiled chart accepted by the Statechart Plugin."
  @type chart :: map()

  @doc "Defines a chart module from a compiled chart and an optional registry."
  defmacro __using__(options) do
    chart = Keyword.fetch!(options, :chart)
    registry = Keyword.get(options, :registry, {:%{}, [], []})

    quote do
      import Jido.Statechart, only: [sigil_SCXML: 2]

      @chart unquote(chart)
      @registry unquote(registry)

      @doc "Returns the compiled chart for the Statechart Plugin."
      @spec chart() :: Jido.Statechart.chart()
      def chart, do: @chart

      @doc "Returns the chart's named bindings."
      @spec registry() :: map()
      def registry, do: @registry
    end
  end

  @doc "Compiles literal SCXML at compile time."
  defmacro sigil_SCXML({:<<>>, _, [xml]}, []) when is_binary(xml) do
    xml |> compile!() |> Macro.escape()
  end

  defmacro sigil_SCXML(_, []), do: raise(ArgumentError, "~SCXML requires literal XML")
  defmacro sigil_SCXML(_, _), do: raise(ArgumentError, "~SCXML takes no modifiers")

  @doc """
  Compiles runtime XML into a chart.

  Returns an invalid-chart error for invalid input or unsupported SCXML.
  """
  @spec compile(term()) :: {:ok, chart()} | {:error, Error.InvalidChart.t()}
  def compile(xml) do
    case Zoi.parse(@xml_schema, xml) do
      {:ok, xml} -> {:ok, compile!(xml)}
      {:error, _issues} -> {:error, Error.InvalidChart.exception(reason: "expected an XML string")}
    end
  rescue
    error in [ArgumentError, SCXML.Unsupported] ->
      {:error, Error.InvalidChart.exception(reason: Exception.message(error))}
  end

  @doc "Compiles runtime XML. Raises if the XML is invalid or uses unsupported SCXML."
  @spec compile!(String.t()) :: chart()
  defdelegate compile!(xml), to: SCXML

  @doc """
  Starts a chart session in a running Agent.

  Pass initial values in `data` for root data declarations. Pass
  `:http_location` in `opts` to give the Basic HTTP processor an access URI.
  Check the returned turn status before sending chart events.
  """
  @spec initialize(AgentServer.server(), map(), keyword()) ::
          {:ok, AgentServer.TurnResult.t()} | {:error, term()}
  def initialize(server, data \\ %{}, opts \\ []) when is_map(data) do
    with :ok <- AgentServer.await_ready(server) do
      AgentServer.call(server, initialization_signal(data, nil, opts[:http_location]))
    end
  end

  @doc false
  @spec initialization_signal(map(), map() | nil, String.t() | nil) :: Jido.Signal.t()
  def initialization_signal(data, parent \\ nil, http_location \\ nil) do
    Jido.Signal.new!(
      "statechart.initialize",
      %{data: data, parent: parent, http_location: http_location},
      source: "/statechart"
    )
  end

  @doc "Reads the committed chart session, or `nil` before initialization, from a running Agent."
  @spec session(AgentServer.server()) :: map() | nil
  def session(server), do: AgentServer.snapshot(server).agent.state.statechart.session
end
