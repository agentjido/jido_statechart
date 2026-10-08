# W3C SCXML fixture snapshot

This directory contains an unchanged subset of the W3C SCXML 1.0
Implementation Report inputs. The upstream report version is 10 March 2015.
The snapshot date is 2026-10-07.

Upstream report: <https://www.w3.org/Voice/2013/scxml-irp/>

The W3C report says that its purpose is implementation and interoperability
evidence. It does not provide conformance testing. This package uses the files
as evidence for the Jido SCXML 1.0 Profile. It does not claim full W3C SCXML
processor conformance.

The `.txml` files include the upstream `conf` namespace. They are not changed
into Jido SCXML. The package harness runs equivalent profile-native cases and
keeps the upstream files only as fixed source evidence. `manifest.json` records
the upstream URL and SHA-256 digest for each copied input.

The copied inputs use the W3C 3-clause BSD license. The official W3C test-suite
license policy is at <https://www.w3.org/copyright/test-suites-licenses/>. The
license text is in `LICENSE`. Do not add a fixture without its upstream
metadata, digest, profile status, execution paths, and skip reason when it does
not run.

`manifest.json` records two different inventories:

- `official_ir_universe` records all 200 assertion rows in the official report.
  It includes the report URL, revision, byte count, and SHA-256 digest.
- `profile_scoped_inventory` classifies all 200 report assertions. The 16 C.1
  assertions and assertion 253 are explicit unsupported SCXML Event I/O
  Processor evidence, not exclusions or support claims.

Every profile-scoped assertion records its exact official abstract, direct or
related feature relation, and expected behavior. It is either `run` or
`skipped`. A skipped row has
one of the `manual`, `multi_session`, `timer`, `invocation`, `unsupported`, or
`deferred` categories and a reason. The smaller
`selected_assertion_inventory` identifies the three assertions and five cases
that the automated translated harness runs through pure, direct Flow, and live
Agent paths.

This classification is profile evidence. It is not full-suite coverage and it
is not a full W3C conformance claim. The executable harness is in test support
and is not part of the published library API. The packaged static capability
API is `Jido.Statechart.Profile.manifest/0`.
