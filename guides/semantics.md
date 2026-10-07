# Semantic Rules

## Configuration

A session configuration is an ordered set of active atomic or final state IDs.
It can contain one state for a compound branch and one state for each parallel
region. The compiler and session validator reject illegal configurations.

The profile supports atomic, compound, parallel, final, shallow-history, and
deep-history states. It supports explicit and default initial selection,
multi-target transitions across legal parallel regions, internal descendant
transitions, external transitions, and targetless transitions.

## Transition selection

For one event, the kernel finds enabled transitions from each active atomic
state toward its ancestors. A descendant transition has priority over an
ancestor transition. The kernel then removes conflicts and uses document order
to select the optimal enabled set.

XML event descriptors use case-sensitive dot tokens. `order` matches `order`
and `order.created`. `order.*` has the same prefix rule. `*` matches any named
event. A missing event means an eventless transition.

An unhandled external event returns a successful stable no-op. An unhandled
internal event, including an error event, is removed by the normal event rules.

## Microsteps and macrosteps

One microstep does this work in order:

1. Exit all states in exit order and run their exit content.
2. Run selected transition content in document order.
3. Enter all states in entry order and run entry and initial content.

A macrostep starts with initialization or one external event. It then takes all
enabled eventless transitions and processes internal events in FIFO order. It
stops when no eventless transition is enabled and the internal queue is empty.
It also stops with an error when a configured limit is reached.

Entering a final child adds `done.state.<parent-id>` to the internal queue.
Parallel completion occurs only after every region is final. Entering a
top-level final state completes the session and performs terminal exit. A
completed session has no active configuration.

## Data models and executable content

The null data model supports its SCXML restrictions and `In(state_id)`. It does
not provide application data or source evaluation.

The Jido data model uses portable values, trusted expression aliases, bounded
`Jido.Expr` values, string-keyed locations, and `In(state_id)`. It does not
evaluate Elixir, JavaScript, XPath, or other text as code.

The profile supports `datamodel`, `data`, `donedata`, `param`, `content`,
`raise`, `if`, `elseif`, `else`, `foreach`, `assign`, `log`, `send`, `cancel`,
`invoke`, `finalize`, entry content, exit content, transition content, initial
content, and history content. `<script>` is not supported.

An allowlisted Jido Action can run as executable content. It receives a minimal
package-owned context. It must return portable data and no effects, streams,
continuations, or opaque terms. The application must keep the Action
deterministic and bounded.

Authored expression and executable-content failures add `error.execution` when
the session is still valid. An invalid configuration, a contract mismatch, or
limit exhaustion is fatal for that macrostep.

## Direct result contract

`Jido.Statechart.initialize/3` and `step/4` run one atomic Flow execution. A
successful `Result` contains:

- the next stable session;
- ordered operation intent;
- a redacted deterministic trace;
- operation counts.

The direct path does not start external work. If the macrostep fails, it does
not return a partial result and it does not change the input session.

## Limits

`Jido.Statechart.Limits.bounds/0` is the authority for allowed values.
`Limits.default/0` returns the default contract. The session stores a digest of
this contract. A restore or execution with different limits fails.

| Limit | Default | Hard maximum |
| --- | ---: | ---: |
| XML bytes | 1,048,576 | 16,777,216 |
| XML depth | 64 | 256 |
| XML attributes per element | 64 | 512 |
| XML nodes | 10,000 | 100,000 |
| XML text bytes | 1,048,576 | 8,388,608 |
| Expression steps | 10,000 | 1,000,000 |
| Microsteps per macrostep | 1,000 | 10,000 |
| Internal queued events | 10,000 | 100,000 |
| Trace entries | 10,000 | 100,000 |
| Data bytes | 1,048,576 | 16,777,216 |
| External intent | 1,000 | 10,000 |
| Timer horizon in milliseconds | 2,678,400,000 | 31,536,000,000 |
| Invocation depth | 16 | 64 |
| Total descendants | 1,000 | 100,000 |
| Pending sends | 1,000 | 100,000 |
| Pending timers | 1,000 | 100,000 |
| Pending invocations | 1,000 | 100,000 |
| Retained terminal records | 10,000 | 1,000,000 |
| Session bytes | 8,388,608 | 134,217,728 |
| Reconciliation batch | 100 | 10,000 |
| Runtime concurrency | 64 | 10,000 |
| Runtime-generated Turns per minute | 1,000 | 1,000,000 |

The Plugin also bounds its duplicate window to 1 through 100,000 IDs, its
reconciliation interval to 10 through 60,000 milliseconds, its retry count to
1 through 100, and its initial retry delay to 1 through 60,000 milliseconds.

Limits count package work. They cannot prove that trusted application code will
terminate. Application Actions and capability adapters must have their own time
and resource policy.
