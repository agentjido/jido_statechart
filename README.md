# Jido Statechart

This spike runs a small subset of SCXML 1.0 in Jido Agents. Define a chart
with `use Jido.Statechart` and compile its XML with `~SCXML`. Attach
`Jido.Statechart.Plugin` to the Agent and route its chart Signals to
`Jido.Statechart.Plugin.Route`.

The Plugin owns the committed chart session. A Jido Flow applies each
microstep in an Iterate subflow. The Plugin dispatches child Agent work
after the parent turn commits. Jido is pinned to the commit that adds
Flow bodies to Iterate.

## Run the cases

```sh
mix deps.get
mix quality
mix statechart.w3c test/fixtures/w3c/355/test355.txml
```

The W3C mode translates templates in memory and reads the verdict from
the Agent's final state. Fixture 415 checks the terminal session. Fixture 513
checks the Basic HTTP response and event data. To run a local W3C corpus,
pass its XML manifest with `mix statechart.w3c --manifest PATH/manifest.xml`.

The spike supports compound and parallel configurations, shallow and deep
history, final states, eventless transitions, and named event descriptors.
It supports entry and exit handlers, raised events, delayed sends to the
same session, and a Jido data model with registry guards and Actions.
Each active state can invoke a registered local child Agent or an inline
SCXML chart after the turn has reached a stable configuration.
The runner reports unsupported W3C template features as skips.

Library license is Apache-2.0. The W3C fixtures use the
[W3C 3-clause BSD license](test/fixtures/w3c/LICENSE).
