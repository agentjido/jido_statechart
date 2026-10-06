# Changelog

## 0.2.0 — 2026-10-06

- Add restricted SCXML 1.0 XML input through an optional Saxy parser.
- Add bounded namespace validation, parser security checks, and typed rejection
  of unsupported XML elements, attributes, and executable content.
- Add SCXML event descriptors with bounded prefix and wildcard matching.
- Preserve existing exact-mode fingerprints and checkpoint compatibility.
- Add the `statechart_xml` Agent declaration, JSON action payloads, fixed XML
  fixtures, parser properties, live integration tests, and an XML example.

## 0.1.0 — 2026-10-06

- Add the normalized definition compiler and strict validator.
- Add a pure bounded interpreter for atomic, compound, and final states.
- Add deterministic transition selection, entry and exit actions, eventless
  transitions, FIFO internal events, and compound completion events.
- Add trusted behavior registries, explicit effect requests, and typed failures.
- Add ordinary Jido Agent integration with one generic Step Action and one Turn.
- Add the Elixir DSL, data authoring API, fingerprints, and checkpoint checks.
- Add deterministic trace fixtures, property tests, and Jido restart tests.
- Document package ownership, execution limits, release dependencies, and the
  unsupported parallel, history, and SCXML scope.
