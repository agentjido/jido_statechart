defmodule Jido.Statechart.Examples.Door do
  use Jido.Statechart.Agent, name: "example_door"

  statechart id: "door", initial: "closed" do
    state "closed" do
      transition "open", target: "opened"
    end

    state "opened" do
      transition "close", target: "closed"
    end
  end
end

alias Jido.Statechart.Examples.Door
agent = Door.new!(id: "door-1")
signal = Jido.Signal.new!("open", %{}, source: "/example")
{:ok, opened, []} = Door.cmd(agent, signal)
true = opened.state.chart.active == ["opened"]
{:ok, checkpoint} = Jido.Agent.checkpoint(opened)
{:ok, restored} = Jido.Agent.restore(Door, checkpoint)
true = restored == opened
IO.inspect(restored.state.chart, label: "Restored door")
