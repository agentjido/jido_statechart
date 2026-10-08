# Verification

## Local result

The U9 verification run used Elixir 1.20.4 on OTP 29 and the exact local V3
source matrix in [Architecture](architecture.md). The Elixir build reports that
it was compiled with OTP 28. The GitHub job is set to OTP 29.

| Check | Result on 2026-10-07 |
| --- | --- |
| `mix deps.get` | Pass with local sibling paths |
| `mix format --check-formatted` | Pass |
| `mix compile --warnings-as-errors` | Pass |
| `mix test --warnings-as-errors --seed 0` | Pass: 292 cases; 286 tests and 6 properties |
| `mix test test/system --warnings-as-errors --seed 0` | Pass: 20 tests |
| `mix test --cover --warnings-as-errors --seed 0` | Pass: >=90% |
| `mix docs --warnings-as-errors` | Pass |
| `mix run examples/door.exs` | Pass |
| `mix run examples/parallel_approval.exs` | Pass for direct and live sessions |
| `mix xref graph --format cycles --label compile-connected` | Pass; no cycles |
| `mix quality` | Pass |
| `git diff --check` | Pass |
| `JIDO_STATECHART_HEX_GATE=1 mix hex.build` | Pass in an isolated copy; required files and the W3C license are present |

The separate published Hex dependency and package job is a pre-release gate. A
local-path result does not satisfy it. `mix hex.build` correctly rejects the
local path graph because Hex packages cannot contain path dependencies.

The published gate currently stops during dependency compilation. It resolves
`jido_action` 3.0.0-beta.12 and `zoi` 0.18.11 from Hex, but that Jido Action
release uses `Zoi.Types.Default`, which is not in the published Zoi release.
The local Zoi checkout contains the required V3 contract. A compatible Zoi and
Jido Action combination must be published before release.

## Profile evidence model

`Jido.Statechart.Profile.features/0` contains each public feature row. Each row
has one of these statuses: `supported`, `unsupported`, `deviation`, or
`not_applicable`. It also has a W3C section where one applies, applicable
official IR assertion IDs, a stable evidence key, and a reason for each unsupported or
deviation row.

`Jido.Statechart.Profile.manifest/0` is the packaged static profile API.
`Jido.Statechart.Conformance` is test support only. It joins profile rows to
exact test IDs and expected behavior. It is not compiled into the published
library. The test verifies that every public row has an evidence key and an
exact regression. It also verifies that every deviation has an explicit
registered regression.

Important evidence groups are:

| Claim group | Main evidence |
| --- | --- |
| Parser and restricted XML | `scxml/parser_test.exs`, `scxml/security_test.exs`, and validation tests |
| Parallel and transition selection | `semantics/parallel_test.exs` and transition selection tests |
| History | `semantics/history_test.exs` |
| Macrostep order and completion | macrostep and completion tests |
| Executable content and data models | executable content and data model tests |
| Direct Flow | Flow, chart, and Flow extension tests |
| Live Agent and Plugin | Agent, Plugin, and system session tests |
| Sends, timers, and reconciliation | runtime tests and `recoverable_send_test.exs` |
| Invocation and children | invocation runtime and system tests |
| Persistence contract | Plugin tests and frozen checkpoint fixtures |
| Disclosure control | `disclosure_test.exs` and runtime proof system tests |

## Selected W3C evidence

The package uses the official
[W3C SCXML Implementation Report](https://www.w3.org/Voice/2013/scxml-irp/),
version 10 March 2015. The report says that conformance testing is not one of
its goals. This package therefore reports profile evidence and does not report a
full W3C conformance result.

The fixed fixture snapshot contains unchanged upstream `.txml` files:

| Assertion | Input | SHA-256 |
| --- | --- | --- |
| 355 | `355/test355.txml` | `ea0c10c389365eeccc99eea293e88a575b6d7d52a9a563a29ff99007a10be3f7` |
| 403 | `403/test403a.txml` | `2d7e031e8806d857ddd68d56800734a4fad01040e737f4f6261cb17d4f0421d4` |
| 403 | `403/test403b.txml` | `cc63512c5f18907c2de0199742c74166d6e8ef8f89a0167ab31128f3187624e0` |
| 403 | `403/test403c.txml` | `24ea2011eb60435431903c6091b4d29800a9f73b9ce7614c599b68106c5f80fd` |
| 436 | `436/test436.txml` | `10537e6b4e9463b1f0f5cb2bb078bca167b3ee3b883959aa6e292ad193e5416d` |

Assertion 355 checks the default first state when the root has no `initial`
attribute. Assertion 403 checks optimal transition selection, descendant
priority, conflict preemption, and document order. Assertion 436 checks the
null data model `In` predicate for active and inactive states. The harness
checks every declared branch through the pure kernel, direct Flow, and live
Agent paths.

The upstream files contain abstract `conf` markup. The package does not change
them into Jido input. It runs equivalent profile-native charts and keeps the
original bytes as source evidence.

`test/fixtures/w3c/manifest.json` records the 200-row official IR universe and
its source digest. Its closed profile-scoped inventory classifies all 200
assertions as run or skipped. The C.1 assertions and assertion 253 are explicit
unsupported SCXML Event I/O Processor evidence. Each row records the exact
official abstract and direct or related feature links. Each skip has a category
and a nonempty reason. A separate selected-run inventory records the three
assertions and five cases that the translated harness runs. These inventories
are profile evidence, not a full W3C conformance claim.

The snapshot uses the official W3C 3-clause BSD license. Its license file is
included in package files.

## Disclosure evidence

The disclosure suite places marker secrets and terminal control characters in:

- hostile XML element names;
- Signal data;
- Action errors and Action context;
- runtime adapter errors and result values.

It verifies that normal diagnostics, traces, inspection, log output, and safe
`inspect/1` output contain none of these values. System tests also verify that
runtime proof material is absent from committed state and persistence.

## Verification limits

- Trusted application Actions and adapters can contain arbitrary code. The
  package bounds calls and validates results, but it cannot prove that this code
  is pure or terminating.
- The minimum Elixir 1.18 environment still needs a dedicated run.
- The published Hex dependency gate must pass before release. It is currently
  blocked by the published Jido Action and Zoi contract mismatch described
  above. The default local dependency gate is not a substitute.
- The selected-run W3C assertions are a fixed evidence subset. The classified
  profile scope is not a full W3C test-suite run and does not create a processor
  conformance claim.
