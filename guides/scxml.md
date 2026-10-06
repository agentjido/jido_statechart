# SCXML Input

`Jido.Statechart.SCXML` compiles a restricted SCXML 1.0 document into the same
`Definition` used by the data API and Agent DSL. It parses XML once. The core
interpreter does not read XML or use a second execution engine.

This adapter is a Jido profile. It does not claim full W3C SCXML conformance.
The format follows the [W3C SCXML specification](https://www.w3.org/TR/scxml/).
The supported subset and differences are listed below.

## Installation and use

Saxy is optional for consumers. To use XML, add this dependency:

```elixir
{:saxy, "~> 1.6"}
```

The adapter accepts UTF-8 XML bytes. The application owns file access:

```elixir
alias Jido.Statechart.SCXML

{:ok, chart} = SCXML.compile(File.read!("charts/door.scxml"))
# Pass chart to Jido.Statechart.init/3 and step/4.
```

Use `compile!/2` to raise a typed error. Options are `id:`, `version:`,
`limits:`, and `xml_limits:`. Unknown or duplicate options fail. The chart ID
comes from `id:`, then the root `name`, then `"scxml"`. The behavior version
comes from `version:` and defaults to `"1"`. It is separate from the required
SCXML format version `"1.0"`.

An application module can compile a file into an ordinary Jido Agent:

```elixir
defmodule MyApp.Door do
  use Jido.Statechart.Agent, name: "door"

  @external_resource Path.join(__DIR__, "door.scxml")
  statechart_xml File.read!(@external_resource), version: "1"
end
```

Use one `statechart_xml` declaration or one `statechart` block per module.
`registry/0`, `effects/0`, Signals, Turns, and checkpoints use the normal Agent
contracts. The XML cannot supply callback code. See the complete
[XML example](../examples/scxml.exs) and [chart file](../examples/door.scxml).

## Supported elements and attributes

The SCXML namespace is `http://www.w3.org/2005/07/scxml`. A default namespace or
a declared prefix is required. Namespace prefixes do not affect the definition.
All listed standard attributes are unqualified.

| Element | Attributes | Rules |
| --- | --- | --- |
| `scxml` | `version`, `name`, `initial`, `datamodel` | Root only; version must be `1.0`; child states required |
| `state` | `id`, `initial` | ID required; child states make it compound |
| `final` | `id` | ID required; entry and exit handlers permitted; transitions forbidden |
| `transition` | `event`, `target`, `cond`, `type` | At least one event, target, or condition required |
| `initial` | None | Compound state only; one target-only transition |
| `onentry`, `onexit` | None | Ordered executable content; multiple handlers preserve document order |
| `raise` | `event`, optional Jido `data` | One internal event name; no expressions |

Root children must be `state` or `final`. The initial target defaults to the
first child in document order. A state can use an `initial` attribute or an
`initial` element, but cannot combine them. Each initial target must name one
immediate child. Initial transitions cannot have actions, events, conditions,
or a `type` attribute. Final states cannot have child states or `donedata`.

A transition can have one target or no target. Multiple targets are not
supported. Targetless transitions run their actions without exit or entry.
The default type is `external`. An `internal` transition from a compound
state to its strict descendant retains the source. Other `internal` transitions
use external semantics, as specified by SCXML.

State IDs, target IDs, condition IDs, reducer IDs, and effect IDs use this
ASCII syntax: `[A-Za-z_][A-Za-z0-9_.:-]*`. Names in XML tags and attributes use
ASCII XML names with an optional namespace prefix. ID values and targets
cannot contain whitespace.

## Conditions, actions, and data

The adapter uses the Jido registry data model. `datamodel="jido"` is permitted;
omission selects the same profile. Other data models are rejected.
`cond="allowed"` selects the trusted guard with ID `"allowed"`. It is an ID,
not an expression. Domain data is supplied by the application through the
normal instance or Agent state API.

Custom actions use the namespace `urn:jido:statechart:1`:

```xml
<scxml xmlns="http://www.w3.org/2005/07/scxml"
       xmlns:j="urn:jido:statechart:1"
       version="1.0" name="approval" datamodel="jido">
  <state id="waiting">
    <transition event="approve" cond="allowed" target="done">
      <j:action id="record" params='{"approved":true}'/>
      <raise event="audit" j:data='{"approved":true}'/>
      <j:effect id="notify" data='{"approved":true}'/>
    </transition>
  </state>
  <final id="done"/>
</scxml>
```

`j:action` has unqualified `id` and optional `params` attributes. It selects a
trusted reducer. `j:effect` has unqualified `id` and optional `data` attributes.
It produces an effect request. `raise` can have a qualified `j:data` attribute.
Payload attributes contain JSON objects and default to `{}`. JSON keys remain
strings. The core data validator checks their size, nesting, and scalar types.
These action elements must be empty.

No XML value can select a module, function, or entity resolver. The application
must provide the registry and effect builders. Application callbacks must
follow the same purity and termination contracts as data-authored charts.

## Event matching

XML transitions use SCXML event descriptors. Space, tab, carriage return, and
line feed separate alternative descriptors. A descriptor matches its exact
name and names with a dot-delimited suffix. Matching is case-sensitive:

| Descriptor | Matches | Does not match |
| --- | --- | --- |
| `order` | `order`, `order.created` | `ordering`, `Order` |
| `order.`, `order.*` | `order`, `order.created` | `ordering` |
| `order payment` | Either prefix | Other prefixes |
| `*` | Any named event | Eventless stabilization |

A missing event attribute means an eventless transition. Empty descriptors,
empty dot tokens, and wildcard characters outside a trailing `.*` or the
single `*` descriptor are rejected. A transition can have at most 32
descriptors. Each descriptor check consumes macrostep work. A matched transition
calls its guard once, even when several descriptors match. See the
[W3C event descriptor rules](https://www.w3.org/TR/scxml/#EventDescriptors).

Data and DSL transitions keep exact matching by default. They can select the
same descriptor mode with `event_mode: :scxml`. Exact chart fingerprints from
0.1.0 remain unchanged. Descriptor mode is part of the fingerprint, so a change
in matching behavior rejects an incompatible checkpoint.

## Parser security and limits

The parser uses [Saxy](https://saxy.hexdocs.pm/Saxy.html) with a fixed handler
and a fixed rejection function for unknown entities. DTDs and all entity
declarations are rejected before parsing. The five predefined XML entities
and numeric character references with at most seven digits are supported.
Numeric values must be valid XML 1.0 characters. The adapter does not
load external files, URLs, schemas, or XInclude resources.

Only XML 1.0 and UTF-8 are accepted. An initial UTF-8 byte order mark is permitted. Comments and an optional XML declaration
are permitted. Other processing instructions, CDATA, and non-whitespace text
are rejected. Every unsupported element or attribute produces a typed error.
Duplicate attributes, duplicate expanded attribute names, unbound prefixes,
and invalid reserved namespace bindings fail.

The XML byte limit applies before parsing or tree allocation. The SAX handler
checks element counts, attribute values, names, text, and depth before adding
nodes to its bounded tree. Saxy can allocate tokens within the byte limit
before the handler receives them. Core limits apply to the resulting chart.

| `xml_limits` field | Hard maximum |
| --- | ---: |
| `bytes` | 1,048,576 |
| `depth` | 64 XML elements |
| `elements` | 16,384 |
| `attributes` | 16 per element, including namespace declarations |
| `attribute_bytes` | 4,096 per decoded value |
| `name_bytes` | 256 per qualified XML name |
| `text_bytes` | 65,536 total emitted whitespace bytes |

Limit overrides are maps with known atom or string keys. They can only lower
the hard maxima. For example, `xml_limits: %{bytes: 65_536, depth: 16}`.
The adapter returns `:parser_unavailable` when Saxy is absent; the core data API
still loads. Other errors use `Jido.Statechart.Error`, including
`:unsupported_xml`, `:invalid_xml`, and `:limit_exceeded`.

## Semantic limits

Parallel states, history states, data declarations, scripts, expression
languages, assignments, conditional executable content, sends, timers, invoked
services, cancellation, root entry and exit handlers, and foreign executable
content are not supported. They fail at compile time. The adapter does not
silently ignore these constructs.

The runtime keeps its bounded Jido contract. An unhandled external event fails
the macrostep; full SCXML would discard that event. Callback failures fail the
whole candidate; the adapter does not create SCXML `error.execution` events.
No partial state or effects are returned. Completion, action ordering, and
post-commit effects follow the core execution guide. The fixed fixture and
security tests verify this profile; they are not a W3C conformance suite.
