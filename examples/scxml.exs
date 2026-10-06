defmodule Jido.Statechart.Examples.XMLDoor do
  use Jido.Statechart.Agent, name: "example_xml_door"

  @external_resource Path.join(__DIR__, "door.scxml")
  statechart_xml(File.read!(@external_resource), version: "1")
end

alias Jido.Statechart.{Event, SCXML}
alias Jido.Statechart.Examples.XMLDoor

# The caller owns file access. The adapter accepts only XML bytes.
chart = SCXML.compile!(File.read!(Path.join(__DIR__, "door.scxml")))
true = chart == XMLDoor.chart_definition()
{:ok, start} = Jido.Statechart.init(chart)
{:ok, event} = Event.new("door.open.request")
{:ok, result} = Jido.Statechart.step(chart, start.instance, event)
true = result.instance.configuration.active == ["opened"]

agent = XMLDoor.new!(id: "xml-door-1")
signal = Jido.Signal.new!("door.open.request", %{}, source: "/example")
{:ok, opened, []} = XMLDoor.cmd(agent, signal)
true = opened.state.chart.active == ["opened"]
{:ok, checkpoint} = Jido.Agent.checkpoint(opened)
{:ok, restored} = Jido.Agent.restore(XMLDoor, checkpoint)
true = restored == opened
IO.inspect(restored.state.chart, label: "Restored SCXML door")
