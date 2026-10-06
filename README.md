# Jido Statechart

A first-party statechart package for Jido V3. The engine computes one complete,
stable candidate for each external event. Jido owns the state commit and the
execution of post-commit Directives.

This package uses the current local V3 checkouts. It is an initial development
release. It is not yet a Hex release.

## Supported behavior

- Atomic, compound, and final states with stable string IDs.
- Explicit initial states and one active path from root to leaf.
- Guarded transitions, entry actions, exit actions, and transition actions.
- External, internal descendant, and targetless transitions.
- Exact event identities, eventless transitions, and FIFO internal events.
- Compound completion events named `done.state.<state-id>`.
- Deterministic transition priority, traces, and execution counts.
- Fixed upper limits, typed errors, and atomic failure of a macrostep.
- Pure application guards and reducers selected through trusted string IDs.
- Explicit effect requests and trusted builders for Jido Directives.
- One generic Step Action, normal Jido Agent definitions, and compatible
  checkpoints with definition fingerprints.
- An Elixir DSL and a data compiler that produce the same normalized model.

Parallel states, history states, SCXML input, expression languages, timers,
invoked services, and W3C conformance are outside this release. Unknown fields
and unsupported state kinds cause a compile error. See
[the SCXML boundary](guides/scxml.md).

## Local installation

Keep this repository beside `jido`, `jido_action`, `jido_signal`, and `zoi`.
The local Jido checkout uses changes to Zoi state validation. This package
selects that same Zoi source to prevent a dependency conflict.

```sh
cd jido_statechart
mix deps.get
mix quality
mix test --cover --warnings-as-errors
mix docs --warnings-as-errors
```

See [the tested source versions](guides/architecture.md#tested-source-versions).
Current Jido and Action commits are local and have not reached the public
upstream repositories. Public CI must use published commits that contain the
same V3 contracts. The manual CI workflow takes those commit refs as inputs.

Before a Hex release, select published compatible V3 dependencies, replace the
local paths with normal version requirements, and repeat the integration checks.

## Pure data API

```elixir
alias Jido.Statechart
alias Jido.Statechart.Event

chart = Statechart.compile!(%{
  id: "door",
  initial: "closed",
  states: [
    %{id: "closed", transitions: [%{event: "open", target: "opened"}]},
    %{id: "opened", transitions: [%{event: "close", target: "closed"}]}
  ]
})

{:ok, start} = Statechart.init(chart)
{:ok, event} = Event.new("open")
{:ok, result} = Statechart.step(chart, start.instance, event)
result.instance.configuration.active
# => ["opened"]
```

The compiler accepts known field names as fixed atoms or strings. State,
event, guard, reducer, and effect IDs must be strings. External input cannot
create atoms, select modules, or supply executable code.

## Jido Agent DSL

```elixir
defmodule MyApp.Door do
  use Jido.Statechart.Agent, name: "door"

  statechart id: "door", version: "1", initial: "closed" do
    state "closed" do
      transition "open", target: "opened"
    end

    state "opened" do
      transition "close", target: "closed"
    end
  end
end

agent = MyApp.Door.new!()
signal = Jido.Signal.new!("open", %{}, source: "/example")
{:ok, candidate, []} = MyApp.Door.cmd(agent, signal)
```

`new/1` creates an ordinary Jido Agent with a `"new"` chart configuration.
The first Signal runs initial entry actions and initialization transitions
before its external event. All work uses one macrostep budget and one Turn.
Initialization effects are returned with the Turn. A failed first event
leaves the Agent uninitialized.

To run the same Agent in OTP, start a normal Jido instance and use
`Jido.start_agent/3` and `Jido.AgentServer.call/3`. This package does not
implement another AgentServer.

## Trusted behavior

A guard has arity 2: `(data, event) -> boolean`. A reducer has arity 3:
`(data, event, params) -> {:ok, next_data}`. A reducer can also return
`{:ok, next_data, requests}`. Requests must be internal `Event` values or
`Effect` values.

```elixir
def registry do
  %Jido.Statechart.Registry{
    guards: %{"allowed" => fn data, _event -> data["allowed"] == true end},
    reducers: %{
      "count" => fn data, _event, _params ->
        {:ok, Map.update(data, "count", 1, &(&1 + 1))}
      end
    }
  }
end
```

Declare this function inside an Agent module to replace its empty registry.
Use `guard: "allowed"` and `actions: ["count"]` in transitions.

Callbacks must be pure, deterministic, and bounded. They must not use network
calls, files, time, randomness, process messages, or external writes. The engine
checks callback results and call counts. It cannot prove purity or stop an
infinite loop inside application code. Use Jido execution timeouts for the live
runtime, and use only trusted bounded callbacks in the pure API.

## Effects and checkpoints

`%{effect: "notify", data: %{...}}` produces an explicit effect request.
An Agent defines `effects/0` as a map of string IDs to pure builders. Each builder
receives one `Jido.Statechart.Effect` and returns `{:ok, directive}`. Jido
validates the Directive before commit and dispatches it after commit. A missing
or invalid builder fails the Turn. See [the example](examples/approval.exs).

Use `Jido.Agent.checkpoint/2` and `Jido.Agent.restore/3` for DSL Agents.
The stored payload contains mutable state and its fingerprint. Restore uses
the current application module and does not run chart actions.

Use `Jido.Statechart.Checkpoint.dump/2` and `load/2` for pure instances.
For a data-built generic Agent, pass its trusted Agent definition explicitly:

```elixir
{:ok, checkpoint} = Jido.Agent.checkpoint(agent)
{:ok, restored} = Jido.Agent.restore(Jido.Statechart.Agent, checkpoint, %{
  statechart_definition: trusted_agent_definition
})
```

A generic data-built Agent needs that context for restore. Use the DSL or an
application-owned behavior module for automatic Server persistence. Stored
data never supplies an executable module or behavior registry.

Change the chart `version` when application callback behavior changes. Change
the Agent `vsn` when its state schema or checkpoint contract changes. A hash of
structural data cannot detect an application code change with the same IDs.
Fingerprints check compatibility. They are not a signature or an authorization
mechanism.

## Guides

- [Architecture and package boundaries](guides/architecture.md)
- [Execution rules, data model, and limits](guides/semantics.md)
- [SCXML boundary and follow-up scope](guides/scxml.md)
- [Contribution](CONTRIBUTING.md)
- [Verification results](guides/verification.md)

License: Apache-2.0. See [LICENSE](LICENSE).
