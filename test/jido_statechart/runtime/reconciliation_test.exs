defmodule Jido.Statechart.Runtime.ReconciliationTest do
  use ExUnit.Case, async: true

  alias Jido.Plugin.Input
  alias Jido.Statechart.Plugin
  alias Jido.Statechart.Plugin.{Cancel, RuntimeResult, Schedule}
  alias Jido.Statechart.Runtime.{Intent, Reconciler}
  alias Jido.Statechart.Session.Operation
  alias Jido.Statechart.Model.Event
  alias Jido.Statechart.{Flow, Limits, Registry, SemanticFixture, Session}

  @now ~U[2026-10-06 12:00:00Z]

  test "an internal send stays in the semantic macrostep" do
    chart =
      SemanticFixture.chart("""
      <state id="root">
        <transition event="start">
          <send event="inside" target="#_internal"/>
        </transition>
        <transition event="inside" target="done"/>
      </state>
      <final id="done"/>
      """)

    registry = Registry.new!(%{version: "registry-1", entries: []})
    session = SemanticFixture.session(chart, status: :active, configuration: ["root"])
    event = Event.new!(%{name: "start", class: :external})

    assert {:ok, result} = Flow.step(chart, session, event, registry, now: @now)
    assert result.intents == []
    assert result.session.status == :completed
    assert result.session.configuration == []
  end

  test "materializes complete immediate and delayed intent before dispatch" do
    {session, registry, limits} = fixture()

    assert {:ok, immediate} =
             Intent.from_semantic(
               %{
                 "kind" => "send",
                 "event" => "notice",
                 "target" => "#_self",
                 "send_id" => "one",
                 "data" => %{"value" => 1}
               },
               session,
               registry,
               limits,
               @now,
               generation: 0,
               created_revision: 1
             )

    assert immediate.kind == :send
    assert immediate.key == "send:one"
    assert immediate.due_at == nil
    assert immediate.state == :not_started

    assert {:ok, delayed} =
             Intent.from_semantic(
               %{
                 "kind" => "send",
                 "event" => "notice",
                 "target" => "#_self",
                 "send_id" => "one",
                 "delay" => "5s",
                 "data" => %{"value" => 2}
               },
               session,
               registry,
               limits,
               @now,
               generation: 1,
               created_revision: 1
             )

    assert delayed.kind == :timer
    assert delayed.due_at == "2026-10-06T12:00:05.000Z"
    assert delayed.id != immediate.id
    assert delayed.payload_digest == Jido.Statechart.Diagnostic.digest(delayed.correlation)
  end

  test "rejects an event-selected runtime target before intent commit" do
    {session, registry, limits} = fixture()

    assert {:error, %Jido.Statechart.Diagnostic{code: :dynamic_runtime_target}} =
             Intent.from_semantic(
               %{
                 "kind" => "send",
                 "event" => "notice",
                 "target" => "#_self",
                 "target_selected" => true
               },
               session,
               registry,
               limits,
               @now
             )
  end

  test "plans attempt commit before dispatch and reuses one operation ID for uncertainty" do
    {session, _registry, limits} = fixture()
    operation = operation(session, 0, :not_started)
    session = put_operation(session, operation)

    assert [{:schedule, ^operation}] = Reconciler.plan(session, @now, limits)

    unknown = %{operation | state: :result_unknown, attempt_count: 1}
    session = %{session | operations: %{unknown.id => unknown}}

    assert [{:dispatch, ^unknown}] = Reconciler.plan(session, @now, limits)
    assert unknown.id == operation.id

    retry_at = "2026-10-06T12:00:02.000Z"

    failed = %{
      unknown
      | state: :retryable_failure,
        result_revision: 2,
        result: %{"reason" => "unavailable"},
        next_attempt_at: retry_at
    }

    session = %{session | operations: %{failed.id => failed}, revision: 2, revision_fence: 2}
    assert [] = Reconciler.plan(session, ~U[2026-10-06 12:00:01Z], limits)
    assert [{:schedule, ^failed}] = Reconciler.plan(session, ~U[2026-10-06 12:00:02Z], limits)
  end

  test "a stale schedule control cannot increment an in-flight attempt" do
    {session, _registry, _limits} = fixture()
    operation = operation(session, 0, :not_started)
    session = put_operation(session, operation)
    context = schedule_context(session, operation, "schedule-once")

    assert {:ok, %{kept: true}, [commit]} = Schedule.run(%{}, context)

    scheduled = commit.session.operations[operation.id]
    assert scheduled.state == :result_unknown
    assert scheduled.attempt_count == 1
    assert scheduled.next_attempt_at == nil

    stale_context = schedule_context(commit.session, scheduled, "schedule-stale")

    assert {:error, _reason} = Schedule.run(%{}, stale_context)
    assert commit.session.operations[operation.id].attempt_count == 1

    retryable = %{
      scheduled
      | next_attempt_at: DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.to_iso8601()
    }

    retry_session = %{commit.session | operations: %{retryable.id => retryable}}

    assert {:ok, %{kept: true}, [retry_commit]} =
             Schedule.run(%{}, schedule_context(retry_session, retryable, "schedule-retry"))

    assert retry_commit.session.operations[operation.id].attempt_count == 2
  end

  test "replacement and explicit cancellation fence old timer generations" do
    {session, _registry, limits} = fixture()

    old =
      operation(session, 0, :not_started, key: "send:shared", due_at: "2026-10-06T12:01:00.000Z")

    new =
      operation(session, 1, :not_started,
        key: "send:shared",
        due_at: "2026-10-06T12:02:00.000Z",
        data: 2
      )

    correlation = %{"kind" => "cancel", "send_id" => "shared"}

    cancel =
      Operation.new!(%{
        session_incarnation: session.incarnation,
        kind: :cancel,
        target: "send:shared",
        key: "send:shared",
        payload_digest: Jido.Statechart.Diagnostic.digest(correlation),
        generation: 2,
        created_revision: 1,
        correlation: correlation
      })

    session =
      %{session | operation_counter: 3, operations: Map.new([old, new, cancel], &{&1.id, &1})}

    assert [
             {:cancel_replaced, ^old, ^new},
             {:cancel, ^cancel, ^new}
           ] = Reconciler.plan(session, @now, limits)
  end

  test "a terminal high-water generation still fences an older active timer" do
    {session, _registry, limits} = fixture()

    old =
      operation(session, 0, :not_started, key: "send:shared", due_at: "2026-10-06T12:01:00.000Z")

    latest =
      terminal_operation(session, 1)
      |> Map.put(:key, "send:shared")

    session =
      %{session | operation_counter: 2, operations: Map.new([old, latest], &{&1.id, &1})}

    assert [{:cancel_replaced, ^old, ^latest}] = Reconciler.plan(session, @now, limits)
  end

  test "a collected keyed generation still fences an older active timer" do
    {session, _registry, limits} = fixture()

    old =
      operation(session, 0, :not_started, key: "send:shared", due_at: "2026-10-06T12:01:00.000Z")

    session = %{
      session
      | operation_counter: 2,
        operation_high_water: %{"send:shared" => 1},
        operations: %{old.id => old}
    }

    assert [{:cancel_stale, ^old, 1}] = Reconciler.plan(session, @now, limits)
  end

  test "terminal collection never removes active or result-unknown work" do
    {session, _registry, _limits} = fixture()
    active = operation(session, 0, :not_started)
    unknown = operation(session, 1, :result_unknown, attempts: 1, data: 2)
    terminal = terminal_operation(session, 2)

    session =
      %{
        session
        | operation_counter: 3,
          operations: Map.new([active, unknown, terminal], &{&1.id, &1})
      }

    collected = Session.collect_terminal(session, 0)
    assert Map.keys(collected.operations) |> Enum.sort() == Enum.sort([active.id, unknown.id])
    assert collected.operation_tombstones == %{}
  end

  test "a late delivery result cannot reopen a canceled generation" do
    {session, _registry, _limits} = fixture()

    canceled =
      operation(session, 0, :not_started)
      |> Map.merge(%{
        state: :canceled,
        attempt_count: 1,
        result_revision: 1,
        result: %{"reason" => "cancel"},
        retention_class: :terminal
      })
      |> Operation.new!()

    session = %{
      session
      | revision: 1,
        revision_fence: 1,
        operation_counter: 1,
        operations: %{canceled.id => canceled}
    }

    input = %Input{
      prepared: %{
        kind: :runtime_result,
        session: session,
        operation_id: canceled.id,
        generation: canceled.generation,
        result_state: :confirmed_complete,
        result: %{"outcome" => "late"},
        signal_id: "late-result"
      },
      runtime: %{authenticated_reserved: true}
    }

    context = %{agent_state: %{kept: true}, plugin_inputs: %{Plugin => input}}

    assert {:ok, %{kept: true}, [commit]} = RuntimeResult.run(%{}, context)
    assert commit.session.revision == 2
    assert commit.session.operations[canceled.id] == canceled
  end

  test "not-started cancellation stays attempt zero and in-flight cancellation fences before completion" do
    {session, _registry, _limits} = fixture()
    waiting = operation(session, 0, :not_started, key: "send:shared")
    cancel = cancel_operation(session, 1, "send:shared")

    waiting_session = %{
      session
      | operation_counter: 2,
        operation_high_water: %{"send:shared" => 1},
        operations: Map.new([waiting, cancel], &{&1.id, &1})
    }

    assert {:ok, _state, [waiting_commit]} =
             Cancel.run(%{}, cancel_context(waiting_session, cancel, waiting, "cancel"))

    assert %{state: :canceled, attempt_count: 0} =
             waiting_commit.session.operations[waiting.id]

    assert %{state: :confirmed_complete} = waiting_commit.session.operations[cancel.id]

    running = operation(session, 0, :result_unknown, key: "send:shared", attempts: 1)

    running_session = %{
      session
      | operation_counter: 2,
        operation_high_water: %{"send:shared" => 1},
        operations: Map.new([running, cancel], &{&1.id, &1})
    }

    assert {:ok, _state, [requested_commit]} =
             Cancel.run(%{}, cancel_context(running_session, cancel, running, "cancel"))

    assert %{state: :cancel_requested} = requested_commit.session.operations[running.id]
    assert %{state: :cancel_requested} = requested_commit.session.operations[cancel.id]

    assert [{:confirm_cancel, _running}] =
             Reconciler.plan(requested_commit.session, @now, Limits.default())

    assert {:ok, _state, [still_requested_commit]} =
             Cancel.run(
               %{},
               cancel_context(requested_commit.session, cancel, running, "cancel")
             )

    assert %{state: :cancel_requested} = still_requested_commit.session.operations[cancel.id]

    confirm_context =
      cancel_context(requested_commit.session, running, running, "confirm_cancel")

    assert {:ok, _state, [confirmed_commit]} = Cancel.run(%{}, confirm_context)
    assert %{state: :canceled, attempt_count: 1} = confirmed_commit.session.operations[running.id]

    assert {:ok, _state, [completed_cancel_commit]} =
             Cancel.run(
               %{},
               cancel_context(confirmed_commit.session, cancel, running, "complete_cancel")
             )

    assert %{state: :confirmed_complete} = completed_cancel_commit.session.operations[cancel.id]

    assert {:ok, _state, [replacement_commit]} =
             Cancel.run(
               %{},
               cancel_context(running_session, running, running, "cancel_replaced")
             )

    assert %{state: :cancel_requested} = replacement_commit.session.operations[running.id]

    assert {:ok, _state, [unchanged_commit]} =
             Cancel.run(
               %{},
               cancel_context(confirmed_commit.session, running, running, "confirm_cancel")
             )

    assert %{state: :canceled} = unchanged_commit.session.operations[running.id]
  end

  defp fixture do
    chart = SemanticFixture.chart(~s(<state id="root"/>))
    registry = Registry.new!(%{version: "registry-1", entries: []})
    limits = Limits.new!(%{timer_horizon_ms: 60_000, reconciliation_batch: 10})

    session =
      SemanticFixture.session(chart,
        registry: registry,
        limits: limits,
        status: :active,
        configuration: ["root"]
      )

    {session, registry, limits}
  end

  defp operation(session, generation, state, options \\ []) do
    attempts = Keyword.get(options, :attempts, 0)

    correlation = %{
      "kind" => "send",
      "event" => "notice",
      "target" => "#_self",
      "send_id" => "#{generation}",
      "data" => Keyword.get(options, :data, 1)
    }

    Operation.new!(%{
      session_incarnation: session.incarnation,
      kind: if(Keyword.get(options, :due_at), do: :timer, else: :send),
      target: "#_self",
      key: Keyword.get(options, :key, "send:#{generation}"),
      payload_digest: Jido.Statechart.Diagnostic.digest(correlation),
      due_at: Keyword.get(options, :due_at),
      generation: generation,
      state: state,
      attempt_count: attempts,
      created_revision: 1,
      correlation: correlation
    })
  end

  defp terminal_operation(session, generation) do
    operation(session, generation, :not_started)
    |> Map.merge(%{
      state: :confirmed_complete,
      attempt_count: 1,
      result_revision: 1,
      result: %{"ok" => true},
      retention_class: :terminal
    })
    |> Operation.new!()
  end

  defp cancel_operation(session, generation, key) do
    correlation = %{"kind" => "cancel", "send_id" => String.replace_prefix(key, "send:", "")}

    Operation.new!(%{
      session_incarnation: session.incarnation,
      kind: :cancel,
      target: key,
      key: key,
      payload_digest: Jido.Statechart.Diagnostic.digest(correlation),
      generation: generation,
      created_revision: session.revision,
      correlation: correlation
    })
  end

  defp cancel_context(session, operation, target, reason) do
    input = %Input{
      prepared: %{
        kind: :runtime_cancel,
        session: session,
        operation_id: operation.id,
        target_operation_id: target.id,
        reason: reason,
        signal_id: "cancel-#{reason}-#{operation.id}"
      },
      runtime: %{authenticated_reserved: true}
    }

    %{agent_state: %{}, plugin_inputs: %{Plugin => input}}
  end

  defp schedule_context(session, operation, signal_id) do
    input = %Input{
      prepared: %{
        kind: :runtime_schedule,
        session: session,
        operation_id: operation.id,
        generation: operation.generation,
        signal_id: signal_id
      },
      runtime: %{authenticated_reserved: true}
    }

    %{agent_state: %{kept: true}, plugin_inputs: %{Plugin => input}}
  end

  defp put_operation(session, operation) do
    %{
      session
      | operation_counter: operation.generation + 1,
        operations: %{operation.id => operation}
    }
  end
end
