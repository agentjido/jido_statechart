# Architecture

## Ownership

| Layer | Owns |
| --- | --- |
| `jido_statechart` | Chart definition, validation, configuration, interpretation, and effect requests |
| `jido_action` | Executable Action contract and in-memory execution |
| `jido_signal` | Signal envelope, routing, serialization, and dispatch |
| `jido` | Agent state validation, Turns, Directives, AgentServer, commits, persistence, and restart |
| Jidoka | Product authoring, user interfaces, storage policy, and deployment above Jido |
| DASP | Protocol messages and protocol conformance |

A statechart is behavior within an Agent. It is not a durable orchestration
service or a distributed protocol. Jidoka can author charts through the data
compiler. DASP can deliver events through an application adapter. Neither
product nor protocol changes are required by this package.

## XML adapter

`Jido.Statechart.SCXML` is an optional input edge. It uses a bounded SAX handler
with Saxy, validates a restricted SCXML profile, and calls the data compiler.
It does not load resources or evaluate expressions. XML Agent declarations
compile at module compile time. The runtime and checkpoint path use only the
normalized definition. The SCXML guide defines the exact supported subset.

## Core model

The compiler produces a `Definition` with a map of `State` values, ordered
`Transition` values, fixed limits, and a SHA-256 fingerprint. Compilation runs
no application callback. The definition has no process or runtime resource.

An `Instance` holds domain data and a `Configuration`. The active configuration
is one ordered path. An `Event` supplies an exact string identity and bounded
data. A `Result` supplies the complete stable candidate, ordered effects, trace,
and operation counts.

The interpreter uses local immutable values. It does not start processes,
read a clock, generate IDs, or dispatch requests. Guards and reducers come
from a separate trusted `Registry`. The application owns callback purity and
the version of those callbacks.

The public validator checks normalized structure and fingerprints. It limits
malformed normalized values before it reconstructs authoring data. Compilation
rejects unknown fields instead of silently removing them.

## Jido integration

The Agent DSL generates a neutral `Jido.Agent` definition and the ordinary
module configuration convention used by Jido. `Jido.Statechart.Agent.build/5` provides the same
integration for data authoring. The static metadata holds the compiled chart,
trusted Registry, and trusted effect builders. Mutable state has `:chart` and
`:data` fields.

`handle_signal/2` creates one bound Turn for `Jido.Statechart.Step`. It builds
the Step input from trusted metadata and the validated Signal. Signal data is
never merged into the trusted input. The Step reads current `agent_state` from
Jido's reserved execution context. It returns the complete next state and one
ordered Directive batch. Existing combined state fields remain in the result.

The Agent schema checks the active path, state status, fingerprint, bounded
domain data, and application domain schema. Jido also applies its standard
candidate and Directive validation. Failed work returns no candidate batch.

Jido owns the live commit boundary. A direct `Jido.Agent.cmd/3` returns a candidate
and Directives. AgentServer validates, persists, commits, and dispatches through
its normal pipeline. There is no replacement Server, alternate executor, or
package-owned supervision tree.

## Initialization and recovery

An Agent starts with status `"new"`. On its first Signal, the Step runs initial
entry and stabilization, then the external event. Both phases share the same
limits. This avoids running callbacks during definition construction and keeps
initialization effects inside the first state commit.

Core and Agent checkpoints store mutable state and fingerprints. They exclude
callbacks and compiled executable behavior. A DSL Agent restores from its
current module definition. A generic data-built Agent must receive a trusted
Agent definition through restore context. Automatic runtime persistence should
use an application module with a stable definition and restore callback.

Restore validates compatibility and state. It does not replay entry actions or
effects. Jido local abnormal restart keeps the committed Agent and revision.
This package adds no effect journal, deduplication service, or delivery guarantee.

Use Jido persistence and recoverable effect facilities when a request must
survive a process or node failure. The application must supply idempotency keys
and reconcile uncertain external results. A Directive failure after commit
cannot undo the committed state.

A fingerprint includes chart structure, ordered behavior IDs, static action
parameters, limits, and the chart version. It excludes callback implementation
code. Update the chart version when callbacks change. Jido Agent `vsn` also
protects the application schema and checkpoint format.

## Tested source versions

These checkouts were used on 2026-10-06. All use V3 package versions. They are
separate repositories.

| Source | Commit | Package version |
| --- | --- | --- |
| `jido` | `8322de574c53d5c2096243d230c9de4f14803bda` | `3.0.0-beta.1` |
| `jido_action` | `44893a606d276968c50924ee9ef60fc6a4e0c411` | `3.0.0-beta.1` |
| `jido_signal` | `afc4c5c58e10db1be611c2a846c1d43b5a9ec1dc` | `3.0.0-beta.4` |
| `zoi` | `2fff2a23e23e7ac0b26f62f49bbc1b12f7818ac9` | `0.18.11` |

The local Jido and Action commits are not yet in their public upstream
repositories. Signal and the Zoi fork commits are public. No sibling source
was copied into this package. The local path dependencies intentionally retain
the tested contracts. Replace them with published compatible sources before
release to Hex.

The host used Elixir 1.20.4 and OTP 29. The minimum supported Elixir requirement
is 1.18, which matches the current Jido V3 packages. This work did not test the
minimum-version environment.
