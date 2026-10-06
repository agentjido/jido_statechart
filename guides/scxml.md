# SCXML Boundary

This release has no `Jido.Statechart.SCXML` parser. Its supported SCXML subset
is empty. It does not accept XML or claim W3C conformance.

A secure XML edge requires separate parser security checks and semantic
fixtures. Those checks must prove that parsing cannot introduce external
resources, executable content, or new atoms. This release keeps that work
outside the complete core engine. An incomplete permissive XML parser is not
included.

A future adapter must parse once and call the existing data compiler. It must
not add a second runtime or interpret XML during a macrostep.

## Required adapter checks

- Disable DTDs and all entity declarations and expansion.
- Disable XInclude and network or filesystem loading.
- Reject scripts and arbitrary executable content.
- Keep element names, state IDs, and event IDs as bounded strings.
- Bound input bytes, elements, attributes, text, and nesting before allocation.
- Map only explicitly supported elements and attributes.
- Resolve guards and reducers through application-owned trusted IDs.
- Reject every unsupported construct with a typed error.
- Publish the supported subset and test it against fixed XML fixtures.
- Test malformed XML, entity attacks, namespace handling, and limit failures.

## Other follow-up scope

Parallel regions require conflict selection, simultaneous active branches,
entry and exit ordering, and completion rules. History states require saved
configuration rules and checkpoint migration. Neither feature is supported.
The compiler rejects `parallel` and `history` types.

Expression languages, data-model scripts, delayed events, invoked services,
and full SCXML event descriptor matching also remain outside this release.
A future extension must preserve the normalized model, deterministic limits,
and Jido's single candidate commit boundary.
