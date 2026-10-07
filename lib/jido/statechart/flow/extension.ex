defmodule Jido.Statechart.Flow.Extension do
  @moduledoc "Adds Statechart Subflow syntax to the Jido Flow module DSL."

  use Jido.Flow.Extension

  @doc "Expands a bound chart module to a normal Flow Subflow declaration."
  defmacro statechart(name, chart_module, params) do
    quote do
      step(unquote(name), action: unquote(chart_module), params: unquote(params))
    end
  end

  @doc "Expands generic Statechart Flow input to a normal Flow Subflow declaration."
  defmacro statechart(name, params) do
    quote do
      step(unquote(name), action: Jido.Statechart.Flow, params: unquote(params))
    end
  end
end
