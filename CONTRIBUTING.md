# Contribution

Work inside the `jido_statechart` repository. Do not include changes from a
sibling repository in this package.

## Local V3 source contract

Keep these repositories beside `jido_statechart`. The default dependencies in
`mix.exs` use these paths.

| Directory | Branch | Required commit |
| --- | --- | --- |
| `../jido` | `release/v3` | `8322de574c53d5c2096243d230c9de4f14803bda` |
| `../jido_action` | `release/v3` | `65330e3dfcaae570bc87f570a9c815f52ec2d872` |
| `../jido_signal` | `release/v3` | `fd8d00555d6a64b4109619f4c26f1b75e8a91d41` |
| `../zoi` | `jido/v3-minimal` | `2fff2a23e23e7ac0b26f62f49bbc1b12f7818ac9` |

Check the matrix before a local release test:

```sh
test "$(git -C ../jido rev-parse HEAD)" = "8322de574c53d5c2096243d230c9de4f14803bda"
test "$(git -C ../jido_action rev-parse HEAD)" = "65330e3dfcaae570bc87f570a9c815f52ec2d872"
test "$(git -C ../jido_signal rev-parse HEAD)" = "fd8d00555d6a64b4109619f4c26f1b75e8a91d41"
test "$(git -C ../zoi rev-parse HEAD)" = "2fff2a23e23e7ac0b26f62f49bbc1b12f7818ac9"
```

## Required local commit gate

Run each command from `jido_statechart`:

```sh
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix test --warnings-as-errors
mix test test/system --warnings-as-errors
mix test --cover --warnings-as-errors
mix docs --warnings-as-errors
mix run examples/door.exs
mix run examples/parallel_approval.exs
mix xref graph --format cycles --label compile-connected
mix quality
git diff --check
```

Coverage must be at least 90 percent. Do not exclude a package feature module
to make the number pass. The local path graph cannot make a publishable Hex
archive. Package construction is part of the separate Hex gate.

## Separate Hex dependency gate

The default local paths remain in `mix.exs` during V3 integration. The Hex gate
sets `JIDO_STATECHART_HEX_GATE=1`. This selects published version requirements
for Jido V3, Jido Action, Jido Signal, and Zoi.

Run the gate only in a clean checkout or an isolated CI job because dependency
resolution can change `mix.lock`:

```sh
JIDO_STATECHART_HEX_GATE=1 mix deps.get
JIDO_STATECHART_HEX_GATE=1 mix format --check-formatted
JIDO_STATECHART_HEX_GATE=1 mix compile --warnings-as-errors
JIDO_STATECHART_HEX_GATE=1 mix test --warnings-as-errors
JIDO_STATECHART_HEX_GATE=1 mix test test/system --warnings-as-errors
JIDO_STATECHART_HEX_GATE=1 mix test --cover --warnings-as-errors
JIDO_STATECHART_HEX_GATE=1 mix docs --warnings-as-errors
JIDO_STATECHART_HEX_GATE=1 mix run examples/door.exs
JIDO_STATECHART_HEX_GATE=1 mix run examples/parallel_approval.exs
JIDO_STATECHART_HEX_GATE=1 mix xref graph --format cycles --label compile-connected
JIDO_STATECHART_HEX_GATE=1 mix quality
JIDO_STATECHART_HEX_GATE=1 mix hex.build
```

The Hex job is a separate pre-release gate. A local-path pass is not permission
to publish. Release only when compatible published dependencies pass the same
checks.

## Profile evidence

Keep profile changes in `Jido.Statechart.Profile`. Add a stable feature row,
W3C section, assertion ID when one exists, reason for every unsupported or
deviation row, and a regression test.

The W3C fixture snapshot is in `test/fixtures/w3c`. Do not change a copied
fixture. For a new fixture, record its official W3C URL, upstream revision,
SHA-256 value, license, profile status, exact case test ID, expected behavior,
and execution paths. The manifest separates the full official IR universe, the
closed profile-scoped inventory, and the smaller selected-run inventory. Each
profile-scoped skipped assertion needs a category and a nonempty reason. Do not
imply that a skipped assertion ran or that this profile covers an excluded
assertion.

Do not state that this package is a fully conforming W3C processor.

## Safety rules

- Keep all externally supplied names as strings. Do not create atoms from XML,
  Signals, or stored state.
- Keep expression, Action, target, and invocation handlers in a trusted Registry.
- Keep runtime proof values, proof secrets, process handles, and task references
  out of state, diagnostics, traces, logs, examples, and documentation.
- Keep delivery and child work after the Agent commit.
- Test unknown outcomes, duplicate input, retry identity, restore, and cleanup.
- Add marker secrets and terminal control characters to disclosure tests when a
  new error or observation surface is added.
