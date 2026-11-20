# Jido Statechart usage rules

- Use `Jido.Statechart` with a literal `~SCXML` chart in a chart module.
  Call `Jido.Statechart.compile/1` to validate XML at runtime.
- Attach `Jido.Statechart.Plugin` to a Jido Agent. Route chart event types to
  `Jido.Statechart.Plugin.Route`. The Plugin adds its own initialization route.
- Call `Jido.Statechart.initialize/3` after the Agent starts. Check for a
  committed turn before you send chart events. Read committed state with
  `Jido.Statechart.session/1`.
- Use registry bindings for named guards, Actions, and child Agents. Supply
  trusted modules and functions from the application.
- Use the null or Jido data model. See [README.md](README.md) for a complete
  example and for the limits of W3C conformance.
