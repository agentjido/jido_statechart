# Contributing

Run these commands from the package root.

```sh
mix setup
mix quality
mix coveralls --warnings-as-errors
mix docs --warnings-as-errors
mix statechart.w3c --manifest test/fixtures/w3c/manifest.xml
git diff --check
```

Keep the W3C fixtures byte-for-byte intact. Translate templates in memory.
For Agent lifecycle and event delivery, assert the result in a live Agent.

Use Conventional Commits. Release automation generates the changelog.
To install the commit message hook, run `mix install_hooks` from the primary
checkout after `mix setup`. Compilation leaves the Git hook configuration alone.

## Release checks

The repository uses the shared Jido v4 workflows for CI, advisory PR review,
and releases. After the Hex build passes, dispatch **Release** with **Dry run**
selected to check release preparation. For a real release, the workflow uses
`RELEASE_TOKEN` to push the release commit and tag and `HEX_API_KEY` to publish
the package.

## Package exceptions

- The Jido `release/v3` GitHub branch provides Iterate subflows. Hex Jido
  3.0.0-beta.3 lacks that support. CI skips the Hex dry run while the package
  uses the Git dependency. The release preflight requires a successful Hex
  build. Switch to a Hex version with the feature and enable package validation
  before release.
- CI tests Elixir 1.18 and 1.19 on OTP 27, and Elixir 1.20 on OTP 29.
  ExCoveralls fails to start on Elixir 1.20 with OTP 27. Add the compile-only
  lane when a release candidate newer than the current stable line is available.
- Credo enforces high-priority issues. The strict check still reports
  style and complexity issues in the SCXML interpreter and its tests.
- Statechart uses the Plugin configuration supplied by its host Agent.
  Installation requires only the dependency and local Agent code.

See the [Jido package quality standards](https://jido.run/docs/contributors/package-quality-standards)
for contributor and release requirements.

## Telemetry

Events use the `[:jido, :statechart]` prefix.

| Event suffix | Measurements | Metadata |
| --- | --- | --- |
| `:log` | None | `instance`, `agent`, `label`, `value` |
| `:completion_retry` | `count: 1` on the first retry | `parent`, `child`, `limit` |

The log event carries chart-defined values. Select which fields your
application exports.
