defmodule Jido.Statechart do
  @moduledoc """
  Deterministic, bounded statecharts for Jido V3.

  Compile data once. Pass the compiled definition and a trusted behavior
  registry to `init/3` and `step/4`. These functions start no process and perform
  no external I/O. A successful result contains one stable candidate and an
  ordered batch of post-commit effect requests.

  Use `Jido.Statechart.Agent` to execute the same interpreter through ordinary
  Jido Signals, Turns, state validation, checkpoints, and AgentServer.
  """
  alias Jido.Statechart.{Compiler, Definition, Error, Event, Instance, Registry, Result}
  @doc "Compiles bounded authoring data."
  @spec compile(term()) :: {:ok, Definition.t()} | {:error, Error.t()}
  defdelegate compile(data), to: Compiler
  @doc "Compiles authoring data or raises its error."
  @spec compile!(term()) :: Definition.t() | no_return()
  defdelegate compile!(data), to: Compiler
  @doc "Runs chart initialization through a pure macrostep."
  @spec init(Definition.t(), map(), Registry.t()) :: {:ok, Result.t()} | {:error, Error.t()}
  def init(definition, data \\ %{}, registry \\ %Registry{}),
    do: Jido.Statechart.Interpreter.init(definition, data, registry)

  @doc "Runs one external event to a stable result."
  @spec step(Definition.t(), Instance.t(), Event.t(), Registry.t()) ::
          {:ok, Result.t()} | {:error, Error.t()}
  def step(definition, instance, event, registry \\ %Registry{}),
    do: Jido.Statechart.Interpreter.step(definition, instance, event, registry)
end
