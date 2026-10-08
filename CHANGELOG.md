# Changelog

## 0.3.0 — 2026-10-07

- Add the Jido SCXML 1.0 Profile and its machine-readable capability manifest.
- Add bounded secure SCXML parsing and immutable normalized chart values.
- Support compound, parallel, final, shallow-history, and deep-history states.
- Add optimal transition selection, multi-target transitions, completion events,
  executable content, the null data model, and the restricted Jido data model.
- Add one canonical bounded `Jido.Statechart.Flow` for direct execution.
- Add chart modules and the Statechart Agent extension for ordinary Jido Agents.
- Require explicit authenticated initialization for live sessions.
- Add a committed operation ledger, post-commit sends and timers, cancellation,
  at-least-once reconciliation, and explicit unknown outcomes.
- Add local allowlisted child statecharts and Jido Agent invocation with bounded
  ancestry, descendants, and later authenticated control Turns.
- Add versioned Plugin persistence and migration checks for the profile, chart,
  Registry, limits, runtime protocol, and duplicate window.
- Add safe chart and session inspection and disclosure tests for XML, Signal,
  Action, runtime, and context data.
- Vendor unchanged selected W3C Implementation Report fixtures for assertions
  355, 403, and 436 under the W3C 3-clause BSD license.
- Add direct door and direct/live parallel approval examples.
- Add the exact local V3 source gate and a separate publishable Hex dependency
  gate. Local sibling paths remain the default until release.

This release describes profile support. It does not claim full W3C SCXML
processor conformance.
