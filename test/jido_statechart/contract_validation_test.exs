defmodule Jido.Statechart.ContractValidationTest do
  use ExUnit.Case, async: true

  alias Jido.Statechart.{Diagnostic, Limits, Profile, Registry, Result, Session}
  alias Jido.Statechart.Model.{Chart, Event, Executable, Source, State, Transition}
  alias Jido.Statechart.Registry.Entry
  alias Jido.Statechart.Session.{Operation, Tombstone}

  @digest_a String.duplicate("a", 64)
  @digest_b String.duplicate("b", 64)

  defmodule TestAction do
    use Jido.Action, name: "contract_validation_action"

    @impl true
    def run(params, _context), do: {:ok, params}
  end

  test "operation identity binds every immutable delivery field" do
    attrs = operation_attrs()
    {:ok, baseline} = Operation.identity(attrs)

    changed = [
      %{attrs | session_incarnation: "incarnation-2"},
      %{attrs | kind: :send, due_at: nil},
      %{attrs | target: "child"},
      %{attrs | payload_digest: String.duplicate("d", 64)},
      %{attrs | due_at: "2026-10-06T12:00:01Z"},
      %{attrs | generation: 2}
    ]

    identities = Enum.map(changed, fn value -> Operation.identity(value) |> elem(1) end)
    assert Enum.uniq([baseline | identities]) == [baseline | identities]
    assert String.starts_with?(baseline, "op_v1_")

    assert {:error, %Diagnostic{code: :invalid_operation_identity_version}} =
             Operation.identity(Map.put(attrs, :identity_version, 2))

    assert {:error, %Diagnostic{code: :operation_identity_mismatch}} =
             Operation.new(Map.put(attrs, :id, "wrong"))

    operation = Operation.new!(attrs)
    assert {:ok, ^operation} = operation |> Operation.dump() |> Operation.load()

    assert {:error, %Diagnostic{code: :missing_operation_identity_version}} =
             operation
             |> Operation.dump()
             |> Map.delete("identity_version")
             |> Operation.load()
  end

  test "operation payload digest binds canonical correlation and timer shape" do
    attrs = operation_attrs() |> Map.put(:correlation, %{"event" => "notice"})

    assert {:error, %Diagnostic{code: :operation_payload_digest_mismatch}} =
             Operation.new(attrs)

    correlation = %{"event" => "notice"}
    digest = Diagnostic.digest(correlation)

    assert {:error, %Diagnostic{code: :invalid_operation_due_at}} =
             Operation.new(%{
               attrs
               | payload_digest: digest,
                 correlation: correlation,
                 kind: :timer,
                 due_at: nil
             })

    assert {:error, %Diagnostic{code: :invalid_operation_due_at}} =
             Operation.new(%{
               attrs
               | payload_digest: digest,
                 correlation: correlation,
                 kind: :send,
                 due_at: "2026-10-06T12:00:00Z"
             })

    assert {:error, %Diagnostic{code: :invalid_operation_timestamp}} =
             Operation.new(%{
               attrs
               | payload_digest: digest,
                 correlation: correlation,
                 kind: :timer,
                 due_at: "not-a-time"
             })
  end

  test "operation state combinations are explicit and restorable" do
    valid = [
      %{},
      %{state: :result_unknown, attempt_count: 1},
      %{state: :cancel_requested, attempt_count: 1},
      %{
        state: :retryable_failure,
        attempt_count: 1,
        result: %{"error" => "temporary"},
        result_revision: 2
      },
      %{
        state: :confirmed_complete,
        attempt_count: 1,
        result: %{"receipt" => "ok"},
        result_revision: 2,
        retention_class: :terminal
      },
      %{
        state: :permanent_failure,
        attempt_count: 1,
        result: %{"error" => "permanent"},
        result_revision: 2,
        retention_class: :audit
      }
    ]

    for override <- valid do
      operation = operation_attrs() |> Map.merge(override) |> Operation.new!()
      assert {:ok, ^operation} = operation |> Operation.dump() |> Operation.load()
    end

    invalid = [
      %{attempt_count: 1},
      %{result: %{"unexpected" => true}},
      %{state: :result_unknown, attempt_count: 0},
      %{state: :retryable_failure, attempt_count: 1},
      %{
        state: :retryable_failure,
        attempt_count: 1,
        result: %{"error" => true},
        result_revision: 0
      },
      %{
        state: :confirmed_complete,
        attempt_count: 1,
        result: %{"receipt" => true},
        result_revision: 2,
        retention_class: :active
      },
      %{retention_class: :terminal}
    ]

    for override <- invalid do
      assert {:error, %Diagnostic{code: :invalid_operation_combination}} =
               operation_attrs() |> Map.merge(override) |> Operation.new()
    end
  end

  test "strict session load requires each explicit supported contract version" do
    dump = session_fixture() |> Session.dump()

    for field <-
          ~w(schema_version runtime_protocol_version profile_version data_model_version registry_version limits_version) do
      assert {:error, %Diagnostic{code: :missing_session_version, path: [:session, missing]}} =
               dump |> Map.delete(field) |> Session.load()

      assert Atom.to_string(missing) == field
    end

    unsupported = [
      {"schema_version", 1},
      {"runtime_protocol_version", 1},
      {"profile_version", "other-profile"},
      {"data_model_version", "2"},
      {"limits_version", "2"}
    ]

    for {field, value} <- unsupported do
      assert {:error, %Diagnostic{code: :invalid_session_version}} =
               dump |> Map.put(field, value) |> Session.load()
    end

    assert {:error, %Diagnostic{code: :invalid_session_version}} =
             dump |> Map.put("registry_version", nil) |> Session.load()

    assert {:ok, _session} =
             Session.new(
               Map.take(dump, ~w(id incarnation chart_fingerprint registry_digest limits_digest))
             )
  end

  test "session stores and strictly validates its independent ID counters" do
    session = session_fixture(%{generated_id_counter: 7, operation_counter: 11})
    dump = Session.dump(session)

    assert dump["generated_id_counter"] == 7
    assert dump["operation_counter"] == 11
    assert {:ok, ^session} = Session.load(dump)

    for field <- ~w(generated_id_counter operation_counter) do
      assert {:error, %Diagnostic{code: :missing_session_counter, path: [:session, missing]}} =
               dump |> Map.delete(field) |> Session.load()

      assert Atom.to_string(missing) == field
    end

    for field <- [:generated_id_counter, :operation_counter], value <- [-1, 1.5, "1", nil] do
      assert {:error, %Diagnostic{code: :invalid_session_counter, path: [:session, ^field]}} =
               Session.new(Map.put(session, field, value))
    end

    assert {:ok, first} = Session.generated_send_id("session-1", "incarnation-1", 7)
    assert {:ok, second} = Session.generated_send_id("session-1", "incarnation-1", 8)
    assert {:ok, other_session} = Session.generated_send_id("session-2", "incarnation-1", 7)
    assert {:ok, other_incarnation} = Session.generated_send_id("session-1", "incarnation-2", 7)

    assert String.starts_with?(first, Session.generated_id_prefix())

    assert Enum.uniq([first, second, other_session, other_incarnation]) ==
             [first, second, other_session, other_incarnation]

    refute String.starts_with?(first, "op_v1_")
  end

  test "public map loaders reject unknown and atom-string duplicate fields" do
    assert_unknown_and_duplicate(&Limits.new/1, Limits.defaults(), :xml_bytes)

    entry = %{
      kind: :action,
      alias: "work",
      permissions: [],
      handler: __MODULE__,
      metadata: %{}
    }

    assert_unknown_and_duplicate(&Entry.new/1, entry, :kind)

    assert_unknown_and_duplicate(
      &Registry.new/1,
      %{version: "registry-1", entries: [entry]},
      :version
    )

    assert_unknown_and_duplicate(&Source.new/1, %{uri: "memory://chart", path: []}, :uri)
    assert_unknown_and_duplicate(&Event.new/1, %{name: "job.start", data: %{}}, :name)

    assert_unknown_and_duplicate(
      &Executable.new/1,
      %{kind: :log, ordinal: 0, data: %{}, children: []},
      :kind
    )

    assert_unknown_and_duplicate(
      &State.new/1,
      %{id: "state", ordinal: 0, kind: :atomic},
      :id
    )

    assert_unknown_and_duplicate(
      &Transition.new/1,
      %{id: "t", ordinal: 0, source_id: "state", target_ids: []},
      :id
    )

    assert_unknown_and_duplicate(&Operation.new/1, operation_attrs(), :kind)

    tombstone_attrs =
      terminal_operation(%{})
      |> Tombstone.from_operation()
      |> Tombstone.dump()

    assert {:error, %Diagnostic{code: :unknown_field}} =
             tombstone_attrs |> Map.put("unknown", true) |> Tombstone.new()

    assert {:error, %Diagnostic{code: :duplicate_field}} =
             tombstone_attrs
             |> Map.put(:state, tombstone_attrs["state"])
             |> Tombstone.new()

    assert {:error, %Diagnostic{code: :invalid_tombstone}} = Tombstone.new(:invalid)

    feature_attrs = %{
      id: :test_feature,
      status: :supported,
      w3c_section: "1",
      evidence_key: "test:feature"
    }

    assert_unknown_and_duplicate(&Profile.Feature.new/1, feature_attrs, :status)

    session_attrs = session_fixture() |> Map.from_struct()
    assert_unknown_and_duplicate(&Session.new/1, session_attrs, :status)

    result_attrs = %{session: session_fixture(), intents: [], trace: [], operation_counts: %{}}
    assert_unknown_and_duplicate(&Result.new/1, result_attrs, :trace)

    chart = chart_fixture()

    chart_attrs =
      chart |> Map.from_struct() |> Map.drop([:state_index, :transition_index, :fingerprint])

    assert_unknown_and_duplicate(&Chart.new/1, chart_attrs, :binding)
  end

  test "chart topology rejects duplicate lists and inconsistent reverse links" do
    chart = chart_fixture()
    [root, left, right] = chart.states
    [transition] = chart.transitions

    assert {:error, %Diagnostic{code: :duplicate_root_state}} =
             Chart.new(%{chart | root_state_ids: ["root", "root"]})

    assert {:error, %Diagnostic{code: :duplicate_id_reference}} =
             Chart.new(%{chart | states: [%{root | children: ["left", "left"]}, left, right]})

    assert {:error, %Diagnostic{code: :duplicate_id_reference}} =
             Chart.new(%{chart | states: [%{root | initial: ["left", "left"]}, left, right]})

    assert {:error, %Diagnostic{code: :duplicate_id_reference}} =
             Chart.new(%{
               chart
               | states: [root, %{left | transition_ids: ["move", "move"]}, right]
             })

    assert {:error, %Diagnostic{code: :duplicate_id_reference}} =
             Chart.new(%{chart | transitions: [%{transition | target_ids: ["right", "right"]}]})

    assert {:error, %Diagnostic{code: :invalid_parent}} =
             Chart.new(%{chart | states: [%{root | children: ["right"]}, left, right]})

    assert {:error, %Diagnostic{code: :invalid_parent}} =
             Chart.new(%{chart | states: [root, %{left | parent: "right"}, right]})

    assert {:error, %Diagnostic{code: :invalid_transition_source}} =
             Chart.new(%{chart | states: [root, %{left | transition_ids: []}, right]})

    assert {:error, %Diagnostic{code: :invalid_transition_source}} =
             Chart.new(%{
               chart
               | states: [root, left, %{right | transition_ids: ["move"]}]
             })
  end

  test "stored chart validates its derived indexes and fingerprint" do
    dump = chart_fixture() |> Chart.dump()
    assert {:ok, _chart} = Chart.load(dump)

    for field <- ~w(state_index transition_index fingerprint) do
      assert {:error, %Diagnostic{code: :missing_stored_field}} =
               dump |> Map.delete(field) |> Chart.load()
    end

    assert {:error, %Diagnostic{code: :stored_chart_mismatch, path: [:chart, :state_index]}} =
             Chart.load(%{dump | "state_index" => %{}})

    assert {:error, %Diagnostic{code: :stored_chart_mismatch, path: [:chart, :transition_index]}} =
             Chart.load(%{dump | "transition_index" => %{}})

    assert {:error, %Diagnostic{code: :stored_chart_mismatch, path: [:chart, :fingerprint]}} =
             Chart.load(%{dump | "fingerprint" => @digest_a})

    assert {:error, %Diagnostic{code: :unknown_field}} =
             dump |> Map.put("surprise", true) |> Chart.load()
  end

  test "terminal retention bounds operations and tombstones and keeps audit priority" do
    active = Operation.new!(operation_attrs(%{generation: 1}))

    terminal_2 =
      terminal_operation(%{generation: 2, result_revision: 2, result: %{"receipt" => 2}})

    terminal_3 =
      terminal_operation(%{generation: 3, result_revision: 3, result: %{"receipt" => 3}})

    audit =
      terminal_operation(%{
        generation: 4,
        result_revision: 1,
        result: %{"receipt" => 4},
        retention_class: :audit
      })

    session =
      session_fixture(%{
        revision_fence: 3,
        operation_counter: 5,
        operations: Map.new([active, terminal_2, terminal_3, audit], &{&1.id, &1})
      })

    collected = Session.collect_terminal(session, 2)
    assert Map.keys(collected.operations) == [active.id]
    assert map_size(collected.operation_tombstones) == 2
    assert Map.has_key?(collected.operation_tombstones, audit.id)
    assert Map.has_key?(collected.operation_tombstones, terminal_3.id)

    assert {:ok, restored} = collected |> Session.dump() |> Session.load()
    assert restored == collected

    fully_collected = Session.collect_terminal(collected, 0)
    assert fully_collected.operations == %{active.id => active}
    assert fully_collected.operation_tombstones == %{}

    assert {:error, %Diagnostic{code: :unknown_operation}} =
             Session.apply_operation_result(
               fully_collected,
               audit.id,
               audit.generation,
               audit.state,
               audit.result,
               audit.result_revision
             )

    replacement = Operation.new!(operation_attrs(%{generation: 5}))
    refute replacement.id == audit.id
  end

  test "older or equal results are stale before transition validation" do
    operation =
      Operation.new!(
        operation_attrs(%{
          state: :retryable_failure,
          attempt_count: 1,
          result_revision: 10,
          result: %{"error" => "temporary"}
        })
      )

    session =
      session_fixture(%{
        revision_fence: 10,
        operation_counter: operation.generation + 1,
        operations: %{operation.id => operation}
      })

    for revision <- [9, 10] do
      assert {:ok, ^session, :stale} =
               Session.apply_operation_result(
                 session,
                 operation.id,
                 operation.generation,
                 :canceled,
                 %{"result" => "late"},
                 revision
               )
    end

    assert {:error, %Diagnostic{code: :invalid_operation_transition}} =
             Session.apply_operation_result(
               session,
               operation.id,
               operation.generation,
               :canceled,
               %{"result" => "new"},
               11
             )
  end

  test "profile has one stable row for each declared feature" do
    expected = ~w(
      scxml_element state_atomic state_compound state_parallel state_final scxml_initial_default
      initial_element
      history_shallow history_deep transition_external transition_internal transition_targetless
      transition_multi_target transition_eventless event_descriptor_matching onentry_element
      onexit_element datamodel_element data_element donedata_element param_element content_element
      raise_element if_element
      elseif_element else_element foreach_element assign_element log_element send_element
      cancel_element executable_content_order executable_content_abort_on_error
      invoke_scxml_element invoke_idlocation_assignment invoke_generated_id_form
      invoke_generated_id_uniqueness invoke_data_model_injection invoke_input_metadata
      invoke_jido_element finalize_element invoke_autoforward
      binding_early binding_late internal_event_queue run_to_completion optimal_transition_set
      null_datamodel jido_datamodel in_predicate system_variables event_system_field_shape
      event_system_type event_system_send_id event_system_origin event_system_origin_type
      event_system_invoke_id event_system_name jido_action_extension script_element
      external_data_source external_content_source ecmascript_datamodel xpath_datamodel
      basic_http_event_io scxml_event_io_processor remote_invocation bounded_macrostep
      restricted_xml commit_then_dispatch post_commit_child_lifecycle dom_binding
    )a

    assert Enum.map(Profile.features(), & &1.id) == expected

    sections = Map.new(Profile.features(), &{&1.id, &1.w3c_section})

    assert Map.take(sections, [
             :datamodel_element,
             :data_element,
             :donedata_element,
             :param_element,
             :raise_element,
             :assign_element,
             :script_element,
             :basic_http_event_io,
             :bounded_macrostep,
             :restricted_xml,
             :commit_then_dispatch
           ]) == %{
             datamodel_element: "5.2",
             data_element: "5.3",
             donedata_element: "5.5",
             param_element: "5.7",
             raise_element: "4.2",
             assign_element: "5.4",
             script_element: "5.8",
             basic_http_event_io: "C.2",
             bounded_macrostep: "D",
             restricted_xml: "E",
             commit_then_dispatch: "6.2"
           }

    for feature <- Profile.features() do
      assert feature.evidence_key == "profile:#{feature.id}"

      if feature.status in [:unsupported, :deviation] do
        assert is_binary(feature.reason) and feature.reason != ""
      end
    end

    assert {:error, %Diagnostic{code: :missing_profile_reason}} =
             Profile.Feature.new(%{
               id: :unsupported_test,
               status: :unsupported,
               w3c_section: "1",
               evidence_key: "test:unsupported"
             })
  end

  test "diagnostics validate strings, identifiers, and portable UTF-8 values" do
    assert Diagnostic.new(:warning, "message", severity: :warning).severity == :warning
    assert Diagnostic.new(:bad_severity, "message", severity: :fatal).severity == :error
    assert Diagnostic.fetch(%{"name" => "value"}, :name) == "value"

    assert {:error, %Diagnostic{code: :invalid_string}} =
             Diagnostic.require_string(%{name: ""}, :name)

    assert {:ok, nil} = Diagnostic.optional_string(%{}, :name)

    assert {:error, %Diagnostic{code: :invalid_string}} =
             Diagnostic.optional_string(%{name: <<255>>}, :name)

    assert {:error, %Diagnostic{code: :invalid_string}} =
             Diagnostic.optional_string(%{name: 1}, :name)

    assert {:error, %Diagnostic{code: :invalid_id}} = Diagnostic.validate_id(1, [:id])
    assert {:error, %Diagnostic{code: :invalid_id}} = Diagnostic.validate_id("bad id", [:id])
    assert {:error, %Diagnostic{code: :non_portable_value}} = Diagnostic.portable(self(), [:data])

    for value <- [
          <<255>>,
          ["ok", <<255>>],
          {"ok", <<255>>},
          %{<<255>> => "bad"},
          %{"key" => <<255>>}
        ] do
      assert {:error, %Diagnostic{code: :non_portable_value}} =
               Diagnostic.portable(value, [:data])
    end

    assert_raise ArgumentError, fn ->
      Diagnostic.unwrap!({:error, Diagnostic.new(:expected, "failure")})
    end
  end

  test "Registry entry validation rejects unsafe capability descriptions" do
    valid = %{
      kind: :action,
      alias: "work",
      permissions: ["write:data", "write:data"],
      handler: TestAction,
      metadata: %{"team" => "runtime"}
    }

    assert {:ok, entry} = Entry.new(valid)
    assert entry.permissions == ["write:data"]
    assert {:ok, ^entry} = Entry.new(entry)
    assert {:ok, string_kind} = Entry.new(%{valid | kind: "action"})
    assert string_kind.kind == :action

    for attrs <- [
          %{valid | kind: "unknown"},
          %{valid | kind: 1},
          %{valid | alias: "bad alias"},
          %{valid | alias: 1},
          %{valid | permissions: [1]},
          %{valid | permissions: :all},
          %{valid | handler: nil},
          %{valid | handler: "Elixir.Module"},
          %{valid | metadata: self()},
          %{valid | metadata: %{pid: self()}}
        ] do
      assert {:error, %Diagnostic{}} = Entry.new(attrs)
    end

    assert {:error, %Diagnostic{code: :invalid_registry_entry}} = Entry.new(:invalid)
    assert {:error, %Diagnostic{code: :invalid_registry}} = Registry.new(:invalid)

    assert {:error, %Diagnostic{code: :invalid_registry}} =
             Registry.new(%{version: "registry-1", entries: :invalid})

    assert {:error, %Diagnostic{path: [:registry, :entries, 0 | _]}} =
             Registry.new(%{version: "registry-1", entries: [%{kind: :action}]})

    registry = Registry.new!(%{version: "registry-1", entries: [valid]})
    assert :error = Registry.fetch(registry, :action, "missing")
  end

  test "event and source boundaries reject malformed portable values" do
    source = Source.new!(%{})

    assert Source.dump(source) == %{
             "uri" => nil,
             "path" => [],
             "line" => nil,
             "column" => nil,
             "byte_offset" => nil
           }

    for attrs <- [
          %{uri: ""},
          %{uri: 1},
          %{path: "not-a-list"},
          %{path: [self()]},
          %{line: 0},
          %{column: "one"},
          %{byte_offset: -1}
        ] do
      assert {:error, %Diagnostic{code: :invalid_source}} = Source.new(attrs)
    end

    assert {:error, %Diagnostic{code: :invalid_source}} = Source.new(:invalid)

    event = Event.new!(%{name: "job.start", class: "internal", data: %{"ok" => true}})
    assert event.class == :internal
    assert Event.dump(event)["class"] == "internal"

    for attrs <- [
          %{name: "event", class: "unknown"},
          %{name: "event", class: 1},
          %{name: "event", data: self()},
          %{name: "event", message_id: 1}
        ] do
      assert {:error, %Diagnostic{}} = Event.new(attrs)
    end

    assert {:error, %Diagnostic{code: :invalid_event}} = Event.new(:invalid)
  end

  test "executable content validates nested commands, data, and source" do
    source = Source.new!(%{uri: "memory://chart"})
    child = %{kind: "log", ordinal: 0, data: %{"label" => "child"}, source: source}

    assert {:ok, executable} =
             Executable.new(%{
               kind: "if",
               ordinal: 0,
               data: %{},
               children: [child],
               source: Source.dump(source)
             })

    assert hd(executable.children).kind == :log
    assert Executable.dump(executable)["source"] == Source.dump(source)

    for attrs <- [
          %{kind: "unknown", ordinal: 0},
          %{kind: 1, ordinal: 0},
          %{kind: :log, ordinal: -1},
          %{kind: :log, ordinal: 0, data: []},
          %{kind: :log, ordinal: 0, data: %{pid: self()}},
          %{kind: :log, ordinal: 0, children: :invalid},
          %{kind: :log, ordinal: 0, children: [%{kind: :log}]},
          %{kind: :log, ordinal: 0, source: %{uri: ""}}
        ] do
      assert {:error, %Diagnostic{}} = Executable.new(attrs)
    end

    assert {:error, %Diagnostic{code: :invalid_executable}} = Executable.new(:invalid)
  end

  test "state validation covers identifiers, content, and state shapes" do
    executable = %{kind: :log, ordinal: 0, data: %{}}

    assert {:ok, state} =
             State.new(%{
               id: "state",
               ordinal: 0,
               kind: "compound",
               on_entry: [executable],
               on_exit: [executable],
               done_data: %{"ok" => true},
               generated: true
             })

    assert State.dump(state)["generated"]

    for attrs <- [
          %{id: "state", ordinal: 0, kind: :atomic, parent: "bad parent"},
          %{id: "state", ordinal: 0, kind: :atomic, children: :invalid},
          %{id: "state", ordinal: -1, kind: :atomic},
          %{id: "state", ordinal: 0, kind: 1},
          %{id: "state", ordinal: 0, kind: "unknown"},
          %{id: "state", ordinal: 0, kind: :atomic, on_entry: :invalid},
          %{id: "state", ordinal: 0, kind: :atomic, on_entry: [%{kind: :log}]},
          %{id: "state", ordinal: 0, kind: :atomic, data: []},
          %{id: "state", ordinal: 0, kind: :atomic, done_data: self()},
          %{id: "state", ordinal: 0, kind: :atomic, source: %{uri: ""}},
          %{id: "state", ordinal: 0, kind: :atomic, generated: 1},
          %{id: "state", ordinal: 0, kind: :atomic, children: ["child"]},
          %{id: "state", ordinal: 0, kind: :parallel, initial: ["child"]},
          %{id: "state", ordinal: 0, kind: :final, initial: ["child"]}
        ] do
      assert {:error, %Diagnostic{}} = State.new(attrs)
    end

    assert {:error, %Diagnostic{code: :invalid_state}} = State.new(:invalid)
  end

  test "transition validation covers targets, events, types, and content" do
    executable = %{kind: :log, ordinal: 0, data: %{}}

    assert {:ok, transition} =
             Transition.new(%{
               id: "move",
               ordinal: 0,
               source_id: "left",
               target_ids: ["right"],
               events: ["job.done"],
               type: "internal",
               executable: [executable],
               generated: true
             })

    assert Transition.dump(transition)["type"] == "internal"

    for attrs <- [
          %{id: "move", ordinal: -1, source_id: "left"},
          %{id: "move", ordinal: 0, source_id: "left", target_ids: :invalid},
          %{id: "move", ordinal: 0, source_id: "left", target_ids: ["bad target"]},
          %{id: "move", ordinal: 0, source_id: "left", events: :invalid},
          %{id: "move", ordinal: 0, source_id: "left", events: [""]},
          %{id: "move", ordinal: 0, source_id: "left", type: "unknown"},
          %{id: "move", ordinal: 0, source_id: "left", type: 1},
          %{id: "move", ordinal: 0, source_id: "left", executable: :invalid},
          %{id: "move", ordinal: 0, source_id: "left", executable: [%{kind: :log}]},
          %{id: "move", ordinal: 0, source_id: "left", source: %{uri: ""}},
          %{id: "move", ordinal: 0, source_id: "left", generated: 1}
        ] do
      assert {:error, %Diagnostic{}} = Transition.new(attrs)
    end

    assert {:error, %Diagnostic{code: :invalid_transition}} = Transition.new(:invalid)
  end

  test "result validation rejects malformed sessions, intents, traces, and counts" do
    session = session_fixture()
    operation = Operation.new!(operation_attrs())

    assert {:ok, result} =
             Result.new(%{
               session: session,
               intents: [operation],
               trace: [%{"step" => 1}],
               operation_counts: %{send: 1}
             })

    assert {:ok, ^result} = result |> Result.dump() |> Result.new()

    for attrs <- [
          %{session: %{}},
          %{session: session, intents: :invalid},
          %{session: session, intents: [%{}]},
          %{session: session, trace: :invalid},
          %{session: session, trace: [self()]},
          %{session: session, operation_counts: []},
          %{session: session, operation_counts: %{"send" => -1}}
        ] do
      assert {:error, %Diagnostic{}} = Result.new(attrs)
    end

    assert {:error, %Diagnostic{code: :invalid_result}} = Result.new(:invalid)
  end

  test "public inspection reports chart identity and completed session status safely" do
    chart = chart_fixture()
    inspected_chart = Jido.Statechart.inspect_chart(chart)
    assert inspected_chart["fingerprint"] == chart.fingerprint
    assert inspected_chart["state_count"] == 3
    assert Jido.Statechart.capabilities() == Profile.manifest()

    session = %{session_fixture() | status: :completed, trace: [%{"secret" => true}]}
    inspected_session = Jido.Statechart.inspect_session(session)
    assert inspected_session["completed"]
    assert inspected_session["trace_entries"] == 1
    assert inspected_session["generated_id_counter"] == 0
    assert inspected_session["operation_counter"] == 0
    refute Map.has_key?(inspected_session, "trace")
  end

  defp assert_unknown_and_duplicate(loader, attrs, duplicate_field) do
    assert {:error, %Diagnostic{code: :unknown_field}} = loader.(Map.put(attrs, "unknown", true))

    string_field = Atom.to_string(duplicate_field)
    duplicate = Map.put(attrs, string_field, Map.fetch!(attrs, duplicate_field))
    assert {:error, %Diagnostic{code: :duplicate_field}} = loader.(duplicate)
  end

  defp operation_attrs(overrides \\ %{}) do
    correlation = Map.get(overrides, :correlation, %{"kind" => "timer"})

    Map.merge(
      %{
        session_incarnation: "incarnation-1",
        kind: :timer,
        target: "parent",
        payload_digest: Diagnostic.digest(correlation),
        due_at: "2026-10-06T12:00:00Z",
        generation: 1,
        created_revision: 1,
        retention_class: :active,
        correlation: correlation
      },
      overrides
    )
  end

  defp terminal_operation(overrides) do
    operation_attrs(%{
      state: :confirmed_complete,
      attempt_count: 1,
      result_revision: 2,
      result: %{"receipt" => true},
      retention_class: :terminal
    })
    |> Map.merge(overrides)
    |> Operation.new!()
  end

  defp session_fixture(overrides \\ %{}) do
    Session.new!(
      Map.merge(
        %{
          id: "session-1",
          incarnation: "incarnation-1",
          chart_fingerprint: @digest_a,
          registry_digest: @digest_b,
          limits_digest: Limits.digest(Limits.default()),
          registry_version: "registry-1"
        },
        overrides
      )
    )
  end

  defp chart_fixture do
    source = Source.new!(%{uri: "memory://chart.scxml", path: ["scxml"], line: 1, column: 1})

    root =
      State.new!(%{
        id: "root",
        ordinal: 0,
        kind: :compound,
        children: ["left", "right"],
        initial: ["left"],
        source: source
      })

    left =
      State.new!(%{
        id: "left",
        ordinal: 1,
        kind: :atomic,
        parent: "root",
        transition_ids: ["move"],
        source: source
      })

    right =
      State.new!(%{id: "right", ordinal: 2, kind: :final, parent: "root", source: source})

    transition =
      Transition.new!(%{
        id: "move",
        ordinal: 0,
        source_id: "left",
        target_ids: ["right"],
        events: ["advance"],
        source: source
      })

    Chart.new!(%{
      id: "chart",
      profile_version: Profile.version(),
      datamodel: "jido",
      root_state_ids: ["root"],
      states: [root, left, right],
      transitions: [transition],
      metadata: %{"root_initial" => ["root"], "initial_transition_content" => %{}},
      source: source
    })
  end
end
