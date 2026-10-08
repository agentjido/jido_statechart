alias Jido.Statechart.{Limits, Profile, Registry, SCXML, Session}

source = Path.expand("door.scxml", __DIR__)
chart = source |> File.read!() |> SCXML.compile!(id: "door", source_uri: source)
registry = Registry.new!(%{version: "door-registry-1", entries: []})
limits = Limits.default()

session =
  Session.new!(%{
    id: "door-session",
    incarnation: "door-session-1",
    chart_fingerprint: chart.fingerprint,
    profile_version: Profile.version(),
    registry_version: registry.version,
    registry_digest: registry.digest,
    limits_digest: Limits.digest(limits),
    invocation_remaining_descendants: limits.total_descendants
  })

{:ok, initialized} = Jido.Statechart.initialize(chart, session, registry)
true = initialized.session.configuration == ["closed"]

{:ok, opened} =
  Jido.Statechart.step(chart, initialized.session, %{name: "door.open"}, registry)

true = opened.session.configuration == ["opened"]
true = opened.intents == []

{:ok, closed} =
  Jido.Statechart.step(chart, opened.session, %{name: "door.close"}, registry)

true = closed.session.configuration == ["closed"]
IO.puts("direct door: closed -> opened -> closed")
