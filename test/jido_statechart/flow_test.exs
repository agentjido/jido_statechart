defmodule Jido.Statechart.FlowTest do
  use ExUnit.Case, async: true

  alias Jido.Exec
  alias Jido.Flow.{Iterate, Step}
  alias Jido.Statechart.Actions.{Finish, Prepare}
  alias Jido.Statechart.Model.Event
  alias Jido.Statechart.Semantics.Macrostep
  alias Jido.Statechart.{Diagnostic, Flow, Limits, Registry, Result, SemanticFixture, Session}

  defmodule ParentAdapter do
    def idempotency, do: :operation_id
    def deliver(_signal, _operation_id, _context), do: :ok
  end

  test "the canonical graph is static, acyclic, and ordered" do
    assert [
             %Step{name: "prepare"},
             %Iterate{name: "microstep", max_iterations: 10_000},
             %Step{name: "finish"}
           ] = Flow.flow().components

    assert {:ok, dependencies} = Jido.Flow.dependencies(Flow.flow())
    assert dependencies["prepare"].effective == []
    assert dependencies["microstep"].effective == ["prepare"]
    assert dependencies["finish"].effective == ["microstep"]
    assert {:ok, _compiled} = Jido.Flow.compile(Flow.flow())
  end

  test "zero iterations return a stable no-op Result" do
    chart = SemanticFixture.chart(~s(<state id="root"/>))
    session = SemanticFixture.session(chart, status: :active, configuration: ["root"])
    input = Flow.input(chart, session, %{name: "unknown"}, SemanticFixture.registry())

    assert {:ok, %Result{} = result} = Exec.run(Flow, input)
    assert result.session.configuration == ["root"]
    assert result.operation_counts["microsteps"] == 0
    assert Enum.map(result.trace, & &1["kind"]) == ["event_discarded"]
  end

  test "the lower macrostep limit succeeds exactly and fails one past it" do
    exact_chart =
      SemanticFixture.chart("""
      <state id="root" initial="a">
        <state id="a"><transition event="go" target="b"/></state>
        <state id="b"><transition target="done"/></state>
        <final id="done"/>
      </state>
      """)

    exact_limits = Limits.new!(%{microsteps_per_macrostep: 2})

    exact_session =
      SemanticFixture.session(exact_chart,
        status: :active,
        configuration: ["a"],
        limits: exact_limits
      )

    exact_input =
      Flow.input(
        exact_chart,
        exact_session,
        %{name: "go"},
        SemanticFixture.registry(),
        limits: exact_limits
      )

    assert {:ok, %Result{} = exact} = Exec.run(Flow, exact_input)
    assert exact.operation_counts["microsteps"] == 2

    one_limit = Limits.new!(%{microsteps_per_macrostep: 1})

    one_session =
      SemanticFixture.session(exact_chart,
        status: :active,
        configuration: ["a"],
        limits: one_limit
      )

    one_input =
      Flow.input(
        exact_chart,
        one_session,
        %{name: "go"},
        SemanticFixture.registry(),
        limits: one_limit
      )

    assert {:error, _error} = Exec.run(Flow, one_input)
    assert Limits.bounds().microsteps_per_macrostep.max == 10_000
  end

  test "run, step, wave, and continue return the same Result" do
    {input, expected} = fixture_input()

    assert {:ok, ^expected} = run_by_steps(input)
    assert {:ok, ^expected} = run_by_waves(input)

    assert {:ok, execution} = Exec.start(Flow, input)
    assert {:ok, execution} = Exec.continue(execution)
    assert {:ok, ^expected} = Exec.result(execution)
  end

  test "step inspection sees Iterate as one compound unit and trace sees each microstep" do
    {input, _expected} = fixture_input()
    assert {:ok, execution} = Exec.start(Flow, input)
    {works, execution} = collect_steps(execution, [])

    assert Enum.count(works, &(&1.kind == :iterate and &1.role == :execute)) == 1
    assert {:ok, %Result{} = result} = Exec.result(execution)
    assert Enum.count(result.trace, &(&1["kind"] == "microstep")) == 2
  end

  test "a late failure returns no earlier statechart intent output" do
    chart =
      SemanticFixture.chart("""
      <state id="root" initial="a">
        <state id="a">
          <transition event="go" target="b"><send event="outside" target="parent"/></transition>
        </state>
        <state id="b"><transition target="done"/></state>
        <final id="done"/>
      </state>
      """)

    limits = Limits.new!(%{trace_entries: 1, microsteps_per_macrostep: 10})

    session =
      SemanticFixture.session(chart,
        status: :active,
        configuration: ["a"],
        limits: limits
      )

    input =
      Flow.input(chart, session, %{name: "go"}, SemanticFixture.registry(), limits: limits)

    assert {:error, _error} = Exec.run(Flow, input)
    assert session.configuration == ["a"]
    assert session.operations == %{}
  end

  test "successful semantic intent becomes a valid ordered Result operation" do
    chart =
      SemanticFixture.chart("""
      <state id="root" initial="a">
        <state id="a">
          <transition event="go" target="b"><send event="outside" target="parent"/></transition>
        </state>
        <state id="b"/>
      </state>
      """)

    registry = parent_registry()

    session =
      SemanticFixture.session(chart, status: :active, configuration: ["a"], registry: registry)

    input = Flow.input(chart, session, %{name: "go"}, registry)

    assert {:ok, %Result{} = result} = Exec.run(Flow, input)
    assert [%Jido.Statechart.Session.Operation{kind: :send, target: "parent"}] = result.intents
    assert result.operation_counts == %{"microsteps" => 1, "send" => 1}
    assert {:ok, ^result} = result |> Result.dump() |> Result.new()
  end

  test "an invalid static send target raises error.execution inside the macrostep" do
    chart =
      SemanticFixture.chart("""
      <state id="root" initial="sending">
        <state id="sending">
          <transition event="go" target="waiting">
            <send event="outside" target="https://example.invalid/events"/>
          </transition>
        </state>
        <state id="waiting">
          <transition event="error.execution" target="recovered"/>
        </state>
        <final id="recovered"/>
      </state>
      """)

    registry = SemanticFixture.registry()

    session =
      SemanticFixture.session(chart,
        status: :active,
        configuration: ["sending"],
        registry: registry
      )

    assert {:ok, %Result{} = result} =
             Flow.step(chart, session, %{name: "go"}, registry)

    assert result.session.configuration == ["recovered"]
    assert result.intents == []
    assert Enum.any?(result.trace, &(&1["event"] == "error.execution"))
  end

  test "operation occurrences are unique, durable, and deterministic" do
    chart =
      SemanticFixture.chart("""
      <state id="root" initial="a">
        <state id="a">
          <transition event="go">
            <send id="same" event="outside" target="parent"/>
          </transition>
        </state>
      </state>
      """)

    registry = parent_registry()

    initial =
      SemanticFixture.session(chart, status: :active, configuration: ["a"], registry: registry)

    assert {:ok, %Result{} = first} = Flow.step(chart, initial, %{name: "go"}, registry)
    assert Enum.map(first.intents, & &1.generation) == [0]
    assert first.session.operation_counter == 1
    assert first.session.generated_id_counter == initial.generated_id_counter
    assert [first_id] = Enum.map(first.intents, & &1.id)

    assert {:ok, replay} = Flow.step(chart, initial, %{name: "go"}, registry)
    assert Enum.map(replay.intents, & &1.id) == [first_id]
    assert replay.session.operation_counter == 1

    assert {:ok, restored} = first.session |> Session.dump() |> Session.load()
    assert {:ok, next} = Flow.step(chart, restored, %{name: "go"}, registry)
    assert Enum.map(next.intents, & &1.generation) == [1]
    assert next.session.operation_counter == 2
    assert [next_id] = Enum.map(next.intents, & &1.id)
    refute first_id == next_id

    assert {:ok, restored_replay} = Flow.step(chart, restored, %{name: "go"}, registry)
    assert Enum.map(restored_replay.intents, & &1.id) == Enum.map(next.intents, & &1.id)

    assert {:ok, prepared} =
             Macrostep.prepare_run(chart, initial, %{name: "unknown"},
               registry: registry,
               limits: Limits.default()
             )

    duplicate_intent = %{"kind" => "send", "event" => "outside", "target" => "parent"}

    duplicate_state =
      put_in(prepared, [:workspace, :intents], [duplicate_intent, duplicate_intent])

    assert {:ok, same_macrostep} = Finish.run(%{state: duplicate_state}, %{})
    assert Enum.map(same_macrostep.intents, & &1.generation) == [0, 1]
    assert same_macrostep.session.operation_counter == 2
    assert 2 == same_macrostep.intents |> Enum.map(& &1.id) |> Enum.uniq() |> length()
  end

  defp parent_registry do
    Registry.new!(%{
      version: "flow-parent-1",
      entries: [
        %{
          kind: :target,
          alias: "parent",
          permissions: ["delivery:at_least_once", "idempotency:operation_id", "send:event"],
          metadata: %{"allowed_signal_types" => ["outside"], "scope" => "local_agent"},
          handler: ParentAdapter
        }
      ]
    })
  end

  test "Flow Action boundaries reject malformed and protected input" do
    chart = SemanticFixture.chart(~s(<state id="root"/>))
    registry = SemanticFixture.registry()
    active = SemanticFixture.session(chart, status: :active, configuration: ["root"])
    input = Flow.input(chart, active, %{name: "go"}, registry)

    assert {:error, %{code: :invalid_flow_context}} = Prepare.run(input, :invalid)
    assert {:error, %{code: :protected_context_override}} = Prepare.run(input, %{chart: chart})

    assert {:error, %{code: :invalid_flow_operation}} =
             Prepare.run(%{input | operation: :bad}, %{})

    for operation <- [:initialize, "initialize"] do
      assert {:error, %{code: :invalid_flow_input}} =
               Prepare.run(%{input | operation: operation, event: nil}, %{})

      fresh = SemanticFixture.session(chart)

      assert {:error, %{code: :invalid_flow_input}} =
               Prepare.run(%{input | operation: operation, session: fresh}, %{})
    end

    for operation <- [:run, "run"] do
      assert {:error, %{code: :invalid_flow_input}} =
               Prepare.run(%{input | operation: operation, event: nil}, %{})

      fresh = SemanticFixture.session(chart)

      assert {:error, %{code: :invalid_flow_input}} =
               Prepare.run(%{input | operation: operation, session: fresh}, %{})
    end

    for event <- [
          %{},
          %{name: ""},
          %Event{name: nil, class: :external},
          %{name: "go", class: :internal},
          %{name: "go", class: :platform},
          Event.new!(%{name: "go", class: :internal}),
          Event.new!(%{name: "go", class: :platform})
        ] do
      assert {:error, _diagnostic} = Prepare.run(%{input | event: event}, %{})
    end

    fresh = SemanticFixture.session(chart)
    fresh_input = Flow.input(chart, fresh, %{name: "go"}, registry)

    assert {:error, %{code: :invalid_flow_input}} =
             Prepare.run(%{fresh_input | operation: nil}, %{})

    deadline_context = %{
      __jido_exec__: %{deadline: System.monotonic_time(:millisecond) + 5_000}
    }

    assert {:ok, state} = Prepare.run(input, deadline_context)
    assert is_map(state) and not is_struct(state)
    assert {:error, %{code: :macrostep_not_stable}} = Macrostep.finish(%{})
    assert {:error, %{code: :macrostep_already_stable}} = Macrostep.advance(%{complete: true})
    assert {:error, %{code: :invalid_semantic_input}} = Macrostep.advance(%{})
    refute Macrostep.complete?(%{})
  end

  test "Finish validates each semantic intent before it exposes a Result" do
    chart =
      SemanticFixture.chart("""
      <state id="root" initial="a">
        <state id="a"><transition event="go" target="b"/></state>
        <state id="b"/>
      </state>
      """)

    session = SemanticFixture.session(chart, status: :active, configuration: ["a"])

    assert {:ok, state} =
             Macrostep.prepare_run(chart, session, %{name: "go"}, SemanticFixture.options())

    assert {:ok, state} = Macrostep.advance(state)
    assert Macrostep.complete?(state)

    for intent <- [
          %{"kind" => "send", "event" => "work", "target" => nil},
          %{"kind" => "cancel", "send_id" => "send-1"}
        ] do
      candidate = put_in(state, [:workspace, :intents], [intent])
      assert {:ok, %Result{intents: [_operation]}} = Finish.run(%{state: candidate}, %{})
    end

    for intent <- [
          :invalid,
          %{"kind" => "unknown"},
          %{"kind" => "send", "target" => 7},
          %{"kind" => "cancel"},
          %{"kind" => "send", "target" => "parent", "unsafe" => self()}
        ] do
      candidate = put_in(state, [:workspace, :intents], [intent])
      assert {:error, _diagnostic} = Finish.run(%{state: candidate}, %{})
    end

    assert {:error, %{code: :invalid_flow_state}} = Finish.run(%{}, %{})
  end

  test "the executable module exposes normal validation and convenience functions" do
    assert %Jido.Flow.Compiled{} = Flow.compiled()
    assert {:error, _error} = Flow.validate_params(:invalid)
    assert {:error, _error} = Flow.validate_output(%{})

    {input, expected} = fixture_input()
    assert {:ok, ^expected} = Flow.run(input, %{})
  end

  test "Flow helpers validate and forward their public options" do
    chart = SemanticFixture.chart(~s(<state id="root"/>))
    registry = SemanticFixture.registry()
    session = SemanticFixture.session(chart)

    for options <- [
          %{},
          [:timeout],
          [unknown: true],
          [exec_options: [timeout: 0]],
          [timeout: 1, timeout: 2]
        ] do
      assert {:error, %Diagnostic{code: :invalid_flow_options}} =
               Flow.initialize(chart, session, registry, options)
    end

    assert {:error, %Jido.Exec.Error.TimeoutError{timeout: 0}} =
             Flow.initialize(chart, session, registry, timeout: 0)

    assert {:error, _error} =
             Flow.initialize(chart, session, registry, max_concurrency: 0)

    assert {:error, _error} =
             Flow.initialize(chart, session, registry, max_continuations: -1)

    assert {:error, _error} =
             Flow.initialize(chart, session, registry,
               task_supervisor: :missing_statechart_test_supervisor
             )

    assert {:ok, %Result{}} =
             Flow.initialize(chart, session, registry, context: %{"tenant" => "one"})

    assert_raise ArgumentError, ~r/options must be a keyword list/, fn ->
      apply(Flow, :input, [chart, session, nil, registry, %{}])
    end

    assert_raise ArgumentError, ~r/unknown option/, fn ->
      Flow.input(chart, session, nil, registry, unknown: true)
    end
  end

  defp fixture_input do
    chart =
      SemanticFixture.chart("""
      <state id="root" initial="a">
        <state id="a"><transition event="go" target="b"/></state>
        <state id="b"><transition target="done"/></state>
        <final id="done"/>
      </state>
      """)

    session = SemanticFixture.session(chart, status: :active, configuration: ["a"])
    input = Flow.input(chart, session, %{name: "go"}, SemanticFixture.registry())
    assert {:ok, expected} = Exec.run(Flow, input)
    {input, expected}
  end

  defp run_by_steps(input) do
    with {:ok, execution} <- Exec.start(Flow, input) do
      {_works, execution} = collect_steps(execution, [])
      Exec.result(execution)
    end
  end

  defp collect_steps(execution, works) do
    if Exec.status(execution) == :running do
      {:ok, work, execution} = Exec.step(execution)
      collect_steps(execution, [work | works])
    else
      {Enum.reverse(works), execution}
    end
  end

  defp run_by_waves(input) do
    with {:ok, execution} <- Exec.start(Flow, input) do
      execution = collect_waves(execution)
      Exec.result(execution)
    end
  end

  defp collect_waves(execution) do
    if Exec.status(execution) == :running do
      {:ok, _works, execution} = Exec.wave(execution)
      collect_waves(execution)
    else
      execution
    end
  end
end
