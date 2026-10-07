# Jido Statechart

Jido Statechart provides bounded SCXML statecharts for Jido V3. It compiles a
secure SCXML input into one normalized chart. The same semantic kernel runs in
the direct `Jido.Flow` path and in a live Jido Agent.

This package implements the **Jido SCXML 1.0 Profile**. It does not claim full
W3C SCXML processor conformance. The profile has finite work limits, a restricted
XML input, local allowlisted targets, and Jido commit timing. Use
`Jido.Statechart.capabilities/0` to read the machine-readable profile.

The package is in V3 integration. Its default dependencies are local sibling
paths. Do not publish the package until the separate Hex dependency gate passes.

## Local setup

Keep `jido_statechart` beside `jido`, `jido_action`, `jido_signal`, and `zoi`.
Then run:

```sh
mix deps.get
mix quality
```

See [Contribution](CONTRIBUTING.md) for the exact tested source commits and all
release checks.

## Direct Flow API

Use the direct API for a pure, bounded macrostep. It does not send external
Signals, start timers, start children, reconcile operations, or persist state.
It returns the next stable session and ordered intent records to the caller.

```elixir
alias Jido.Statechart
alias Jido.Statechart.{Limits, Profile, Registry, SCXML, Session}

chart =
  "examples/door.scxml"
  |> File.read!()
  |> SCXML.compile!(id: "door", source_uri: "examples/door.scxml")

registry = Registry.new!(%{version: "door-registry-1", entries: []})
limits = Limits.default()

session =
  Session.new!(%{
    id: "door-direct",
    incarnation: "door-direct-1",
    chart_fingerprint: chart.fingerprint,
    profile_version: Profile.version(),
    registry_version: registry.version,
    registry_digest: registry.digest,
    limits_digest: Limits.digest(limits),
    invocation_remaining_descendants: limits.total_descendants
  })

{:ok, initialized} = Statechart.initialize(chart, session, registry)
{:ok, result} = Statechart.step(chart, initialized.session, %{name: "door.open"}, registry)

result.session.configuration
# => ["opened"]
```

The input session is unchanged when a macrostep fails. An unhandled external
event is a successful stable no-op. The result contains a stable session,
ordered intents, a redacted trace, and operation counts.

## Live Agent and Plugin API

Use the live API when Jido must commit state, dispatch external work, reconcile
unknown outcomes, persist state, or own child processes. A chart module owns the
compiled chart and its trusted Registry. An ordinary Jido Agent uses the
Statechart Agent extension.

```elixir
defmodule MyApp.DoorChart do
  @path Path.expand("examples/door.scxml")
  @external_resource @path
  @chart @path |> File.read!() |> Jido.Statechart.SCXML.compile!(id: "door")
  @registry Jido.Statechart.Registry.new!(%{version: "door-registry-1", entries: []})

  use Jido.Statechart.Chart, chart: @chart, registry: @registry
end

defmodule MyApp.DoorAgent do
  use Jido.Agent,
    name: "door",
    extensions: [Jido.Statechart.Agent.Extension]

  agent do
    schema(Zoi.object(%{label: Zoi.string() |> Zoi.default("door")}))
  end

  routes do
    route("door.open", statechart: MyApp.DoorChart)
  end
end

{:ok, jido} = Jido.start_link(name: :my_app, namespace: "my-app")
{:ok, server} = Jido.start_agent(:my_app, MyApp.DoorAgent, id: "front-door")

# This reserved Turn is required before any business Signal.
{:ok, _agent} = Jido.Statechart.Agent.initialize(server)

signal = Jido.Signal.new!("door.open", %{}, id: "door-input-1", source: "/example")
{:ok, agent} = Jido.AgentServer.call(server, signal)
agent.state.statechart.session.configuration
# => ["opened"]
```

Input and delivery are at least once. The Plugin keeps recent Signal IDs in a
bounded FIFO window. The default window is 1,024 IDs and the allowed range is
1 through 100,000. An ID that leaves this window can run again. This window is
not a durable idempotency record for a receiver.

The Plugin commits intent before it dispatches external work. A communication
failure or unknown result is stored and reported by a later correlated Turn. It
does not roll back the macrostep. A retry keeps the same operation ID. Each
external target must use that ID for durable idempotency.

## Safety and lifecycle rules

- XML, Signal data, and stored state cannot select modules or create atoms.
- A trusted, versioned Registry provides expressions, Actions, targets, and
  invocation capabilities. Each session binds its Registry and limits digests.
- Runtime-owned Signals need a short-lived proof. Proof values and proof secrets
  are never public API and must not enter logs, diagnostics, traces, inspection,
  or persisted state.
- Completed sessions stay available for inspection. With `stop_on_done: true`,
  the Agent stops only after external and child cleanup is confirmed.
- SCXML invocation starts a local child statechart. The Jido invocation extension
  starts an allowlisted local Jido Agent. Depth, descendants, pending operations,
  retained terminal records, and runtime work are bounded.
- Checkpoints bind the chart fingerprint, runtime protocol, profile, data model,
  Registry manifest, limits, and duplicate-window contract. Incompatible state
  fails before runtime work starts.

See [Runtime](guides/runtime.md) for the complete commit, persistence, delivery,
cleanup, and child contracts.

## SCXML profile

The profile supports compound and parallel state, final state, shallow and deep
history, multi-target transitions, completion events, the null data model, the
restricted Jido data model, executable content, local sends, timers, and local
invocation. It does not evaluate `<script>`, ECMAScript, or XPath. It does not
fetch external data or content. It does not treat inline invoke content as an
executable SCXML document, and it does not implement the BasicHTTP or SCXML
Event I/O Processors or remote invocation. Invoke input stays ordered portable
metadata; it is not injected or filtered against a child SCXML top-level data
model. Generated invoke IDs and `_event` field names use documented Jido forms.

Selected unchanged W3C Implementation Report inputs provide profile evidence for
assertions 355, 403, and 436. The report states that it is interoperability
evidence, not a conformance test. See [SCXML profile](guides/scxml.md) and
[Verification](guides/verification.md).

## Guides and examples

- [Architecture and ownership](guides/architecture.md)
- [Semantic rules and limits](guides/semantics.md)
- [SCXML profile](guides/scxml.md)
- [Live runtime contract](guides/runtime.md)
- [Verification and W3C evidence](guides/verification.md)
- [Direct door example](examples/door.exs)
- [Direct and live parallel example](examples/parallel_approval.exs)

Library license: Apache-2.0. The selected W3C fixtures use BSD-3-Clause and
have their license notice in
`test/fixtures/w3c/LICENSE`.
