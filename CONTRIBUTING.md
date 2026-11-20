# Contribution

Run these commands from the package directory.

```sh
mix quality
mix test --cover --warnings-as-errors
mix docs --warnings-as-errors
mix statechart.w3c test/fixtures/w3c/355/test355.txml
git diff --check
```

Keep upstream W3C fixtures byte-for-byte intact. Make template changes in memory
and check the verdict in the running Agent. Put local scenarios and their
expected outcomes in the example file.

Run `mix hex.build` after switching to a Hex release of Jido with Iterate
subflows. Hex rejects Git dependencies during the package build.
