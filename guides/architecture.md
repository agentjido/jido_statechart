# Architecture

## Package ownership

| Package | Ownership |
| --- | --- |
| `jido_statechart` | SCXML input, normalized charts, semantic execution, session operations, and the Statechart Plugin |
| `jido_action` | Actions, Flow definitions, `Jido.Exec`, and in-memory execution |
| `jido_signal` | Signal values, routing, serialization, dispatch, and the local bus |
| `jido` | Agents, AgentServer, Plugins, Turns, commit, persistence, and supervision |

The package does not replace AgentServer. It does not own a distributed work
queue. A statechart is one part of an Agent. An application owns product policy,
storage selection, external adapters, and abandonment policy.

## Compile boundary

`Jido.Statechart.SCXML` accepts XML bytes that the caller already owns. It uses
a bounded SAX handler. It does not read a file, open a URL, load a schema,
resolve an external entity, or evaluate source text. The compiler validates the
Jido SCXML 1.0 Profile and returns an immutable `Model.Chart`.

The chart contains document-order indexes, source paths, a profile version, and
a deterministic fingerprint. XML text cannot create atoms, select a module, or
install a capability.

A `Registry` is trusted application input. It gives typed aliases for
expressions, Actions, targets, and invocation types. Its portable manifest does
not contain handlers. A session binds the Registry version and digest.

## Semantic kernel and Flow

The semantic kernel uses immutable values. It selects an optimal transition set,
plans exits and entries, runs executable content, processes the internal FIFO
queue, and stops at a stable configuration. All ordering is explicit.

`Jido.Statechart.Flow` is the canonical direct execution path. It has three
stages:

1. Prepare and validate the chart, session, Registry, event, and limits.
2. Iterate through bounded semantic microsteps.
3. Return one stable `Result`.

Registered Jido Actions run through `Jido.Exec` with a package-owned minimal
context. A Statechart Action cannot return effects, a stream, an opaque value, or
a continuation during a microstep.

The direct path produces intent records. It does not dispatch them. The caller
owns any later use of those records.

## Live Agent path

`Jido.Statechart.Chart` binds one normalized chart and one Registry to a module.
`Jido.Statechart.Agent.Extension` binds one such chart module to an ordinary
Jido Agent route. It also installs one `Jido.Statechart.Plugin` instance.

The Plugin owns one portable session in Agent state. It is the only live write
path for that session. The route runs the same Statechart Flow as the direct
API. The Plugin then reduces one package commit directive. Jido validates and
commits the whole Agent candidate before the Plugin runtime starts external
work.

The supervised Plugin runtime owns process IDs, task references, timer
references, child handles, runtime proof secrets, and the current proof epoch.
These values never enter committed Agent state.

## State and inspection

`Jido.Statechart.inspect_chart/1` returns safe chart identity and size data.
`Jido.Statechart.inspect_session/1` returns stable session identity,
configuration, history, status, counters, trace size, and pending operation IDs.
It does not return operation payloads or runtime proof material.

Session traces contain identifiers and execution order. They do not contain
Signal data, Action context, result payloads, or proof values. Diagnostics use
stable codes, bounded paths, profile features, and redacted correction data.

## Recovery model

The committed session operation ledger is the source of truth for sends, timers,
cancellation, invocation, and child control. The runtime reconciles this ledger
after commit, after startup, and at a bounded interval.

A dispatch attempt is committed before external dispatch. The result is stored
by a later authenticated Turn. A process crash or lost wake-up cannot delete the
committed intent. An uncertain result keeps the same immutable operation ID for
later reconciliation.

See [Runtime](runtime.md) for persistence, delivery, cleanup, and child rules.

## Tested V3 source matrix

These separate repositories were tested together on 2026-10-07.

| Source | Branch | Commit | Package version |
| --- | --- | --- | --- |
| `jido` | `release/v3` | `8322de574c53d5c2096243d230c9de4f14803bda` | `3.0.0-beta.1` |
| `jido_action` | `release/v3` | `65330e3dfcaae570bc87f570a9c815f52ec2d872` | `3.0.0-beta.12` |
| `jido_signal` | `release/v3` | `fd8d00555d6a64b4109619f4c26f1b75e8a91d41` | `3.0.0-beta.4` |
| `zoi` | `jido/v3-minimal` | `2fff2a23e23e7ac0b26f62f49bbc1b12f7818ac9` | `0.18.11` |

The default `mix.exs` dependencies remain local sibling paths during V3
integration. The local CI job checks these exact commits. The separate Hex gate
uses published version requirements and builds the package. Both modes must pass
before release.

The verification host uses Elixir 1.20.4 and OTP 29. The package requirement is
Elixir 1.18 or later. The minimum version still needs its own CI run.
