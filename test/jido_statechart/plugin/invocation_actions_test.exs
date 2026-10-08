defmodule Jido.Statechart.Plugin.InvocationActionsTest do
  use ExUnit.Case, async: true

  alias Jido.Agent.Directive.SpawnChild
  alias Jido.Plugin.Input
  alias Jido.Statechart.Plugin

  alias Jido.Statechart.Plugin.{
    ChildControlAck,
    ChildResult,
    Invoke,
    OwnedChildControl,
    StopInvoke
  }

  alias Jido.Statechart.Runtime.{Invocation, Reconciler}
  alias Jido.Statechart.{Limits, SemanticFixture}

  defmodule WorkerAgent do
    use Jido.Agent, name: "statechart_plugin_invocation_worker"

    agent do
      schema(Zoi.object(%{job: Zoi.string() |> Zoi.default("none")}))
    end
  end

  defmodule ParentChart do
    @chart Jido.Statechart.SemanticFixture.chart("""
           <state id="root">
             <transition event="done.invoke.worker" target="done"/>
             <transition event="error.communication" target="done"/>
           </state>
           <final id="done"/>
           """)
    @registry Jido.Statechart.Registry.new!(%{
                version: "plugin-invocation-1",
                entries: [
                  %{
                    kind: :invocation,
                    alias: "worker-capability",
                    permissions: ["invoke:jido", "scope:local"],
                    metadata: %{"type" => "jido", "input_mode" => "initial_state"},
                    handler: Jido.Statechart.Plugin.InvocationActionsTest.WorkerAgent
                  }
                ]
              })
    use Jido.Statechart.Chart, chart: @chart, registry: @registry
  end

  test "Invoke rechecks committed desire and returns one temporary SpawnChild" do
    {session, registry, operation} = fixture()
    context = context(:runtime_invoke, session, operation, registry)

    assert {:ok, %{kept: true}, [commit, %SpawnChild{} = spawn]} = Invoke.run(%{}, context)
    assert commit.operation == :invoke
    assert commit.session.revision == session.revision + 1
    assert commit.session.operations[operation.id].state == :result_unknown
    assert spawn.agent == WorkerAgent
    assert spawn.tag == operation.target
    assert spawn.restart == :temporary
    assert spawn.opts.initial_state == %{"job" => "one"}
    assert spawn.meta["jido_statechart_operation_id"] == operation.id
  end

  test "Invoke does not spawn after a correlated stop is committed" do
    {session, registry, invoke} = fixture()

    {:ok, stop} =
      Invocation.from_semantic(
        %{
          "kind" => "stop_invoke",
          "invoke_id" => "worker",
          "owner_state_id" => "root"
        },
        session,
        registry,
        Limits.default(),
        DateTime.utc_now(),
        generation: 1,
        created_revision: 1,
        prior_operations: [invoke]
      )

    session = %{
      session
      | operation_counter: 2,
        operations: %{invoke.id => invoke, stop.id => stop}
    }

    assert {:error, :statechart_invocation_no_longer_desired} =
             Invoke.run(%{}, context(:runtime_invoke, session, invoke, registry))
  end

  test "StopInvoke retains cancellation while start is pending and returns StopChild" do
    {session, registry, invoke} = fixture()
    invoke = %{invoke | state: :result_unknown, attempt_count: 1}

    {:ok, stop} =
      Invocation.from_semantic(
        %{
          "kind" => "stop_invoke",
          "invoke_id" => "worker",
          "owner_state_id" => "root"
        },
        session,
        registry,
        Limits.default(),
        DateTime.utc_now(),
        generation: 1,
        created_revision: 1,
        prior_operations: [invoke]
      )

    session = %{
      session
      | operation_counter: 2,
        operations: %{invoke.id => invoke, stop.id => stop}
    }

    context = context(:runtime_stop_invoke, session, stop, registry)

    assert {:ok, %{kept: true}, [commit, %OwnedChildControl{} = directive]} =
             StopInvoke.run(%{}, context)

    assert commit.operation == :stop_invoke
    assert commit.session.operations[stop.id].state == :result_unknown
    assert commit.session.operations[invoke.id].state == :cancel_requested
    assert directive.tag == invoke.target
    assert directive.invoke_operation_id == invoke.id
    assert {:ok, ^directive} = OwnedChildControl.validate(directive)
    assert {:error, :invalid_statechart_owned_child_control} = OwnedChildControl.validate(%{})
  end

  test "ChildResult emits done.invoke once and records a durable stop" do
    {session, _registry, invoke} = fixture()
    invoke = %{invoke | state: :result_unknown, attempt_count: 1}
    session = %{session | operations: %{invoke.id => invoke}}
    context = child_context(session, invoke, "done", %{"answer" => 42})

    assert {:ok, %{kept: true}, [commit]} = ChildResult.run(%{}, context)

    assert commit.operation == :child_result
    assert commit.session.status == :completed
    assert commit.session.operations[invoke.id].state == :confirmed_complete
    assert [%{kind: :child_stop, target: target} = stop] = commit.intents
    assert target == invoke.target
    assert stop.correlation["invoke_operation_id"] == invoke.id

    restored = %{
      commit.session
      | operations: Map.put(commit.session.operations, stop.id, stop),
        operation_high_water:
          Map.put(commit.session.operation_high_water, stop.key, stop.generation)
    }

    assert [{:stop_invoke, ^stop}] =
             Reconciler.plan(restored, DateTime.utc_now(), Limits.default())

    duplicate = child_context(commit.session, invoke, "done", %{"answer" => 42})
    assert {:ok, %{kept: true}, []} = ChildResult.run(%{}, duplicate)
  end

  test "ChildResult confirms restored starts and ignores completion after cancellation" do
    {session, _registry, invoke} = fixture()

    assert {:ok, %{kept: true}, [commit]} =
             ChildResult.run(%{}, child_context(session, invoke, "started", %{}))

    assert commit.session.operations[invoke.id].state == :result_unknown

    canceled = %{
      invoke
      | state: :cancel_requested,
        attempt_count: 1
    }

    canceled_session = %{session | operations: %{canceled.id => canceled}}

    assert {:ok, %{kept: true}, []} =
             ChildResult.run(
               %{},
               child_context(canceled_session, canceled, "done", %{"late" => true})
             )
  end

  test "ChildResult converts a child failure to a later communication event" do
    {session, _registry, invoke} = fixture()
    invoke = %{invoke | state: :result_unknown, attempt_count: 1}
    session = %{session | operations: %{invoke.id => invoke}}

    assert {:ok, %{kept: true}, [commit]} =
             ChildResult.run(
               %{},
               child_context(session, invoke, "failed", %{"reason" => "child_exit"})
             )

    assert commit.session.status == :completed
    assert commit.session.operations[invoke.id].state == :permanent_failure
    assert commit.intents == []

    may_exist =
      child_context(session, invoke, "failed", %{"reason" => "child_initialization_failed"})

    assert {:ok, %{kept: true}, [may_exist_commit]} = ChildResult.run(%{}, may_exist)
    assert [%{kind: :child_stop}] = may_exist_commit.intents
  end

  test "ChildResult confirms stop and autoforward operations" do
    {session, registry, invoke} = fixture()
    invoke = %{invoke | state: :cancel_requested, attempt_count: 1}

    {:ok, stop} =
      Invocation.from_semantic(
        %{
          "kind" => "stop_invoke",
          "invoke_id" => "worker",
          "owner_state_id" => "root"
        },
        session,
        registry,
        Limits.default(),
        DateTime.utc_now(),
        generation: 1,
        created_revision: 1,
        prior_operations: [%{invoke | state: :result_unknown}]
      )

    stop = %{stop | state: :result_unknown, attempt_count: 1}

    stopped_session = %{
      session
      | operation_counter: 2,
        operation_high_water: %{
          invoke.key => invoke.generation,
          stop.key => stop.generation
        },
        operations: %{invoke.id => invoke, stop.id => stop}
    }

    assert {:ok, %{kept: true}, [stop_commit]} =
             ChildResult.run(%{}, child_context(stopped_session, stop, "stopped", %{}))

    assert stop_commit.session.operations[stop.id].state == :confirmed_complete
    assert stop_commit.session.operations[invoke.id].state == :canceled

    active = %{invoke | state: :result_unknown}

    {:ok, forward} =
      Invocation.from_semantic(
        %{
          "kind" => "invoke_send",
          "invoke_id" => "worker",
          "event" => %{"name" => "notice", "class" => "external", "data" => %{}}
        },
        session,
        registry,
        Limits.default(),
        DateTime.utc_now(),
        generation: 1,
        created_revision: 1,
        prior_operations: [active]
      )

    forward = %{forward | state: :result_unknown, attempt_count: 1}

    forwarded_session = %{
      session
      | operation_counter: 2,
        operations: %{active.id => active, forward.id => forward}
    }

    assert {:ok, %{kept: true}, [forward_commit]} =
             ChildResult.run(
               %{},
               child_context(forwarded_session, forward, "forwarded", %{})
             )

    assert forward_commit.session.operations[forward.id].state == :confirmed_complete
  end

  test "Invoke commits a forward attempt before emit and acknowledges only after emit" do
    {session, registry, invoke} = fixture()
    active = %{invoke | state: :result_unknown, attempt_count: 1}

    {:ok, forward} =
      Invocation.from_semantic(
        %{
          "kind" => "invoke_send",
          "invoke_id" => "worker",
          "event" => %{"name" => "notice", "data" => %{}}
        },
        session,
        registry,
        Limits.default(),
        DateTime.utc_now(),
        generation: 1,
        created_revision: 1,
        prior_operations: [active]
      )

    forwarded = %{
      session
      | operation_counter: 2,
        operations: %{active.id => active, forward.id => forward}
    }

    assert {:ok, %{kept: true}, [commit, %OwnedChildControl{} = owned, %ChildControlAck{} = ack]} =
             Invoke.run(%{}, context(:runtime_invoke_forward, forwarded, forward, registry))

    assert commit.session.operations[forward.id].state == :result_unknown
    assert ack.operation_id == forward.id
    assert ack.generation == forward.generation
    assert ack.session_incarnation == forward.session_incarnation
    assert owned.invoke_operation_id == active.id
    assert {:ok, ^owned} = OwnedChildControl.validate(owned)
    assert {:ok, ^ack} = ChildControlAck.validate(ack)

    assert {:error, :invalid_statechart_child_control_ack} =
             ChildControlAck.validate(%ChildControlAck{
               session_incarnation: "",
               operation_id: "",
               generation: -1
             })

    assert {:error, :invalid_statechart_owned_child_control} =
             OwnedChildControl.validate(%{owned | signal: nil})
  end

  test "ChildResult records stop failure before a later communication event" do
    {session, registry, invoke} = fixture()
    invoke = %{invoke | state: :cancel_requested, attempt_count: 1}

    {:ok, stop} =
      Invocation.from_semantic(
        %{
          "kind" => "stop_invoke",
          "invoke_id" => "worker",
          "owner_state_id" => "root"
        },
        session,
        registry,
        Limits.default(),
        DateTime.utc_now(),
        generation: 1,
        created_revision: 1,
        prior_operations: [%{invoke | state: :result_unknown}]
      )

    stop = %{stop | state: :result_unknown, attempt_count: 2}

    failed_session = %{
      session
      | operation_counter: 2,
        operation_high_water: %{
          invoke.key => invoke.generation,
          stop.key => stop.generation
        },
        operations: %{invoke.id => invoke, stop.id => stop}
    }

    assert {:ok, %{kept: true}, [commit]} =
             ChildResult.run(
               %{},
               child_context(failed_session, stop, "failed", %{"reason" => "stop_failed"})
             )

    assert commit.session.operations[stop.id].state == :permanent_failure
    assert commit.session.status == :completed
  end

  test "control retries advance the durable attempt count and due time" do
    {session, registry, invoke} = fixture()
    invoke = %{invoke | state: :result_unknown, attempt_count: 1}
    session = %{session | operations: %{invoke.id => invoke}}

    assert {:ok, %{kept: true}, [commit, %SpawnChild{}]} =
             Invoke.run(%{}, context(:runtime_invoke, session, invoke, registry))

    retried = commit.session.operations[invoke.id]
    assert retried.attempt_count == 2
    assert is_binary(retried.next_attempt_at)
  end

  defp fixture do
    chart = ParentChart.chart()
    registry = ParentChart.registry()

    session =
      SemanticFixture.session(chart,
        registry: registry,
        status: :active,
        configuration: ["root"]
      )

    {:ok, operation} =
      Invocation.from_semantic(
        %{
          "kind" => "invoke",
          "invoke_id" => "worker",
          "type" => "jido",
          "capability" => "worker-capability",
          "input" => %{"job" => "one"},
          "owner_state_id" => "root",
          "autoforward" => false
        },
        session,
        registry,
        Limits.default(),
        DateTime.utc_now(),
        generation: 0,
        created_revision: 1
      )

    session = %{
      session
      | revision: 1,
        revision_fence: 1,
        operation_counter: 1,
        operation_high_water: %{operation.key => operation.generation},
        operations: %{operation.id => operation}
    }

    {session, registry, operation}
  end

  defp context(kind, session, operation, registry) do
    input = %Input{
      prepared: %{
        kind: kind,
        session: session,
        operation_id: operation.id,
        generation: operation.generation,
        registry: registry,
        retry_backoff_ms: 10,
        signal_id: "control-#{operation.id}"
      },
      runtime: %{authenticated_reserved: true}
    }

    %{agent_state: %{kept: true}, plugin_inputs: %{Plugin => input}}
  end

  defp child_context(session, operation, state, result) do
    input = %Input{
      prepared: %{
        kind: :child_result,
        session: session,
        operation_id: operation.id,
        generation: operation.generation,
        child_state: state,
        result: result,
        chart: ParentChart,
        limits: Limits.default(),
        signal_id: "child-#{state}-#{operation.id}"
      },
      runtime: %{authenticated_reserved: true}
    }

    %{agent_state: %{kept: true}, plugin_inputs: %{Plugin => input}}
  end
end
