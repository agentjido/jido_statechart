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
  @timer_signal "jido.statechart.timer"
  @delivery_signal "jido.statechart.delivery"
  @child_signal "jido.statechart.child"
  @reconciliation_signal "jido.statechart.reconcile"
  @child_lifecycle_signals [
    "jido.agent.child.started",
    "jido.agent.child.exit",
    "jido.agent.orphaned"
  ]
  @reserved_signals [
    @initialization_signal,
    @cleanup_signal,
    @timer_signal,
    @delivery_signal,
    @child_signal,
    @reconciliation_signal
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

  @doc false
  def timer_signal_type, do: @timer_signal

  @doc false
  def delivery_signal_type, do: @delivery_signal

  @doc false
  def child_signal_type, do: @child_signal

  @doc false
  def reconciliation_signal_type, do: @reconciliation_signal

  @doc false
  def child_lifecycle_signal_types, do: @child_lifecycle_signals

  @doc "Returns the closed set of runtime-owned Signal types."
  @spec reserved_signal_types() :: [String.t()]
  def reserved_signal_types, do: @reserved_signals

  @doc false
  @spec reserved_signal?(term()) :: boolean()
  def reserved_signal?(type), do: type in @reserved_signals
end
