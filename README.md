# Jido Statechart

Use SCXML 1.0 to define how a Jido Agent changes state in response to Signals.
A chart controls transitions, entry and exit work, and completion. The
Statechart Plugin stores the session on the Agent.

## Run an approval Agent

Clone this repository and run `mix setup` from the package root. Use Elixir
1.18 or later and Erlang/OTP 27 or later. The project uses the Jido
`release/v3` GitHub branch for Flows as Iterate bodies.

Start `iex -S mix` and enter the following example. The chart starts in
`pending` and finishes when it receives `order.approved`.

```elixir
defmodule Orders.ApprovalChart do
  use Jido.Statechart,
    chart: ~SCXML"""
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="pending">
      <state id="pending">
        <transition event="order.approved" target="approved"/>
      </state>
      <final id="approved"/>
    </scxml>
    """
end

defmodule Orders.ApprovalAgent do
  use Jido.Agent,
    name: "order_approval",
    plugins: [{Jido.Statechart.Plugin, %{chart: Orders.ApprovalChart}}]

  routes do
    route("order.approved", Jido.Statechart.Plugin.Route)
  end
end

{:ok, root} = Jido.start_link(name: Orders.Jido, namespace: "orders")
{:ok, agent} = Jido.start_agent(Orders.Jido, Orders.ApprovalAgent, id: "order-42")

{:ok, %{status: :committed}} = Jido.Statechart.initialize(agent)
%{state: "pending", status: :active} = Jido.Statechart.session(agent)

signal = Jido.Signal.new!("order.approved", %{}, source: "/orders")
{:ok, %{status: :committed}} = Jido.AgentServer.call(agent, signal)
%{state: "approved", status: :completed} = Jido.Statechart.session(agent)

Supervisor.stop(root)
```

Initialization enters the starting configuration. The Plugin supplies the
initialization route. Add a route to `Jido.Statechart.Plugin.Route` for each
application event the chart receives. Other routes can run normal Agent work.

The `~SCXML` sigil compiles a literal chart at compile time. Use
`Jido.Statechart.compile/1` for XML loaded at runtime. It returns a chart or
a `Jido.Statechart.Error.InvalidChart` error. Supply a `registry:` to
`use Jido.Statechart` when your chart refers to named guards, Actions, or
child Agents.

## SCXML support

The interpreter supports compound and parallel states, shallow and deep
history, final states, eventless transitions, and named event descriptors.
A Jido Flow processes the chart to a stable configuration. The Plugin commits
the session before it dispatches external effects such as HTTP sends and child
Agent invocations.

The compiler supports the null data model and the Jido data model. W3C
fixtures use an in-memory template translation for the supported data model.
ECMAScript and the other scripting cases stay deferred.

## Run the checks

```sh
mix quality
mix coveralls --warnings-as-errors
mix statechart.w3c test/fixtures/w3c/355/test355.txml
mix statechart.w3c --manifest test/fixtures/w3c/manifest.xml
```

The W3C runner starts a live Agent and reads its verdict from the final
session. The full manifest has 202 entries. It reports 176 passes, one
adjustment, one expected failure, and 24 deferred entries.

- Fixture 198 passes with an in-memory adjustment to compare `origintype`
  with `"scxml"`.
- Fixture 352 expects a URI for `origintype`. It reports an expected failure
  because the runtime uses `"scxml"`.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow.
The library uses the [Apache 2.0 license](LICENSE). The W3C fixtures use the
[W3C 3-clause BSD license](https://github.com/agentjido/jido_statechart/blob/main/test/fixtures/w3c/LICENSE).
