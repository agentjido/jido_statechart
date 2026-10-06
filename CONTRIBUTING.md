# Contribution

Work inside this repository. Keep sibling source changes in their own
repositories. Use compatible Jido V3 checkouts and the local paths in `mix.exs`.

Run these checks before a commit:

```sh
mix deps.get
mix quality
mix test --cover --warnings-as-errors
mix docs --warnings-as-errors
mix run examples/door.exs
mix run examples/approval.exs
```

The coverage gate is 90%. Test meaningful behavior: transition boundaries,
priority, guards, action order, internal events, malformed input, limits,
checkpoint compatibility, and live Jido commits. Do not change a trace fixture
only to make a failing test pass. Explain the semantic change first.

Use deterministic trusted callbacks. Do not add external I/O to guards or
reducers. Keep deferred work in explicit effect requests and Jido Directives.
Bump chart versions when callback behavior changes. Plan checkpoint migration
when a state schema or stored contract changes.

The manual GitHub CI workflow needs published Jido and Action commit refs.
The initial tested local commits are not yet public. See the architecture
guide. Keep source refs explicit so CI does not silently select a different API.
