# Execution Rules

## Definition input

A chart has `id`, `version`, `initial`, `states`, and optional `limits` fields.
The default version is `"1"`. States form a flat list with explicit parent IDs.
Top-level states have no parent. The chart initial ID must name a top-level
state. A compound state must name one immediate child as its initial state.

A state has `id`, `parent`, `type`, `initial`, `entry`, `exit`, and `transitions`
fields. The default type is `atomic`. Supported types are `atomic`, `compound`,
and `final`. Atomic and final states have no children. Final states have no
transitions. Final entry and exit actions are permitted.

A transition has `event`, `target`, `guard`, `actions`, `priority`, and `kind`
fields. A missing event means an eventless transition. A missing target means
an action-only transition. The default priority is 0. It must be an integer
from -1,000,000 through 1,000,000. The default kind is `external`.

Actions use one of these forms:

```elixir
"reducer-id"
%{id: "reducer-id", params: %{...}}
%{raise: "internal-event-id", data: %{...}}
%{effect: "effect-id", data: %{...}}
```

Action parameters and request data must be bounded plain maps. Guards use
trusted IDs. There is no string expression evaluator.

## Transition selection

1. Search from the active leaf toward the root.
2. At each source, inspect matching transitions in descending priority order.
3. Use declaration order when priorities are equal.
4. Select the first transition whose guard returns `true`.
5. Search the parent when no transition at that source is enabled.

A deeper enabled source wins over an ancestor, even when the ancestor has a
higher priority. Events match complete strings. There are no wildcards,
prefix matches, or space-separated event lists.

An unhandled external event fails the macrostep. An unhandled internal event
is removed from the queue and recorded in the trace.

## Exit and entry

An external transition exits states from leaf toward its transition boundary.
Exit actions run before transition actions. Entry then runs from the boundary
toward the target, followed by explicit initial descendants.

The boundary is the least common ancestor that is a proper ancestor of both
source and target. When source and target are in separate top-level states,
the boundary is outside the chart. An external self transition exits and
reenters the source. A transition to an ancestor exits and reenters that
ancestor, then follows its initial state.

An internal targeted transition must have a compound source and a strict
descendant target. It retains the source and replaces its active descendants.
A targetless transition retains the whole active path and runs only its actions.

When a final state with a parent is entered, the engine raises
`done.state.<parent-id>`. That event uses the normal internal queue. A top-level
final state marks the chart `done`. A nested final state completes its parent;
it does not mark the whole chart done. No automatic transition is added to a
completed compound state.

External input and authored raise actions cannot use reserved completion names
or names beginning with `$`. Internal lifecycle events use those names.
Trusted reducer callbacks can return internal Event values.

## Run to completion

Initialization enters the chart initial path and settles it. For one external
event, the engine applies its selected transition and then repeats these steps:

1. Take an enabled eventless transition, if present.
2. Otherwise take the next internal event in FIFO order.
3. Stop when no eventless transition is enabled and the queue is empty.

Eventless guards and reducers receive the most recently processed event.
Initialization uses the internal `$init` event. Queued events retain their own
data. Actions append raised events to the queue in action order.

A stable result contains no queued internal event. The trace is deterministic
for the same definition, data, external event, and trusted callback behavior.
It omits domain payloads and records state, action, guard, event, and effect IDs.

The engine builds all changes in a local candidate. If any limit, guard,
reducer, request, or validation fails, it returns `{:error, %Error{...}}`.
The input instance remains unchanged. It does not return partial effects.

## Fixed limits

Definitions can lower these limits. They cannot raise them or supply duplicate
field aliases.

| Field | Maximum | Bounds |
| --- | ---: | --- |
| `states` | 512 | Defined states |
| `depth` | 32 | State hierarchy depth |
| `active_states` | 32 | Active path length |
| `transitions` | 4,096 | Defined transitions and transitions in one macrostep |
| `actions_per_list` | 256 | Entry, exit, or transition action list |
| `action_calls` | 512 | Reducer and built-in action calls; total effects |
| `internal_events` | 128 | Raised events per macrostep, including completion events |
| `macrostep` | 1,024 | Interpreter work operations |
| `expression_bytes` | 4,096 | UTF-8 bytes in each identity or behavior reference |
| `definition_bytes` | 1,048,576 | External-term size of authoring data and normalized data |
| `data_nodes` | 65,536 | Nodes in each data value |
| `data_bytes` | 1,048,576 | Scalar bytes in each data value |

Data nesting is limited to 64 levels. Integers must fit in a signed 64-bit
value. Data accepts strings, floats, integers, fixed atoms, plain maps with
string or atom keys, and proper lists. It rejects functions, processes,
references, ports, structs, tuples, and non-byte bitstrings. Use strings for
names that can be introduced by external data. Fixed application atoms are
accepted but can require trusted modules to be loaded on another BEAM node.

Work counts include state searches, transition inspections, guard calls,
transition execution, entry, exit, actions, requests, and internal queue
consumption. Traces, effect lists, and queues are bounded by those counts.
Definition validation has separate structural and data bounds.

A budget counts engine work. It cannot count instructions inside a trusted
callback. Application callbacks and Directive builders must terminate within
the application's execution policy. The pure API has no wall-clock scheduler.
Jido execution timeout and cancellation policy apply when running a Turn.

`Result.stats` exposes work, transition, guard, action, internal-event, and
effect counts. A failure identifies its limit in `Error.details` when the
failure occurs during interpretation.
