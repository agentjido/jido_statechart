defmodule Jido.Statechart.PluginTest do
  use ExUnit.Case, async: true

  alias Jido.Agent.Plugin.{Preparation, Reduction}
  alias Jido.Persistence.Plugin.Context
  alias Jido.Plugin.Input
  alias Jido.Statechart.Plugin.Commit
  alias Jido.Statechart.Session.{Operation, Tombstone}
  alias Jido.Statechart.{Chart, Diagnostic, Limits, Plugin, Profile, Result, SemanticFixture}

  defmodule BoundChart do
    @chart SemanticFixture.chart("""
           <state id="root" initial="idle">
             <state id="idle"><transition event="go" target="done"/></state>
             <final id="done"/>
           </state>
           """)
    @registry SemanticFixture.registry()
    use Chart, chart: @chart, registry: @registry
  end

  @options [chart: BoundChart, duplicate_window: 2]

  test "Commit is the only owner of session writes and validates compare-and-swap" do
    current =
      SemanticFixture.session(BoundChart.chart(), status: :active, configuration: ["idle"])

    next = %{
      current
      | revision: current.revision + 1,
        revision_fence: current.revision + 1,
        configuration: ["done"],
        status: :completed
    }

    plugin_state = Plugin.state(current)

    commit = %Commit{
      session: next,
      expected_revision: current.revision,
      signal_id: "signal-1",
      operation: :run
    }

    reduction = reduction(plugin_state, [commit])

    assert {:ok, state} = Plugin.reduce(reduction, @options)
    assert state.session == next
    assert state.recent_signal_ids == ["signal-1"]

    stale = %Commit{commit | expected_revision: current.revision + 1}

    assert {:error, {:statechart_compare_and_swap, 0, 1}} =
             Plugin.reduce(reduction(plugin_state, [stale]), @options)

    invalid_next = %Commit{
      commit
      | session: %{
          next
          | revision: current.revision + 2,
            revision_fence: current.revision + 2
        }
    }

    assert {:error, {:statechart_revision_jump, 0, 2}} =
             Plugin.reduce(reduction(plugin_state, [invalid_next]), @options)
  end

  test "self delivery records one durable operation receipt and rejects its replay" do
    correlation = %{
      "kind" => "send",
      "event" => "go",
      "data" => %{},
      "target" => "#_self"
    }

    operation =
      Operation.new!(%{
        session_incarnation: "incarnation-1",
        kind: :send,
        target: "#_self",
        key: "send:self-work",
        payload_digest: Diagnostic.digest(correlation),
        generation: 0,
        state: :result_unknown,
        attempt_count: 1,
        correlation: correlation
      })

    current =
      SemanticFixture.session(BoundChart.chart(), status: :active, configuration: ["idle"])
      |> Map.merge(%{
        operation_counter: 1,
        operation_high_water: %{"send:self-work" => 0},
        operations: %{operation.id => operation}
      })

    next = %{current | revision: 1, revision_fence: 1}
    result = Result.new!(%{session: next})

    prepared = %{
      kind: :macrostep,
      operation: :run,
      expected_revision: 0,
      signal_id: operation.id,
      receipt_operation_id: operation.id
    }

    input = %Input{prepared: prepared, runtime: %{authenticated_delivery: true}}
    context = %{agent_state: %{}, plugin_inputs: %{Plugin => input}}

    assert {:ok, %{}, [receipt_commit]} =
             Jido.Statechart.Plugin.Agent.run(%{result: result}, context)

    assert receipt_commit.session.received_operation_ids == [operation.id]

    signal = Jido.Signal.new!("go", %{}, id: operation.id, source: "/jido/statechart/session")
    {:ok, signal} = Jido.Signal.put_context(signal, "jidoscop", operation.id)

    preparation = %Preparation{
      plugin: Plugin,
      agent_id: "agent-1",
      agent_module: __MODULE__,
      agent_state: %{},
      signal: signal,
      plugin_state: Plugin.state(receipt_commit.session)
    }

    assert {:error, {:duplicate_signal, operation_id}} = Plugin.prepare(preparation, @options)
    assert operation_id == operation.id
  end

  test "reduction binds immutable session identity and preserves the durable ledger" do
    active = operation(:send, :not_started, generation: 0, created_revision: 0)

    current =
      BoundChart.chart()
      |> SemanticFixture.session(status: :active, configuration: ["idle"])
      |> then(&%{&1 | operations: %{active.id => active}, operation_counter: 1})

    swapped = %{current | id: "another-session", revision: 1, revision_fence: 1}

    assert {:error, {:statechart_immutable_session_field, :id}} =
             Plugin.reduce(
               reduction(Plugin.state(current), [commit(swapped, 0, "identity-swap")]),
               @options
             )

    deleted = %{current | revision: 1, revision_fence: 1, operations: %{}}

    assert {:error, {:statechart_operation_deleted, operation_id}} =
             Plugin.reduce(
               reduction(Plugin.state(current), [commit(deleted, 0, "ledger-delete")]),
               @options
             )

    assert operation_id == active.id

    guarded = %{
      current
      | revision_fence: 10,
        generated_id_counter: 10,
        initialized_data_state_ids: ["data-a"]
    }

    fence_reset = %{guarded | revision: 1, revision_fence: 1}

    assert {:error, :statechart_revision_fence_regression} =
             Plugin.reduce(
               reduction(Plugin.state(guarded), [commit(fence_reset, 0, "fence-reset")]),
               @options
             )

    counter_reset = %{guarded | revision: 1, revision_fence: 11, generated_id_counter: 0}

    assert {:error, :statechart_generated_id_counter_regression} =
             Plugin.reduce(
               reduction(Plugin.state(guarded), [commit(counter_reset, 0, "counter-reset")]),
               @options
             )

    data_reset = %{guarded | revision: 1, revision_fence: 11, initialized_data_state_ids: []}

    assert {:error, :statechart_initialized_data_regression} =
             Plugin.reduce(
               reduction(Plugin.state(guarded), [commit(data_reset, 0, "data-reset")]),
               @options
             )

    terminal =
      operation(:send, :confirmed_complete,
        generation: 0,
        created_revision: 0,
        attempt_count: 1,
        result_revision: 0,
        result: %{"ok" => true},
        retention_class: :terminal
      )

    terminal_current = %{current | operations: %{terminal.id => terminal}}
    regressed = operation(:send, :not_started, generation: 0, created_revision: 0)

    terminal_next = %{
      terminal_current
      | revision: 1,
        revision_fence: 1,
        operations: %{regressed.id => regressed}
    }

    assert {:error, {:statechart_operation_regression, terminal_id}} =
             Plugin.reduce(
               reduction(Plugin.state(terminal_current), [commit(terminal_next, 0, "regress")]),
               @options
             )

    assert terminal_id == terminal.id

    unknown =
      operation(:send, :result_unknown,
        generation: 0,
        created_revision: 0,
        attempt_count: 1
      )

    resolved =
      operation(:send, :confirmed_complete,
        generation: 0,
        created_revision: 0,
        attempt_count: 1,
        result_revision: 1,
        result: %{"ok" => true},
        retention_class: :terminal
      )

    unknown_current = %{current | operations: %{unknown.id => unknown}}

    resolved_next = %{
      unknown_current
      | revision: 1,
        revision_fence: 1,
        operations: %{resolved.id => resolved}
    }

    assert {:ok, resolved_state} =
             Plugin.reduce(
               reduction(Plugin.state(unknown_current), [commit(resolved_next, 0, "resolved")]),
               @options
             )

    assert resolved_state.session.operations == %{}

    assert resolved_state.session.operation_tombstones[resolved.id] ==
             Tombstone.from_operation(resolved)
  end

  test "reduction enforces committed session byte and operation pressure limits" do
    byte_limits = Limits.new!(%{session_bytes: 1_024})

    byte_current =
      SemanticFixture.session(BoundChart.chart(),
        status: :active,
        configuration: ["idle"],
        data: %{"payload" => String.duplicate("x", 2_000)},
        limits: byte_limits
      )

    byte_next = %{byte_current | revision: 1, revision_fence: 1}

    assert {:error, %Diagnostic{code: :session_size_limit_exceeded}} =
             Plugin.reduce(
               reduction(Plugin.state(byte_current), [commit(byte_next, 0, "bytes")]),
               chart: BoundChart,
               limits: byte_limits
             )

    for {kind, field, code} <- [
          {:send, :pending_sends, :pending_send_limit_exceeded},
          {:timer, :pending_timers, :pending_timer_limit_exceeded},
          {:invoke, :pending_invocations, :pending_invocation_limit_exceeded}
        ] do
      limits = Limits.new!(%{field => 0})

      current =
        SemanticFixture.session(BoundChart.chart(),
          status: :active,
          configuration: ["idle"],
          limits: limits
        )

      intent =
        operation(kind, :not_started,
          session_incarnation: current.incarnation,
          generation: 0,
          created_revision: 1
        )

      next = %{current | revision: 1, revision_fence: 1, operation_counter: 1}
      directive = commit(next, 0, "pressure-#{kind}", [intent])

      assert {:error, %Diagnostic{code: ^code}} =
               Plugin.reduce(reduction(Plugin.state(current), [directive]),
                 chart: BoundChart,
                 limits: limits
               )
    end

    terminal_limits = Limits.new!(%{terminal_records: 0})

    terminal =
      operation(:send, :confirmed_complete,
        attempt_count: 1,
        result_revision: 0,
        result: %{"ok" => true},
        retention_class: :terminal
      )

    terminal_current =
      BoundChart.chart()
      |> SemanticFixture.session(
        status: :active,
        configuration: ["idle"],
        limits: terminal_limits
      )
      |> then(&%{&1 | operations: %{terminal.id => terminal}, operation_counter: 1})

    terminal_next = %{terminal_current | revision: 1, revision_fence: 1}

    assert {:ok, terminal_state} =
             Plugin.reduce(
               reduction(Plugin.state(terminal_current), [commit(terminal_next, 0, "terminal")]),
               chart: BoundChart,
               limits: terminal_limits
             )

    assert terminal_state.session.operations == %{}
    assert terminal_state.session.operation_tombstones == %{}
  end

  test "reduction rejects a second Commit and invalid Commit data" do
    current =
      SemanticFixture.session(BoundChart.chart(), status: :active, configuration: ["idle"])

    next = %{current | revision: 1, revision_fence: 1}

    commit = %Commit{
      session: next,
      expected_revision: 0,
      signal_id: "signal-1",
      operation: :run
    }

    assert {:error, :multiple_statechart_commits} =
             Plugin.reduce(reduction(Plugin.state(current), [commit, commit]), @options)

    assert {:error, _reason} = Commit.validate(%Commit{commit | signal_id: ""})
    assert {:error, _reason} = Commit.validate(%Commit{commit | session: :invalid})
    assert {:error, _reason} = Commit.validate(%Commit{commit | intents: :invalid})
    assert {:error, _reason} = Commit.validate(%Commit{commit | intents: [:invalid]})
  end

  test "reduction binds Commit provenance to the prepared Signal and operation" do
    current =
      SemanticFixture.session(BoundChart.chart(), status: :active, configuration: ["idle"])

    next = %{current | revision: 1, revision_fence: 1}
    directive = commit(next, 0, "source-signal")
    valid = reduction(Plugin.state(current), [directive])

    foreign_signal =
      Jido.Signal.new!("go", %{}, id: "another-signal", source: "/another-route")

    assert {:error, :invalid_statechart_commit_provenance} =
             Plugin.reduce(%{valid | signal: foreign_signal}, @options)

    wrong_operation = put_in(valid.prepared_input.operation, :cleanup)

    assert {:error, :invalid_statechart_commit_provenance} =
             Plugin.reduce(wrong_operation, @options)

    stopped = %{next | status: :stopped}

    assert {:error, :invalid_statechart_commit_provenance} =
             Plugin.reduce(
               reduction(Plugin.state(current), [commit(stopped, 0, "illegal-status")]),
               @options
             )
  end

  test "the duplicate window evicts IDs in FIFO order" do
    session =
      SemanticFixture.session(BoundChart.chart(), status: :active, configuration: ["idle"])

    state =
      Enum.reduce(1..3, Plugin.state(session), fn index, state ->
        next = %{
          state.session
          | revision: state.session.revision + 1,
            revision_fence: state.session.revision + 1
        }

        commit = %Commit{
          session: next,
          expected_revision: state.session.revision,
          signal_id: "signal-#{index}",
          operation: :run
        }

        assert {:ok, next_state} = Plugin.reduce(reduction(state, [commit]), @options)
        next_state
      end)

    assert state.recent_signal_ids == ["signal-2", "signal-3"]
  end

  test "dump and load validate all stored execution contracts" do
    session =
      SemanticFixture.session(BoundChart.chart(), status: :active, configuration: ["idle"])

    state = Plugin.state(session, ["signal-1"])
    dump_context = context(:dump)
    load_context = context(:load)

    assert {:ok, stored} = Plugin.dump(state, dump_context, @options)
    assert stored["checkpoint_version"] == Plugin.checkpoint_version()
    assert stored["chart_fingerprint"] == BoundChart.chart().fingerprint
    assert stored["profile_version"] == Profile.version()

    assert stored["registry_manifest"] ==
             Jido.Statechart.Registry.manifest(BoundChart.registry())

    assert stored["limits"] == Limits.dump(Limits.default())
    refute inspect(stored) =~ "runtime_secret"

    assert {:ok, ^state} = Plugin.load(stored, load_context, @options)

    for {field, value} <- [
          {"checkpoint_version", Plugin.checkpoint_version() + 1},
          {"chart_fingerprint", String.duplicate("0", 64)},
          {"profile_version", "new-profile"},
          {"registry_manifest", %{"version" => "other", "entries" => [], "digest" => "bad"}},
          {"limits", Map.put(stored["limits"], "trace_entries", 1)}
        ] do
      assert {:error, _reason} =
               Plugin.load(Map.put(stored, field, value), load_context, @options)
    end

    assert {:error, :invalid_statechart_persistence_context} =
             Plugin.dump(state, load_context, @options)

    assert {:error, :invalid_statechart_persistence_context} =
             Plugin.load(stored, dump_context, @options)

    assert {:error, :invalid_statechart_checkpoint_fields} =
             Plugin.load(Map.put(stored, "unknown", true), load_context, @options)

    assert {:error, {:statechart_checkpoint_contract_mismatch, "duplicate_window"}} =
             Plugin.load(stored, load_context, chart: BoundChart, duplicate_window: 3)

    too_many_ids = Map.put(stored, "recent_signal_ids", ["one", "two", "three"])

    assert {:error, :statechart_duplicate_window_exceeded} =
             Plugin.load(too_many_ids, load_context, @options)

    assert {:error, :statechart_duplicate_window_exceeded} =
             Plugin.dump(Plugin.state(session, ["one", "two", "three"]), dump_context, @options)
  end

  test "profile-one checkpoints remain frozen and are rejected under profile two" do
    historical_fingerprint = "c33ab2f15a777fcca2ebccd8e3fa1fcb4a732996b49a94026097263b02e486e8"

    for version <- 1..5 do
      fixture = checkpoint_fixture(version)
      session = fixture["session"]

      assert session["profile_version"] == "jido-scxml-1.0/profile-1"
      assert session["chart_fingerprint"] == historical_fingerprint

      if version > 1 do
        assert fixture["profile_version"] == "jido-scxml-1.0/profile-1"
        assert fixture["chart_fingerprint"] == historical_fingerprint
      end

      assert {:error,
              {:statechart_checkpoint_profile_mismatch, "jido-scxml-1.0/profile-1",
               "jido-scxml-1.0/profile-2"}} = Plugin.migrate(fixture, @options)

      assert {:error,
              {:statechart_checkpoint_profile_mismatch, "jido-scxml-1.0/profile-1",
               "jido-scxml-1.0/profile-2"}} = Plugin.load(fixture, context(:load), @options)
    end

    assert {:error, {:unsupported_checkpoint_version, 0}} =
             Plugin.migrate(%{"checkpoint_version" => 0}, @options)

    assert {:error, :invalid_statechart_checkpoint} = Plugin.migrate(:invalid, @options)

    assert {:error, :invalid_statechart_v1_checkpoint} =
             Plugin.migrate(
               %{
                 "checkpoint_version" => 1,
                 "session" => %{"profile_version" => Profile.version()},
                 "signal_ids" => :invalid
               },
               @options
             )
  end

  test "the frozen profile-two checkpoint loads without migration changes" do
    fixture = checkpoint_fixture("profile_2")

    assert {:ok, ^fixture} = Plugin.migrate(fixture, @options)
    assert {:ok, state} = Plugin.load(fixture, context(:load), @options)
    assert_frozen_session(state, fixture["session"], :completed)
  end

  test "declared schema migrations preserve the current profile and chart identity" do
    current = checkpoint_fixture("profile_2")

    version_one = %{
      "checkpoint_version" => 1,
      "session" => current["session"],
      "signal_ids" => current["recent_signal_ids"]
    }

    version_two =
      current
      |> Map.put("checkpoint_version", 2)
      |> Map.delete("duplicate_window")

    version_three = Map.put(current, "checkpoint_version", 3)

    version_four =
      checkpoint_fixture(4)
      |> Map.put("profile_version", Profile.version())
      |> Map.put("chart_fingerprint", BoundChart.chart().fingerprint)
      |> Map.put("limits", current["limits"])
      |> Map.put("limits_version", current["limits_version"])
      |> put_in(["session", "profile_version"], Profile.version())
      |> put_in(["session", "chart_fingerprint"], BoundChart.chart().fingerprint)
      |> put_in(["session", "limits_digest"], current["session"]["limits_digest"])
      |> put_in(["session", "limits_version"], current["session"]["limits_version"])

    for legacy <- [version_one, version_two, version_three, version_four] do
      assert {:ok, migrated} = Plugin.migrate(legacy, @options)
      assert migrated["checkpoint_version"] == Plugin.checkpoint_version()
      assert migrated["profile_version"] == Profile.version()
      assert migrated["chart_fingerprint"] == BoundChart.chart().fingerprint
      assert migrated["session"]["profile_version"] == Profile.version()
      assert migrated["session"]["chart_fingerprint"] == BoundChart.chart().fingerprint
      assert {:ok, state} = Plugin.load(legacy, context(:load), @options)
      assert_frozen_session(state, migrated["session"], :completed)
    end

    assert {:ok, ^current} = Plugin.migrate(current, @options)
  end

  test "current checkpoints preserve an empty session and legacy profile is still rejected" do
    current = checkpoint_fixture("profile_2") |> Map.put("session", nil)
    legacy = checkpoint_fixture(4) |> Map.put("session", nil)

    assert {:ok, %{session: nil}} = Plugin.load(current, context(:load), @options)

    assert {:error,
            {:statechart_checkpoint_profile_mismatch, "jido-scxml-1.0/profile-1",
             "jido-scxml-1.0/profile-2"}} = Plugin.migrate(legacy, @options)
  end

  test "state validation rejects runtime handles and proof material" do
    state = Plugin.state(nil)
    assert :ok = Plugin.validate_state(state, [])
    assert {:error, _reason} = Plugin.validate_state(Map.put(state, :runtime, self()), [])
    assert {:error, _reason} = Plugin.validate_state(Map.put(state, :proof, "secret"), [])
  end

  test "restore rejects tampered revision and operation fences" do
    operation =
      operation(:send, :not_started,
        generation: 0,
        created_revision: 1
      )

    session =
      BoundChart.chart()
      |> SemanticFixture.session(status: :active, configuration: ["idle"])
      |> then(fn session ->
        %{
          session
          | revision: 1,
            revision_fence: 1,
            operation_counter: 1,
            operations: %{operation.id => operation}
        }
      end)

    assert {:ok, stored} = Plugin.dump(Plugin.state(session), context(:dump), @options)

    revision_tamper = put_in(stored, ["session", "revision_fence"], 0)

    assert {:error, %Diagnostic{code: :invalid_revision_fence}} =
             Plugin.load(revision_tamper, context(:load), @options)

    generation_tamper = put_in(stored, ["session", "operation_counter"], 0)

    assert {:error, %Diagnostic{code: :invalid_operation_fence}} =
             Plugin.load(generation_tamper, context(:load), @options)

    created_tamper =
      put_in(stored, ["session", "operations", operation.id, "created_revision"], 2)

    assert {:error, %Diagnostic{code: :invalid_operation_fence}} =
             Plugin.load(created_tamper, context(:load), @options)
  end

  test "cleanup requires confirmed safe timer and child outcomes" do
    base =
      SemanticFixture.session(BoundChart.chart(), status: :completed, configuration: ["done"])

    for state <- [:not_started, :result_unknown, :permanent_failure] do
      opts = operation_state_options(state)
      timer = operation(:timer, state, opts)
      session = %{base | operations: %{timer.id => timer}, operation_counter: 1}
      refute Plugin.cleanup_complete?(session)
    end

    timer =
      operation(:timer, :confirmed_complete,
        attempt_count: 1,
        result_revision: 0,
        result: %{"removed" => true},
        retention_class: :terminal
      )

    child_start =
      operation(:child_start, :confirmed_complete,
        generation: 1,
        target: "child-one",
        attempt_count: 1,
        result_revision: 0,
        result: %{"started" => true},
        retention_class: :terminal
      )

    matching_stop =
      operation(:child_stop, :confirmed_complete,
        generation: 2,
        target: "child-one",
        attempt_count: 1,
        result_revision: 0,
        result: %{"removed" => true},
        retention_class: :terminal
      )

    safe = %{
      base
      | operations: %{
          timer.id => timer,
          child_start.id => child_start,
          matching_stop.id => matching_stop
        },
        operation_counter: 3
    }

    assert Plugin.cleanup_complete?(safe)

    stale_stop =
      operation(:child_stop, :confirmed_complete,
        generation: 0,
        target: "child-one",
        attempt_count: 1,
        result_revision: 0,
        result: %{"removed" => true},
        retention_class: :terminal
      )

    refute Plugin.cleanup_complete?(%{
             base
             | operations: %{child_start.id => child_start, stale_stop.id => stale_stop},
               operation_counter: 2
           })

    unmatched_stop = %{matching_stop | target: "child-two"}

    refute Plugin.cleanup_complete?(%{
             base
             | operations: %{child_start.id => child_start, unmatched_stop.id => unmatched_stop},
               operation_counter: 3
           })

    tombstone = Tombstone.from_operation(child_start)

    assert Plugin.cleanup_complete?(%{
             base
             | operations: %{matching_stop.id => matching_stop},
               operation_tombstones: %{tombstone.id => tombstone},
               operation_counter: 3
           })

    refute Plugin.cleanup_complete?(%{
             base
             | operations: %{},
               operation_tombstones: %{tombstone.id => tombstone},
               operation_counter: 2
           })

    failed_invoke =
      operation(
        :invoke,
        :permanent_failure,
        operation_state_options(:permanent_failure) ++
          [generation: 3, target: "failed-child"]
      )

    failed_forward =
      operation(
        :child_start,
        :permanent_failure,
        operation_state_options(:permanent_failure) ++
          [generation: 4, target: "failed-child"]
      )

    proven_absent_start =
      operation(
        :invoke,
        :permanent_failure,
        operation_state_options(:permanent_failure) ++
          [
            generation: 6,
            target: "never-created-child",
            result: %{
              "outcome" => "failed",
              "value" => %{"reason" => "child_start_failed"}
            }
          ]
      )

    proven_absent_stop =
      operation(:child_stop, :confirmed_complete,
        generation: 5,
        target: "failed-child",
        attempt_count: 1,
        result_revision: 0,
        result: %{"outcome" => "stopped"},
        retention_class: :terminal
      )

    assert Plugin.cleanup_complete?(%{
             base
             | operations: %{
                 failed_invoke.id => failed_invoke,
                 failed_forward.id => failed_forward,
                 proven_absent_stop.id => proven_absent_stop
               },
               operation_counter: 6
           })

    assert Plugin.cleanup_complete?(%{
             base
             | operations: %{proven_absent_start.id => proven_absent_start},
               operation_counter: 7
           })

    absent_tombstone = Tombstone.from_operation(proven_absent_start)

    assert Plugin.cleanup_complete?(%{
             base
             | operation_tombstones: %{absent_tombstone.id => absent_tombstone},
               operation_counter: 7
           })

    refute Plugin.cleanup_complete?(%{
             base
             | operations: %{
                 failed_invoke.id => failed_invoke,
                 failed_forward.id => failed_forward
               },
               operation_counter: 5
           })

    uncertain_stop = %{proven_absent_stop | state: :result_unknown, retention_class: :active}

    refute Plugin.cleanup_complete?(%{
             base
             | operations: %{
                 failed_invoke.id => failed_invoke,
                 failed_forward.id => failed_forward,
                 uncertain_stop.id => uncertain_stop
               },
               operation_counter: 6
           })
  end

  defp reduction(plugin_state, directives) do
    directive = Enum.find(directives, &match?(%Commit{}, &1))
    signal_id = if directive, do: directive.signal_id, else: "signal"
    operation = if directive, do: directive.operation, else: :run

    signal_type =
      case operation do
        :initialize -> Jido.Statechart.Agent.initialization_signal_type()
        :cleanup -> Jido.Statechart.Agent.cleanup_signal_type()
        :run -> "go"
      end

    prepared =
      if directive do
        %{
          kind: if(operation == :cleanup, do: :cleanup, else: :macrostep),
          operation: operation,
          session: plugin_state.session,
          expected_revision: directive.expected_revision,
          signal_id: signal_id
        }
      end

    %Reduction{
      plugin: Plugin,
      agent_id: "agent-1",
      agent_module: __MODULE__,
      signal: Jido.Signal.new!(signal_type, %{}, id: signal_id, source: "/test"),
      state_before: %{statechart: plugin_state},
      state: %{statechart: plugin_state},
      plugin_state: plugin_state,
      prepared_input: prepared,
      directives: directives
    }
  end

  defp commit(session, expected_revision, signal_id, intents \\ []) do
    %Commit{
      session: session,
      expected_revision: expected_revision,
      signal_id: signal_id,
      operation: :run,
      intents: intents
    }
  end

  defp operation(kind, state, opts) do
    correlation = Keyword.get(opts, :correlation, %{"kind" => Atom.to_string(kind)})

    defaults = [
      session_incarnation: "incarnation-1",
      kind: kind,
      target: "target",
      payload_digest: Diagnostic.digest(correlation),
      due_at: if(kind == :timer, do: "2026-10-06T12:00:00Z", else: nil),
      generation: 0,
      state: state,
      created_revision: 0,
      correlation: correlation
    ]

    defaults
    |> Keyword.merge(opts)
    |> Map.new()
    |> Operation.new!()
  end

  defp operation_state_options(:not_started), do: []
  defp operation_state_options(:result_unknown), do: [attempt_count: 1]

  defp operation_state_options(:permanent_failure) do
    [
      attempt_count: 1,
      result_revision: 0,
      result: %{"error" => true},
      retention_class: :terminal
    ]
  end

  defp context(direction) do
    %Context{
      plugin: Plugin,
      plugin_vsn: 2,
      record_format: 3,
      direction: direction,
      reason: :test
    }
  end

  defp checkpoint_fixture(version) do
    suffix = if is_integer(version), do: "v#{version}", else: version

    Path.join([__DIR__, "..", "fixtures", "checkpoints", "statechart_#{suffix}.json"])
    |> File.read!()
    |> Jason.decode!()
  end

  defp assert_frozen_session(state, expected_dump, expected_status) do
    assert state.recent_signal_ids in [["signal-old"], ["signal-new"]]
    assert state.session.status == expected_status
    assert state.session.revision == 4
    assert state.session.revision_fence == 4
    assert state.session.generated_id_counter == 3
    assert state.session.operation_counter == 3
    assert map_size(state.session.operations) == 1
    assert map_size(state.session.operation_tombstones) == 1
    assert Jido.Statechart.Session.dump(state.session) == expected_dump
  end
end
