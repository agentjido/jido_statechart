defmodule Jido.Statechart.Runtime.InvocationTest do
  use ExUnit.Case, async: true

  alias Jido.Statechart.Runtime.{Child, Invocation, Reconciler}
  alias Jido.Statechart.{Diagnostic, Flow, Limits, Registry, SemanticFixture, Session}

  defmodule ChildChart do
    @chart Jido.Statechart.SemanticFixture.chart(~s(<state id="root"/>))
    @registry Jido.Statechart.SemanticFixture.registry()
    use Jido.Statechart.Chart, chart: @chart, registry: @registry
  end

  defmodule WorkerAgent do
    use Jido.Agent,
      name: "statechart_invocation_worker",
      extensions: [Jido.Statechart.Agent.Extension]

    agent do
      schema(Zoi.object(%{input: Zoi.map() |> Zoi.default(%{})}))
      plugin(Jido.Statechart.Plugin)
    end

    routes do
      route("finish", statechart: Jido.Statechart.Runtime.InvocationTest.ChildChart)
    end
  end

  @now ~U[2026-10-06 12:00:00Z]

  test "resolves a standard SCXML child through the typed Registry" do
    {session, registry, limits} = fixture("child-chart")

    assert {:ok, operation} =
             Invocation.from_semantic(
               %{
                 "kind" => "invoke",
                 "invoke_id" => "worker",
                 "type" => "scxml",
                 "capability" => "child-chart",
                 "input" => %{"input" => %{"job" => "one"}},
                 "owner_state_id" => "root",
                 "autoforward" => true
               },
               session,
               registry,
               limits,
               @now,
               generation: 3,
               created_revision: 1
             )

    assert operation.kind == :invoke
    assert operation.key == "invoke:worker"
    assert operation.target == Child.tag(session.incarnation, "worker", 3)
    assert operation.correlation["capability"] == "child-chart"
    assert operation.correlation["child_restart"] == "temporary"
    assert operation.correlation["depth"] == 1
    assert operation.correlation["remaining_descendants"] == limits.total_descendants - 1

    assert [{:invoke, ^operation}] =
             Reconciler.plan(put_operation(session, operation), @now, limits)
  end

  test "rejects arbitrary modules and recursive or exhausted invocation chains" do
    {session, _registry, limits} = fixture("child-chart")

    arbitrary =
      Registry.new!(%{
        version: "bad-registry",
        entries: [
          %{
            kind: :invocation,
            alias: "child-chart",
            permissions: ["invoke:scxml", "scope:local"],
            metadata: %{"type" => "scxml", "chart_fingerprint" => "child"},
            handler: String
          }
        ]
      })

    assert {:error, %Diagnostic{code: :invalid_invocation_handler}} =
             Invocation.from_semantic(start_value(), session, arbitrary, limits, @now)

    {_session, recursive, _limits} = fixture("recursive")

    assert {:error, %Diagnostic{code: :invocation_recursion}} =
             Invocation.from_semantic(
               Map.merge(start_value(), %{
                 "capability" => "recursive",
                 "ancestry" => [session.chart_fingerprint, ChildChart.chart().fingerprint]
               }),
               session,
               recursive,
               limits,
               @now
             )

    exhausted = Limits.new!(%{invocation_depth: 0, total_descendants: 0})

    assert {:error, %Diagnostic{code: :invocation_depth_exceeded}} =
             Invocation.from_semantic(
               start_value(),
               session,
               fixture_registry("child-chart"),
               exhausted,
               @now
             )

    used = %{session | invocation_descendants_used: limits.total_descendants}

    assert {:error, %Diagnostic{code: :invocation_descendant_limit_exceeded}} =
             Invocation.from_semantic(
               start_value(),
               used,
               fixture_registry("child-chart"),
               limits,
               @now
             )

    assert {:error, %Diagnostic{code: :invocation_descendant_limit_exceeded}} =
             Invocation.from_semantic(
               Map.put(start_value(), "reserved_descendants", limits.total_descendants + 1),
               session,
               fixture_registry("child-chart"),
               limits,
               @now
             )

    assert {:error, %Diagnostic{code: :invalid_invocation_ancestry}} =
             Invocation.from_semantic(
               Map.put(start_value(), "ancestry", [""]),
               session,
               fixture_registry("child-chart"),
               limits,
               @now
             )

    assert {:error, %Diagnostic{code: :invalid_invocation}} =
             Invocation.from_semantic(
               :invalid,
               session,
               fixture_registry("child-chart"),
               limits,
               @now
             )
  end

  test "invocation capabilities require an exact type, permission, and local scope" do
    base = %{
      kind: :invocation,
      alias: "child-chart",
      permissions: ["invoke:scxml", "scope:local"],
      metadata: %{
        "type" => "scxml",
        "scope" => "local",
        "chart_fingerprint" => ChildChart.chart().fingerprint
      },
      handler: WorkerAgent
    }

    registry = fn entry ->
      Registry.new!(%{version: Diagnostic.digest(entry), entries: [entry]})
    end

    assert {:error, %Diagnostic{code: :invocation_type_mismatch}} =
             Invocation.capability(
               registry.(put_in(base, [:metadata], Map.delete(base.metadata, "type"))),
               "child-chart",
               "scxml"
             )

    assert {:error, %Diagnostic{code: :invocation_permission_denied}} =
             Invocation.capability(
               registry.(%{base | permissions: ["scope:local"]}),
               "child-chart",
               "scxml"
             )

    assert {:error, %Diagnostic{code: :invocation_scope_not_allowed}} =
             Invocation.capability(
               registry.(put_in(base, [:metadata, "scope"], "remote")),
               "child-chart",
               "scxml"
             )

    assert {:error, %Diagnostic{code: :unsupported_invocation_type}} =
             Invocation.capability(registry.(base), "child-chart", "other")

    assert {:error, %Diagnostic{code: :unknown_invocation_capability}} =
             Invocation.capability(SemanticFixture.registry(), "child-chart", "scxml")
  end

  test "persisted parent context rejects a mutual A to B to A recursion" do
    {session, registry, limits} = fixture("child-chart")

    nested = %{
      session
      | invocation_ancestry: [ChildChart.chart().fingerprint, session.chart_fingerprint],
        invocation_depth: 1,
        invocation_remaining_descendants: limits.total_descendants - 1
    }

    assert {:error, %Diagnostic{code: :invocation_recursion}} =
             Invocation.from_semantic(start_value(), nested, registry, limits, @now)
  end

  test "child invocation context survives strict Session persistence" do
    {session, _registry, limits} = fixture("child-chart")

    child =
      Session.new!(%{
        session
        | invocation_ancestry: [session.chart_fingerprint],
          invocation_depth: 0,
          invocation_remaining_descendants: limits.total_descendants - 1
      })

    dump = Session.dump(child)
    assert {:ok, ^child} = Session.load(dump)

    assert {:error, %Diagnostic{code: :invalid_invocation_context}} =
             dump
             |> Map.put("invocation_depth", 2)
             |> Session.load()

    assert {:error, %Diagnostic{code: :missing_stored_field}} =
             dump
             |> Map.delete("invocation_ancestry")
             |> Session.load()

    assert {:error, %Diagnostic{code: :missing_stored_field}} =
             dump
             |> Map.delete("invocation_descendants_used")
             |> Session.load()

    assert {:error, %Diagnostic{code: :invalid_invocation_context}} =
             dump
             |> Map.put("invocation_remaining_descendants", -1)
             |> Session.load()

    assert {:error, %Diagnostic{code: :invalid_session}} = Session.load(:invalid)
  end

  test "a stop intent keeps the stable child identity while a spawn is pending" do
    {session, registry, limits} = fixture("child-chart")

    {:ok, start} =
      Invocation.from_semantic(start_value(), session, registry, limits, @now,
        generation: 0,
        created_revision: 1
      )

    assert {:ok, stop} =
             Invocation.from_semantic(
               %{
                 "kind" => "stop_invoke",
                 "invoke_id" => "worker",
                 "owner_state_id" => "root"
               },
               session,
               registry,
               limits,
               @now,
               generation: 1,
               created_revision: 1,
               prior_operations: [start]
             )

    assert stop.kind == :child_stop
    assert stop.target == start.target
    assert stop.correlation["invoke_operation_id"] == start.id

    pending = put_operation(%{session | operation_counter: 2}, start, stop)

    assert [{:invoke, ^start}, {:stop_invoke, ^stop}] =
             Reconciler.plan(pending, @now, limits)
  end

  test "autoforward is ordered before a same-turn state-exit stop" do
    chart =
      SemanticFixture.chart("""
      <state id="root">
        <invoke id="worker" type="scxml" src="child-chart" autoforward="true"/>
        <transition event="finish" target="done"/>
      </state>
      <final id="done"/>
      """)

    registry = fixture_registry("child-chart")
    session = SemanticFixture.session(chart, registry: registry)

    assert {:ok, initialized} = Flow.initialize(chart, session, registry)
    [invoke] = initialized.intents
    session = commit_intents(initialized.session, [invoke])

    assert {:ok, result} =
             Flow.step(
               chart,
               session,
               %{name: "finish", class: :external, message_id: "finish-1"},
               registry
             )

    assert [forward, stop] = result.intents
    assert forward.kind == :child_start
    assert forward.correlation["kind"] == "invoke_send"
    assert stop.kind == :child_stop
    assert stop.correlation["invoke_operation_id"] == invoke.id
  end

  test "sibling invokes reserve one durable descendant budget without duplication" do
    chart =
      SemanticFixture.chart("""
      <state id="root">
        <invoke id="first" type="scxml" src="child-chart"/>
        <invoke id="second" type="scxml" src="child-chart"/>
      </state>
      """)

    registry = fixture_registry("child-chart")
    allowed = Limits.new!(%{total_descendants: 2})
    session = SemanticFixture.session(chart, registry: registry, limits: allowed)

    assert {:ok, initialized} = Flow.initialize(chart, session, registry, limits: allowed)
    assert length(initialized.intents) == 2
    assert initialized.session.invocation_descendants_used == 2

    assert Enum.all?(initialized.intents, fn invoke ->
             invoke.correlation["reserved_descendants"] == 1 and
               invoke.correlation["remaining_descendants"] == 0
           end)

    exhausted = Limits.new!(%{total_descendants: 1})
    session = SemanticFixture.session(chart, registry: registry, limits: exhausted)

    assert {:error, error} = Flow.initialize(chart, session, registry, limits: exhausted)
    assert inspect(error) =~ "Invocation descendant budget was exhausted"
    assert session.invocation_descendants_used == 0
    assert session.operations == %{}
  end

  test "invocation input keeps namelist and parameter order" do
    chart =
      SemanticFixture.chart(
        """
        <state id="root">
          <invoke id="worker" type="scxml" src="child-chart" namelist="z a"/>
        </state>
        """,
        datamodel: "jido"
      )

    registry = fixture_registry("child-chart")
    session = SemanticFixture.session(chart, registry: registry, data: %{"z" => 9, "a" => 1})

    assert {:ok, initialized} = Flow.initialize(chart, session, registry)
    [invoke] = initialized.intents

    assert invoke.correlation["input"] == [
             %{"name" => "z", "value" => 9},
             %{"name" => "a", "value" => 1}
           ]
  end

  test "matching child finalize content runs before transition selection" do
    chart =
      SemanticFixture.chart("""
      <state id="root">
        <invoke id="worker" type="scxml" src="child-chart">
          <finalize><raise event="finalized"/></finalize>
        </invoke>
        <transition event="finalized" target="done"/>
      </state>
      <final id="done"/>
      """)

    registry = fixture_registry("child-chart")
    session = SemanticFixture.session(chart, registry: registry)

    assert {:ok, initialized} = Flow.initialize(chart, session, registry)
    [invoke] = initialized.intents
    session = commit_intents(initialized.session, [invoke])

    assert {:ok, result} =
             Flow.step(
               chart,
               session,
               %{
                 name: "child.reply",
                 class: :external,
                 message_id: "reply-1",
                 invoke_id: "worker"
               },
               registry
             )

    assert result.session.status == :completed
    assert [%{kind: :child_stop}] = result.intents
  end

  defp start_value do
    %{
      "kind" => "invoke",
      "invoke_id" => "worker",
      "type" => "scxml",
      "capability" => "child-chart",
      "input" => %{},
      "owner_state_id" => "root",
      "autoforward" => false
    }
  end

  defp fixture(alias_name) do
    chart = SemanticFixture.chart(~s(<state id="root"/>), id: "parent-chart")
    registry = fixture_registry(alias_name)
    limits = Limits.default()

    session =
      SemanticFixture.session(chart,
        registry: registry,
        limits: limits,
        status: :active,
        configuration: ["root"]
      )

    {session, registry, limits}
  end

  defp fixture_registry(alias_name) do
    Registry.new!(%{
      version: "invocation-registry-1",
      entries: [
        %{
          kind: :invocation,
          alias: alias_name,
          permissions: ["invoke:scxml", "scope:local"],
          metadata: %{
            "type" => "scxml",
            "chart_fingerprint" => ChildChart.chart().fingerprint,
            "input_mode" => "initial_state"
          },
          handler: WorkerAgent
        }
      ]
    })
  end

  defp put_operation(session, first, second \\ nil) do
    values = Enum.reject([first, second], &is_nil/1)

    %{
      session
      | operation_counter: max(session.operation_counter, length(values)),
        operations: Map.new(values, &{&1.id, &1})
    }
  end

  defp commit_intents(session, operations) do
    high_water =
      Map.new(operations, fn operation -> {operation.key, operation.generation} end)

    %{
      session
      | operations: Map.new(operations, &{&1.id, &1}),
        operation_high_water: high_water
    }
  end
end
