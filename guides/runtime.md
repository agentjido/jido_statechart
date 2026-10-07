# Live Runtime Contract

This guide applies to a Statechart that runs in `Jido.AgentServer` with
`Jido.Statechart.Plugin`. It does not apply to the direct Flow API.

## Start and initialize

Start a normal Jido instance and Agent. Then initialize the Statechart before
you send a business Signal.

```elixir
{:ok, _jido} = Jido.start_link(name: :orders, namespace: "orders")
{:ok, server} = Jido.start_agent(:orders, MyApp.OrderAgent, id: "order-42")
{:ok, _agent} = Jido.Statechart.Agent.initialize(server)
```

Initialization is a reserved authenticated Turn. It creates the session, enters
the initial configuration, runs initial stabilization, and commits the result.
A normal business Signal cannot initialize a live session.

## Input identity and duplicate window

The adapter maps `signal.type` to the SCXML event name. It keeps `signal.id` as
the transport message identity. It also preserves applicable source, data,
origin type, SCXML send ID, invocation ID, Turn ID, event class, and session ID.

Input is at least once. The Plugin stores recent external Signal IDs in a
committed FIFO duplicate window. A duplicate inside the window does not run the
macrostep again. The default window is 1,024 IDs. The allowed range is 1 through
100,000. An old ID can run again after it leaves the window.

The window is local duplicate suppression. It is not a permanent idempotency
record and it does not give exactly-once input.

## Commit and dispatch

A live macrostep creates immutable operation records for external sends, delayed
sends, cancellation, invocation, and child control. These records are part of
the Agent candidate.

Jido validates and commits the candidate before the Plugin runtime starts the
external work. Therefore:

- a failed Agent commit starts no new external work;
- external success cannot make an uncommitted session authoritative;
- an external failure does not roll back the committed macrostep;
- delivery and child results arrive as later correlated Signals and later Turns.

The runtime first commits an attempt state. It then dispatches the work. A
confirmed result, retryable failure, permanent failure, or unknown result is
committed by a later Turn.

## Unknown outcomes and reconciliation

A timeout, process exit, adapter exception, or ambiguous error can leave the
external result unknown. Unknown does not mean that the target did no work.

The runtime keeps the original immutable operation ID and reconciles the same
logical operation after startup, after commit, and at a bounded interval. It
does not create a new logical delivery ID for a retry. A target that declares
at-least-once delivery must keep a durable idempotency record for this operation
ID.

The committed ledger is the authority. Runtime task state and wake-up messages
are only an execution aid. A lost wake-up or runtime restart cannot remove
committed work.

## Timers and cancellation

A delayed send stores an absolute UTC due time and a generation. A process timer
reference is not persisted. Restore reconciliation schedules future work and
handles overdue work.

Replacement and cancellation use generation high-water marks. A late timer or a
late result from an older generation cannot act on the current operation.
Cancellation can also have an unknown result and is reconciled from committed
state.

## Runtime Signal authentication

The Plugin reserves these Signal types:

- `jido.statechart.initialize`;
- `jido.statechart.cleanup.confirmed`;
- `jido.statechart.timer`;
- `jido.statechart.delivery`;
- `jido.statechart.child`;
- `jido.statechart.reconcile`.

The runtime also handles Jido child lifecycle Signals. Application routes must
not use these reserved types.

Each runtime-owned Signal needs a short-lived proof before route execution. The
proof is bound to the Agent, session incarnation, operation, generation, event
type, payload, and current runtime epoch. A missing, stale, cross-Agent,
cross-operation, or changed-payload proof fails admission.

Proof values, proof secrets, and their private Signal context fields are not
public API. Do not persist, log, inspect, copy, or construct them. The runtime
rotates its secret material when it restarts. Public inspection and persistence
contain no proof material.

## Persistence

The Statechart Plugin persistence envelope binds:

- checkpoint and session schema versions;
- runtime protocol version;
- profile and data model versions;
- Registry version, manifest, and digest;
- limits version, values, and digest;
- chart fingerprint;
- duplicate-window size;
- the portable session and recent Signal IDs.

Restore validates this contract before runtime startup. A known old checkpoint
can use an explicit package migration. An unknown version, unknown field, or
contract mismatch fails. Restore does not replay entry content or external
work. Reconciliation continues the committed ledger.

If persistence reports an indeterminate write, the old Agent activation stops
and dispatches no new Statechart work. A later load from the persistence store
decides which revision is authoritative. The application must not treat the old
in-memory candidate as committed.

## Completion and cleanup

A completed session remains committed and inspectable. By default, the Agent
continues to run with this completed session.

With `stop_on_done: true`, the runtime waits until sends, timers, cancellation,
invocation, and child cleanup have a confirmed terminal record. It then sends a
later authenticated cleanup Turn. Only that Turn changes the session to stopped
and asks AgentServer to stop.

An unknown child or delivery outcome can delay cleanup. The package does not
guess that an external resource is absent. The application owns abandonment,
manual repair, data retention, and operator escalation policy.

## Child lifecycle

Standard SCXML invocation starts a local child statechart session. The Jido
invocation extension starts an allowlisted local Jido Agent capability. XML and
Signal data cannot select a module.

Child start and stop occur after the parent commit. Later authenticated control
Turns record start, result, stop, and failure. Finalize content runs before
transition selection for a matching child event. Autoforward occurs before a
same-Turn state-exit stop request.

The session binds child operations to invocation ID, generation, parent
incarnation, and ancestry. It rejects stale results, direct recursion, mutual
recursion, depth exhaustion, and descendant-budget exhaustion. If a child start
result is unknown, reconciliation uses the same logical child identity and does
not assume that no child exists.

## Operational limits

`Jido.Statechart.Limits` bounds pending work by type, retained terminal records,
session bytes, timer horizon, invocation depth, total descendants,
reconciliation batch size, runtime concurrency, and runtime-generated Turns.
The Plugin also bounds retries and the reconciliation interval.

Use `Jido.Statechart.inspect_session/1` for safe stable state. It reports active
configuration, history, completion state, trace size, and pending operation IDs.
It does not report payloads, runtime handles, or proof material.
