# Verification

Verified on 2026-10-06 with Elixir 1.20.4 and OTP 29. The tested source commits
are listed in the architecture guide.

| Check | Result |
| --- | --- |
| `mix deps.get` | Pass with the shared local Zoi override |
| `mix format --check-formatted` | Pass |
| `mix compile --warnings-as-errors` | Pass for the package |
| `mix quality` | Pass; includes format, compile, and test checks |
| `mix test --cover --warnings-as-errors --seed 0` | Pass: 45 total cases, 42 tests and 3 properties |
| Line coverage | 96.75%; required threshold: 90% |
| `mix docs --warnings-as-errors` | Pass |
| `mix run examples/door.exs` | Pass; state and checkpoint assertions pass |
| `mix run examples/approval.exs` | Pass; guard, completion, final state, and Directive assertions pass |
| `mix xref graph --format cycles` | Pass; no cycles |
| `git diff --check` | Pass |

The deterministic trace fixture covers compound exit and entry order,
eventless transitions, raised events, completion, and effects. Property tests
compare flat cycles with a separate reference model, restore checkpoints at
every step, check arbitrary malformed terms, and check bounded termination.

Live integration tests check one committed revision per Signal, post-commit
Signal dispatch, failed candidate rollback, invalid effect rejection,
fingerprint mismatch rejection, checkpoint restore, and abnormal local restart.
They also check that Signal payloads cannot replace trusted behavior.

Input tests check unknown and duplicate fields, bad references, hierarchy
cycles, malformed initial states, unsupported state kinds, improper lists,
unsafe runtime terms, fixed limits, bounded request batches, and external
string identities that never enter the atom table.

The first dependency compilation emitted warnings from third-party packages.
The package compile and test checks pass with warnings as errors. No dependency
source was changed to remove its warnings.

## Verification limits

The minimum Elixir 1.18 environment has not been tested. The two local Jido and
Action source commits are not yet public upstream commits, so the manual public
CI workflow has not run against those exact sources. Supply compatible published
commit refs when that source becomes available. The package is not published to
Hex and retains local development dependencies.

There are no parallel, history, or SCXML conformance tests because those features
are explicitly unsupported. Callback purity and termination are application
contracts. The engine bounds calls and checks results; arbitrary callback code
cannot be proven pure by these tests.
