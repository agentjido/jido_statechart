defmodule Jido.Statechart.Conformance do
  @moduledoc false

  alias Jido.Expr
  alias Jido.Statechart.Agent, as: StatechartAgent
  alias Jido.Statechart.Expression.Reference
  alias Jido.Statechart.Semantics.Macrostep
  alias Jido.Statechart.{Flow, Limits, Profile, Registry, Session}

  @fixture_root Path.expand("../fixtures/w3c", __DIR__)

  defmodule Assertion355Chart do
    @chart Jido.Statechart.SCXML.compile!(
             """
             <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
               <state id="s0"><transition target="pass"/></state>
               <state id="s1"><transition target="fail"/></state>
               <final id="pass"/><final id="fail"/>
             </scxml>
             """,
             id: "w3c-355-profile-translation"
           )
    @registry Registry.new!(%{version: "w3c-355-2", entries: []})
    use Jido.Statechart.Chart, chart: @chart, registry: @registry
  end

  defmodule Assertion403AChart do
    @chart Jido.Statechart.SCXML.compile!(
             """
             <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0"
                    datamodel="jido" initial="s0">
               <state id="s0" initial="s01">
                 <transition event="event1" target="fail"/>
                 <transition event="event2" target="pass"/>
                 <state id="s01">
                   <onentry><raise event="event1"/></onentry>
                   <transition event="event1" target="s02"/>
                   <transition event="*" target="fail"/>
                 </state>
                 <state id="s02">
                   <onentry><raise event="event2"/></onentry>
                   <transition event="event1" target="fail"/>
                   <transition event="event2" cond="false_condition" target="fail"/>
                 </state>
               </state>
               <final id="pass"/><final id="fail"/>
             </scxml>
             """,
             id: "w3c-403a-profile-translation"
           )
    @registry Registry.new!(%{
                version: "w3c-403a-2",
                entries: [
                  %{
                    kind: :expression,
                    alias: "false_condition",
                    permissions: ["evaluate"],
                    handler: {:expression, false}
                  }
                ]
              })
    use Jido.Statechart.Chart, chart: @chart, registry: @registry
  end

  defmodule Assertion403BChart do
    @chart Jido.Statechart.SCXML.compile!(
             """
             <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0"
                    datamodel="jido" initial="s0">
               <datamodel><data id="counter" expr="zero"/></datamodel>
               <state id="s0" initial="p0">
                 <transition event="event1"><assign location="counter" expr="increment"/></transition>
                 <parallel id="p0">
                   <onentry><raise event="event1"/><raise event="event2"/></onentry>
                   <transition event="event1"><assign location="counter" expr="increment"/></transition>
                   <state id="p0s1">
                     <transition event="event2" cond="counter_one" target="pass"/>
                     <transition event="event2" target="fail"/>
                   </state>
                   <state id="p0s2"/>
                 </parallel>
               </state>
               <final id="pass"/><final id="fail"/>
             </scxml>
             """,
             id: "w3c-403b-profile-translation"
           )
    @registry Registry.new!(%{
                version: "w3c-403b-2",
                entries: [
                  %{
                    kind: :expression,
                    alias: "zero",
                    permissions: ["evaluate"],
                    handler: {:expression, 0}
                  },
                  %{
                    kind: :expression,
                    alias: "increment",
                    permissions: ["evaluate", "read:data"],
                    handler: {:expression, Expr.new!(:add, [Reference.data("counter"), 1])}
                  },
                  %{
                    kind: :expression,
                    alias: "counter_one",
                    permissions: ["evaluate", "read:data"],
                    handler: {:expression, Expr.new!(:eq, [Reference.data("counter"), 1])}
                  }
                ]
              })
    use Jido.Statechart.Chart, chart: @chart, registry: @registry
  end

  defmodule Assertion403CChart do
    @chart Jido.Statechart.SCXML.compile!(
             """
             <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0"
                    datamodel="jido" initial="s0">
               <datamodel><data id="counter" expr="zero"/></datamodel>
               <state id="s0" initial="p0">
                 <onentry><raise event="event1"/></onentry>
                 <transition event="event2" target="fail"/>
                 <parallel id="p0">
                   <state id="p0s1">
                     <transition event="event1"/>
                     <transition event="event2"/>
                   </state>
                   <state id="p0s2">
                     <transition event="event1" target="p0s1"><raise event="event2"/></transition>
                   </state>
                   <state id="p0s3">
                     <transition event="event1" target="fail"/>
                     <transition event="event2" target="s1"/>
                   </state>
                   <state id="p0s4">
                     <transition event="*"><assign location="counter" expr="increment"/></transition>
                   </state>
                 </parallel>
               </state>
               <state id="s1">
                 <transition cond="counter_two" target="pass"/>
                 <transition target="fail"/>
               </state>
               <final id="pass"/><final id="fail"/>
             </scxml>
             """,
             id: "w3c-403c-profile-translation"
           )
    @registry Registry.new!(%{
                version: "w3c-403c-2",
                entries: [
                  %{
                    kind: :expression,
                    alias: "zero",
                    permissions: ["evaluate"],
                    handler: {:expression, 0}
                  },
                  %{
                    kind: :expression,
                    alias: "increment",
                    permissions: ["evaluate", "read:data"],
                    handler: {:expression, Expr.new!(:add, [Reference.data("counter"), 1])}
                  },
                  %{
                    kind: :expression,
                    alias: "counter_two",
                    permissions: ["evaluate", "read:data"],
                    handler: {:expression, Expr.new!(:eq, [Reference.data("counter"), 2])}
                  }
                ]
              })
    use Jido.Statechart.Chart, chart: @chart, registry: @registry
  end

  defmodule Assertion436Chart do
    @chart Jido.Statechart.SCXML.compile!(
             """
             <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0"
                    datamodel="null" initial="p">
               <parallel id="p">
                 <state id="ps0">
                   <transition cond="In('s1')" target="fail"/>
                   <transition cond="In('ps1')" target="pass"/>
                   <transition target="fail"/>
                 </state>
                 <state id="ps1"/>
               </parallel>
               <state id="s1"/>
               <final id="pass"/><final id="fail"/>
             </scxml>
             """,
             id: "w3c-436-profile-translation"
           )
    @registry Registry.new!(%{version: "w3c-436-2", entries: []})
    use Jido.Statechart.Chart, chart: @chart, registry: @registry
  end

  @cases %{
    "355" => Assertion355Chart,
    "403a" => Assertion403AChart,
    "403b" => Assertion403BChart,
    "403c" => Assertion403CChart,
    "436" => Assertion436Chart
  }

  @evidence [
    {:scxml_element, "test/jido_statechart/scxml/validation_test.exs",
     "rejects unsupported root contracts",
     "The root namespace, version, data model, binding, and state rules are enforced."},
    {:state_atomic, "test/jido_statechart/semantics/transition_selection_test.exs",
     "configuration is a legal ordered set of atomic states",
     "A stable configuration contains only legal atomic states."},
    {:state_compound, "test/jido_statechart/scxml/lowering_test.exs",
     "lowers compound, parallel, final, and history states in document order",
     "Compound states lower with their ordered child topology."},
    {:state_parallel, "test/jido_statechart/semantics/parallel_test.exs",
     "parallel initialization enters every region in document order",
     "Parallel initialization enters each region in document order."},
    {:state_final, "test/jido_statechart/semantics/completion_test.exs",
     "top-level final completes once and keeps constructed donedata",
     "A top-level final state completes the session once."},
    {:scxml_initial_default, "test/jido_statechart/profile_feature_evidence_test.exs",
     "profile evidence: SCXML root default initial selects its first state",
     "An omitted root initial attribute selects the first child state."},
    {:initial_element, "test/jido_statechart/semantics/parallel_test.exs",
     "compound initial transition content runs after parent entry and before child entry",
     "Initial transition content runs in SCXML entry order."},
    {:history_shallow, "test/jido_statechart/semantics/history_test.exs",
     "shallow history saves a child and restores its default descendants",
     "Shallow history restores the saved child and its default descendants."},
    {:history_deep, "test/jido_statechart/semantics/history_test.exs",
     "deep history saves and restores atomic descendants",
     "Deep history restores the saved atomic descendants."},
    {:transition_external, "test/jido_statechart/semantics/transition_selection_test.exs",
     "transition domains distinguish targetless, internal descendant, and external self",
     "An external transition uses the external transition domain."},
    {:transition_internal, "test/jido_statechart/semantics/transition_selection_test.exs",
     "transition domains distinguish targetless, internal descendant, and external self",
     "An internal descendant transition keeps its compound source active."},
    {:transition_targetless, "test/jido_statechart/semantics/transition_selection_test.exs",
     "transition domains distinguish targetless, internal descendant, and external self",
     "A targetless transition has no exit domain."},
    {:transition_multi_target, "test/jido_statechart/scxml/lowering_test.exs",
     "accepts legal multi-target transitions across parallel regions",
     "A legal multi-target transition can target separate parallel regions."},
    {:transition_eventless, "test/jido_statechart/semantics/macrostep_test.exs",
     "eventless transitions run before FIFO internal events",
     "Eventless transitions run before queued internal events."},
    {:event_descriptor_matching, "test/jido_statechart/semantics/transition_selection_test.exs",
     "event descriptors use exact token prefixes and wildcard matching",
     "Event descriptors use exact tokens, token prefixes, and wildcard matching."},
    {:onentry_element, "test/jido_statechart/semantics/parallel_test.exs",
     "one microstep runs all exits, transition content, then entries in SCXML order",
     "Entry content runs after all exit and transition content."},
    {:onexit_element, "test/jido_statechart/semantics/parallel_test.exs",
     "one microstep runs all exits, transition content, then entries in SCXML order",
     "Exit content runs before transition and entry content."},
    {:datamodel_element, "test/jido_statechart/data_model/jido_test.exs",
     "initializes string-keyed declarations and rejects unsafe shapes",
     "The data model initializes bounded string-keyed declarations."},
    {:data_element, "test/jido_statechart/data_model/jido_test.exs",
     "initializes declarations by explicit document ordinal",
     "Data declarations initialize in explicit document order."},
    {:donedata_element, "test/jido_statechart/semantics/completion_test.exs",
     "top-level final completes once and keeps constructed donedata",
     "Final-state completion keeps constructed done data."},
    {:param_element, "test/jido_statechart/data_model/jido_test.exs",
     "constructs expression, parameter, text, and embedded content values",
     "Parameters construct ordered portable values."},
    {:content_element, "test/jido_statechart/data_model/jido_test.exs",
     "constructs expression, parameter, text, and embedded content values",
     "Content constructs bounded portable values."},
    {:raise_element, "test/jido_statechart/executable_content_test.exs",
     "runs authored condition, raise, log, and data content in order",
     "Raise appends an internal event in authored content order."},
    {:if_element, "test/jido_statechart/executable_content_test.exs",
     "runs authored condition, raise, log, and data content in order",
     "If selects the first true branch and runs its content."},
    {:elseif_element, "test/jido_statechart/scxml/review_regression_test.exs",
     "encodes ordered if partitions, including a nested if",
     "Elseif partitions keep authored order."},
    {:else_element, "test/jido_statechart/executable_content_test.exs",
     "keeps internal sends in the FIFO queue and selects else branches",
     "Else runs only when no earlier condition matches."},
    {:foreach_element, "test/jido_statechart/executable_content_test.exs",
     "foreach uses stable snapshots and scoped loop bindings",
     "Foreach uses one stable snapshot and scoped bindings."},
    {:assign_element, "test/jido_statechart/data_model/jido_test.exs",
     "assigns existing nested string-key locations and protects system variables",
     "Assign changes only an existing allowed data location."},
    {:log_element, "test/jido_statechart/executable_content_test.exs",
     "runs authored condition, raise, log, and data content in order",
     "Log records bounded values in authored order."},
    {:send_element, "test/jido_statechart/executable_content_test.exs",
     "builds send and cancel intent without changing the current event",
     "Send creates an intent without changing the current event."},
    {:cancel_element, "test/jido_statechart/executable_content_test.exs",
     "builds send and cancel intent without changing the current event",
     "Cancel creates an intent for the authored send identifier."},
    {:executable_content_order, "test/jido_statechart/executable_content_test.exs",
     "runs authored condition, raise, log, and data content in order",
     "An executable-content block runs its elements in authored document order."},
    {:executable_content_abort_on_error, "test/jido_statechart/executable_content_test.exs",
     "runs authored condition, raise, log, and data content in order",
     "An execution error stops the remaining elements in the current executable-content block."},
    {:invoke_scxml_element, "test/jido_statechart/runtime/invocation_test.exs",
     "resolves a standard SCXML child through the typed Registry",
     "SCXML invocation resolves a typed local child capability."},
    {:invoke_idlocation_assignment, "test/jido_statechart/runtime/invocation_test.exs",
     "generated invoke IDs are distinct, deterministic, and assigned to idlocation",
     "A generated invoke identifier is stored in the declared idlocation."},
    {:invoke_generated_id_form, "test/jido_statechart/runtime/invocation_test.exs",
     "generated invoke IDs are distinct, deterministic, and assigned to idlocation",
     "Generated invoke identifiers use a deterministic session-scoped Jido hash form, not stateid.platformid."},
    {:invoke_generated_id_uniqueness, "test/jido_statechart/runtime/invocation_test.exs",
     "generated invoke IDs are distinct, deterministic, and assigned to idlocation",
     "Generated identifiers for distinct invoke elements are unique in one session."},
    {:invoke_data_model_injection, "test/jido_statechart/runtime/invocation_test.exs",
     "invocation input preserves param and namelist metadata without SCXML data-model injection",
     "Invoke input stays ordered metadata and is not filtered into a child SCXML top-level data model."},
    {:invoke_input_metadata, "test/jido_statechart/runtime/invocation_test.exs",
     "invocation input preserves param and namelist metadata without SCXML data-model injection",
     "Param and namelist values are preserved separately as ordered portable input metadata."},
    {:invoke_jido_element, "test/system/invocation_session_test.exs",
     "a local Agent child survives runtime replacement and stops on state exit",
     "Jido invocation starts an allowlisted local Agent child."},
    {:finalize_element, "test/jido_statechart/runtime/invocation_test.exs",
     "matching child finalize content runs before transition selection",
     "Matching child finalization runs before transition selection."},
    {:invoke_autoforward, "test/jido_statechart/runtime/invocation_test.exs",
     "autoforward is ordered before a same-turn state-exit stop",
     "Autoforward is ordered before a same-turn invoke stop."},
    {:binding_early, "test/jido_statechart/data_model/jido_test.exs",
     "initializes declarations by explicit document ordinal",
     "Early binding initializes declarations in document order."},
    {:binding_late, "test/jido_statechart/semantics/macrostep_test.exs",
     "late data binding records first entry and survives session storage",
     "Late binding initializes state data on first entry and persists the result."},
    {:internal_event_queue, "test/jido_statechart/semantics/macrostep_test.exs",
     "eventless transitions run before FIFO internal events",
     "The internal event queue is FIFO after eventless processing."},
    {:run_to_completion, "test/jido_statechart/semantics/macrostep_test.exs",
     "repeated execution and trace replay are deterministic",
     "A macrostep runs to one deterministic stable configuration."},
    {:optimal_transition_set, "test/jido_statechart/profile_conformance_test.exs",
     "profile evidence: W3C 403 runs all selected transition-selection cases",
     "The 403a, 403b, and 403c cases cover fallback, document order, preemption, and a maximal non-conflicting set."},
    {:null_datamodel, "test/jido_statechart/data_model/null_test.exs",
     "supports only the null data model and In predicate",
     "The null data model rejects value evaluation and exposes In."},
    {:jido_datamodel, "test/jido_statechart/data_model/jido_test.exs",
     "resolves only registered expressions with declared permissions",
     "Jido expressions require typed registry entries and permissions."},
    {:in_predicate, "test/jido_statechart/data_model/null_test.exs",
     "supports only the null data model and In predicate",
     "In tests the current active state configuration."},
    {:system_variables, "test/jido_statechart/data_model/jido_test.exs",
     "reads system and loop bindings without exposing source evaluation",
     "System variables are readable through the bounded data model."},
    {:event_system_field_shape, "test/jido_statechart/profile_feature_evidence_test.exs",
     "profile evidence: event system fields use normalized Jido names and values",
     "Events have a fixed normalized Jido field set instead of the exact SCXML field names."},
    {:event_system_type, "test/jido_statechart/profile_feature_evidence_test.exs",
     "profile evidence: event system fields use normalized Jido names and values",
     "External, internal, and platform event types use the normalized class field."},
    {:event_system_send_id, "test/jido_statechart/profile_feature_evidence_test.exs",
     "profile evidence: event system fields use normalized Jido names and values",
     "Send identity uses send_id, with nil when no send identity is present."},
    {:event_system_origin, "test/jido_statechart/profile_feature_evidence_test.exs",
     "profile evidence: event system fields use normalized Jido names and values",
     "Internal and platform events have no origin."},
    {:event_system_origin_type, "test/jido_statechart/profile_feature_evidence_test.exs",
     "profile evidence: event system fields use normalized Jido names and values",
     "Origin type uses origin_type, with nil for internal and platform events."},
    {:event_system_invoke_id, "test/jido_statechart/profile_feature_evidence_test.exs",
     "profile evidence: event system fields use normalized Jido names and values",
     "Child correlation uses invoke_id, with nil for events that are not from a child."},
    {:event_system_name, "test/jido_statechart/profile_feature_evidence_test.exs",
     "profile evidence: event system fields use normalized Jido names and values",
     "The normalized event name field contains the event name."},
    {:jido_action_extension, "test/jido_statechart/action_runner_test.exs",
     "runs a registered Action with a minimal context and remaining deadline",
     "A registered Jido Action receives only bounded context and time."},
    {:script_element, "test/jido_statechart/profile_feature_evidence_test.exs",
     "profile evidence: script is rejected without source evaluation",
     "Script input is rejected before source evaluation."},
    {:external_data_source, "test/jido_statechart/profile_feature_evidence_test.exs",
     "profile evidence: external data source is rejected",
     "An external data source is rejected before any fetch."},
    {:external_content_source, "test/jido_statechart/profile_feature_evidence_test.exs",
     "profile evidence: external invocation content source is rejected",
     "An external invocation source is rejected before any fetch."},
    {:ecmascript_datamodel, "test/jido_statechart/profile_feature_evidence_test.exs",
     "profile evidence: ECMAScript data model is rejected",
     "The ECMAScript data model is rejected at the SCXML root."},
    {:xpath_datamodel, "test/jido_statechart/profile_feature_evidence_test.exs",
     "profile evidence: XPath data model is rejected",
     "The XPath data model is rejected at the SCXML root."},
    {:basic_http_event_io, "test/jido_statechart/profile_feature_evidence_test.exs",
     "profile evidence: Basic HTTP Event I/O targets are rejected",
     "HTTP targets are outside the closed local target grammar."},
    {:scxml_event_io_processor, "test/jido_statechart/profile_feature_evidence_test.exs",
     "profile evidence: SCXML Event I/O Processor session targets are rejected",
     "SCXML session and invoke Event I/O Processor targets are outside the profile."},
    {:remote_invocation, "test/jido_statechart/runtime/invocation_test.exs",
     "invocation capabilities require an exact type, permission, and local scope",
     "A remote invocation capability is rejected by its scope."},
    {:bounded_macrostep, "test/jido_statechart/semantics/macrostep_test.exs",
     "work and trace limits stop at the exact boundary with no partial result",
     "A configured macrostep limit stops work without a partial result."},
    {:restricted_xml, "test/jido_statechart/scxml/security_test.exs",
     "rejects forbidden lexical constructs across every chunk boundary",
     "DTD, entity, processing instruction, and external entity input is rejected."},
    {:commit_then_dispatch, "test/system/recoverable_send_test.exs",
     "commits an immediate self-send before delivery and records its later result",
     "External delivery starts only after durable intent commit."},
    {:post_commit_child_lifecycle, "test/system/invocation_session_test.exs",
     "a local Agent child survives runtime replacement and stops on state exit",
     "Child start and stop work reconciles after the parent commit."},
    {:dom_binding, "test/jido_statechart/profile_feature_evidence_test.exs",
     "profile evidence: DOM binding is absent from the closed data model resolver",
     "The closed data model resolver exposes no DOM binding."}
  ]

  def manifest do
    @fixture_root |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
  end

  def fixture_root, do: @fixture_root
  def selected_cases, do: manifest()["cases"]

  def expected(case_id) do
    selected_cases() |> Enum.find(&(&1["id"] == case_id)) |> Map.fetch!("expected")
  end

  def evidence_registry do
    Enum.map(@evidence, fn {feature, file, name, expected} ->
      %{
        "id" => "profile:#{feature}",
        "feature" => Atom.to_string(feature),
        "file" => file,
        "name" => name,
        "expected" => expected
      }
    end)
  end

  def evidence_index, do: Map.new(evidence_registry(), &{&1["id"], &1})

  def run_pure(case_id), do: run_case(case_id, :pure)
  def run_direct(case_id), do: run_case(case_id, :direct)

  def run_live(case_id, jido) do
    chart_module = Map.fetch!(@cases, case_id)
    agent_module = agent_module(case_id)
    {:ok, server} = Jido.start_agent(jido, agent_module, id: unique_id("live-w3c-#{case_id}"))
    {:ok, agent} = StatechartAgent.initialize(server)
    summarize(case_id, chart_module.chart(), live_session(agent))
  end

  def profile_matrix do
    evidence = evidence_index()

    Enum.map(Profile.features(), fn feature ->
      %{
        id: feature.id,
        status: feature.status,
        assertions: feature.assertions,
        reason: feature.reason,
        evidence_key: feature.evidence_key,
        assertion_cases: assertion_cases(feature.assertions),
        regressions: [Map.fetch!(evidence, feature.evidence_key)]
      }
    end)
  end

  defp run_case(case_id, mode) do
    chart_module = Map.fetch!(@cases, case_id)
    chart = chart_module.chart()
    registry = chart_module.registry()
    source = session(chart, registry, "#{mode}-#{case_id}")

    {:ok, result} =
      case mode do
        :pure -> Macrostep.initialize(chart, source, options(registry))
        :direct -> Flow.initialize(chart, source, registry)
      end

    summarize(case_id, chart, result.session)
  end

  defp summarize(case_id, chart, session) do
    transition_index = Map.new(chart.transitions, &{&1.id, &1})

    steps =
      for %{"kind" => "microstep"} = entry <- session.trace do
        transitions = Enum.map(entry["transitions"], &Map.fetch!(transition_index, &1))

        %{
          "event" => entry["event"],
          "sources" => Enum.map(transitions, & &1.source_id),
          "targets" => Enum.map(transitions, & &1.target_ids)
        }
      end

    %{
      "case_id" => case_id,
      "status" => Atom.to_string(session.status),
      "configuration" => session.configuration,
      "data" => session.data,
      "steps" => steps
    }
  end

  defp assertion_cases(assertions) do
    for assertion <- assertions,
        case_info <- selected_cases(),
        case_info["assertion_id"] == assertion,
        do: Map.take(case_info, ["id", "test_id", "expected"])
  end

  defp agent_module("355"), do: Jido.Statechart.ProfileConformance.Assertion355Agent
  defp agent_module("403a"), do: Jido.Statechart.ProfileConformance.Assertion403AAgent
  defp agent_module("403b"), do: Jido.Statechart.ProfileConformance.Assertion403BAgent
  defp agent_module("403c"), do: Jido.Statechart.ProfileConformance.Assertion403CAgent
  defp agent_module("436"), do: Jido.Statechart.ProfileConformance.Assertion436Agent

  defp live_session(agent), do: agent.state.statechart.session

  defp session(chart, registry, id) do
    limits = Limits.default()

    Session.new!(%{
      id: id,
      incarnation: "#{id}-incarnation",
      chart_fingerprint: chart.fingerprint,
      registry_digest: registry.digest,
      limits_digest: Limits.digest(limits),
      registry_version: registry.version,
      profile_version: Profile.version(),
      invocation_remaining_descendants: limits.total_descendants
    })
  end

  defp options(registry), do: [registry: registry, limits: Limits.default()]
  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
end
