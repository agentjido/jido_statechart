# Jido SCXML 1.0 Profile

This package implements the Jido SCXML 1.0 Profile. It follows the
[W3C SCXML 1.0 Recommendation](https://www.w3.org/TR/scxml/) for the supported
semantic rules. It has listed restrictions and deviations. It does not claim
full W3C SCXML processor conformance.

`Jido.Statechart.Profile.features/0` is the authority for feature status.
`Jido.Statechart.capabilities/0` returns the portable capability manifest and
its digest.

## Compile XML

The caller must read the XML bytes. The compiler does no I/O.

```elixir
alias Jido.Statechart.SCXML

{:ok, chart} =
  "charts/order.scxml"
  |> File.read!()
  |> SCXML.compile(id: "order", source_uri: "charts/order.scxml")
```

`compile_stream/2` accepts an enumerable of binary chunks. `compile!/2` raises
`ArgumentError` for a diagnostic. The accepted options are `:id`, `:limits`,
and `:source_uri`. Unknown or duplicate options fail.

The root must use the SCXML namespace
`http://www.w3.org/2005/07/scxml` and version `1.0`. The compiler accepts the
`null` and `jido` data models and early or late data binding.

## Supported model

The profile supports these state and transition features:

- atomic, compound, parallel, final, shallow-history, and deep-history states;
- explicit and default initial states;
- external, internal descendant, targetless, eventless, and legal multi-target
  transitions;
- SCXML event descriptors and the optimal enabled transition set;
- entry, exit, transition, initial, history, and finalize content;
- compound and parallel completion and `donedata`;
- the internal FIFO event queue and run-to-completion processing.

The profile supports these standard executable elements: `raise`, `if`,
`elseif`, `else`, `foreach`, `assign`, `log`, `send`, and `cancel`. It supports
`datamodel`, `data`, `content`, `param`, `donedata`, `invoke`, and `finalize`.
Executable-content blocks run in document order. An execution error stops the
remaining elements in that block and adds `error.execution` when the error is
recoverable.

Values such as `cond`, `expr`, `location`, and `array` are restricted Jido data
model inputs. They are identifiers or bounded expression values. They are not
Elixir or JavaScript source.

The Jido namespace is `urn:jido:statechart:1`. Its `action` element selects an
allowlisted Registry Action. It cannot select an arbitrary module.

## Event matching

An XML transition event is a space-separated list of descriptors. Matching is
case-sensitive and uses dot-delimited tokens.

| Descriptor | Matches | Does not match |
| --- | --- | --- |
| `order` | `order`, `order.created` | `ordering`, `Order` |
| `order.*` | `order`, `order.created` | `ordering` |
| `order payment` | either prefix | another prefix |
| `*` | any named event | an eventless step |

A missing event attribute makes an eventless transition. An unhandled external
event is a successful stable no-op.

## Data and capabilities

The null data model has no application data and no script support. It supports
the `In(state_id)` predicate.

The Jido data model uses portable values, trusted expression aliases,
string-keyed locations, and `In(state_id)`. The trusted Registry has four
capability types: expression, Action, target, and invocation. A session binds
the Registry version, manifest digest, and limits digest.

SCXML invocation starts an allowlisted local child statechart. The Jido
invocation extension starts an allowlisted local Jido Agent. The first profile
does not start a remote processor or an arbitrary module. An invoke `src` or
`srcexpr` resolves a local Registry capability. Inline invoke content is
portable child input. It is not an SCXML document to compile and execute.

An invoke without an authored `id` gets a deterministic hashed, session-scoped
Jido identifier. An `idlocation` receives that identifier, and distinct invoke
elements get distinct identifiers. The identifier does not use the SCXML
`stateid.platformid` form.

Invoke `param` and `namelist` values stay in authored order as portable child
input metadata. The profile does not inject these values into a child SCXML
top-level data model. It also does not filter the values against child `data`
declarations.

The protected `_event` value uses normalized Jido fields. These include
`name`, `class`, `send_id`, `origin`, `origin_type`, `invoke_id`, and `data`.
The values keep the SCXML event meaning, but the normalized names are not the
exact SCXML `type`, `sendid`, `origintype`, and `invokeid` field names.

## Parser safety

The parser accepts bounded UTF-8 XML 1.0. It accepts an initial UTF-8 byte order
mark and normal XML comments. It rejects:

- DTD and entity declarations;
- external entities, schemas, XInclude, and resource fetches;
- unsupported processing instructions and encodings;
- unknown SCXML elements or attributes;
- `<script>` and script resources;
- invalid namespace bindings and malformed names;
- input that exceeds any XML or data limit.

The five predefined XML entities and valid numeric character references are
allowed. The parser does not convert input text to atoms. An unknown or hostile
XML element name is redacted in the diagnostic path.

Compiler errors use `Jido.Statechart.Diagnostic`. A diagnostic has a stable
code, severity, bounded source path or location, profile feature, and redacted
correction data. It must not contain input secrets or terminal control text.

See [Semantic Rules](semantics.md) for the current limit values.

## Unsupported features

The first profile does not support:

- the ECMAScript or XPath data model;
- `<script>` or source-code evaluation;
- external `data`, `content`, or script resources;
- inline or external SCXML documents as invoke sources;
- invoke input injection or filtering against child SCXML top-level data;
- the BasicHTTP or SCXML Event I/O Processors;
- remote invocation or arbitrary processor-wide session addressing;
- DOM data model binding.

## Declared deviations

| Deviation | Jido rule |
| --- | --- |
| Bounded macrostep | A configured finite limit can stop run-to-completion work. |
| Restricted XML | Unsafe XML and external resource input fail before lowering. |
| Jido data model | Trusted bounded expressions replace source evaluation. |
| Jido Action | An allowlisted effect-free Action can provide executable content. |
| Jido invocation | An allowlisted local Jido Agent can be a child. |
| Commit then dispatch | External work starts only after the Jido Agent commit. |
| Post-commit child lifecycle | Child start and stop use later authenticated control Turns. |
| Generated invoke ID form | Deterministic hashed Jido IDs replace `stateid.platformid`. |
| Invoke input metadata | Ordered portable metadata replaces child SCXML data-model injection. |
| Event system fields | Normalized Jido field names replace some exact SCXML `_event` field names. |

These differences are part of the public profile. They are not hidden
implementation details.

## W3C evidence boundary

The package vendors unchanged selected inputs from the
[W3C SCXML Implementation Report](https://www.w3.org/Voice/2013/scxml-irp/),
version 10 March 2015. The report states that its goals are implementation and
interoperability evidence and that conformance testing is not a goal.

The selected `.txml` files use abstract `conf` markup. The package keeps their
bytes unchanged and runs equivalent profile-native cases for assertions 355,
403, and 436. Each selected case runs through the pure kernel, direct Flow, and
live Agent paths. The manifest records all 200 official IR assertion rows. Its
closed profile scope classifies all 200 rows. The C.1 rows and assertion 253
are explicit unsupported SCXML Event I/O Processor evidence. They are not
support claims. The snapshot README, license, source URLs, and SHA-256 values
are in `test/fixtures/w3c`.

The fixture subset uses the W3C 3-clause BSD license. It is evidence for this
profile only. It is not a certificate and it is not a full W3C test-suite run.
