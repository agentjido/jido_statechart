# Jido Statechart contributor instructions

Run commands from this package root. See [README.md](README.md) for the public
Agent example and the current SCXML support.

## Code map

- `lib/jido_statechart.ex` defines the chart macro, sigil, and session API.
- `lib/jido_statechart/scxml.ex` compiles XML. `configuration.ex` selects
  transitions. `turn.ex` runs ordered microsteps with Jido Flow.
- `lib/jido_statechart/plugin.ex` owns the committed session.
  `plugin/effects.ex` dispatches sends and child Agent work after commit.
- `lib/jido_statechart/conformance/template.ex` translates W3C templates in
  memory. `conformance.ex` runs them in live Agents.

## Change and test rules

- Use existing Jido Flows, Actions, Signals, and Plugin callbacks for Agent
  integration. Keep transition selection and internal event order in the
  interpreter.
- Keep files under `test/fixtures/w3c/` byte-for-byte intact. Make any fixture
  translation in memory. Keep the runner and ExUnit on the same manifest
  filter. ECMAScript and the other scripting cases stay deferred.
- Put new local scenarios in ExUnit. For Agent lifecycle, queue, and transport
  behavior, assert the outcome through a live Agent.
- Run `mix quality` and `mix coveralls --warnings-as-errors` for code or test
  changes. Keep total line coverage at or above 90%. Use
  `mix coveralls.html --warnings-as-errors` to find uncovered lines.
- For changes to SCXML behavior or the runner, run
  `mix statechart.w3c --manifest test/fixtures/w3c/manifest.xml`. Check for zero
  unexpected failures and confirm the reported adjustment for fixture 198 and
  expected failure for fixture 352.
- For documentation changes, run `mix docs --warnings-as-errors`. Execute any
  changed usage example against the pinned Jido dependency.
