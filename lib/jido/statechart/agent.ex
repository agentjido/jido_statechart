defmodule Jido.Statechart.Agent do
  @moduledoc """
  Starts and addresses one live statechart session through normal Agent Turns.

  `initialize/2` gets a short-lived authenticated Signal from the supervised
  Statechart Plugin runtime. It returns only after AgentServer commits that
  initialization Turn. Proof values and runtime handles are not returned.
  """

  alias Jido.Statechart.Plugin.Runtime

  @initialization_signal "jido.statechart.initialize"
  @cleanup_signal "jido.statechart.cleanup.confirmed"
  @reserved_signals [
    @initialization_signal,
    @cleanup_signal,
    "jido.statechart.timer",
    "jido.statechart.delivery",
    "jido.statechart.child",
    "jido.statechart.reconcile"
  ]

  @doc "Initializes one live statechart session in an authenticated Turn."
  @spec initialize(Jido.AgentServer.server(), timeout() | keyword()) ::
          {:ok, Jido.Agent.instance()} | {:error, term()}
  def initialize(server, timeout_or_options \\ 5_000) do
    with {:ok, signal} <- Runtime.initialization_signal(server) do
      Jido.AgentServer.call(server, signal, timeout_or_options)
    end
  end

  @doc "Returns the reserved initialization Signal type."
  @spec initialization_signal_type() :: String.t()
  def initialization_signal_type, do: @initialization_signal

  @doc false
  @spec cleanup_signal_type() :: String.t()
  def cleanup_signal_type, do: @cleanup_signal

  @doc "Returns the closed set of runtime-owned Signal types."
  @spec reserved_signal_types() :: [String.t()]
  def reserved_signal_types, do: @reserved_signals

  @doc false
  @spec reserved_signal?(term()) :: boolean()
  def reserved_signal?(type), do: type in @reserved_signals
end
