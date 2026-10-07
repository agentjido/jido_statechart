defmodule Jido.Statechart.Runtime.TargetTest do
  use ExUnit.Case, async: true

  alias Jido.Statechart.Runtime.Target
  alias Jido.Statechart.{Diagnostic, Registry, SemanticFixture, Session}

  defmodule IdempotentAdapter do
    def idempotency, do: :operation_id
    def deliver(_signal, _operation_id, _context), do: :ok
  end

  defmodule UnsafeAdapter do
    def deliver(_signal, _operation_id, _context), do: :ok
  end

  defmodule RaisingAdapter do
    def idempotency, do: raise("bad adapter")
    def deliver(_signal, _operation_id, _context), do: :ok
  end

  test "accepts only the profile target grammar" do
    for {text, kind, value} <- [
          {"#_self", :self, nil},
          {"self", :self, nil},
          {"#_parent", :parent, nil},
          {"parent", :parent, nil},
          {"#_invoke.child-1", :invoke, "child-1"},
          {"invoke:child-1", :invoke, "child-1"},
          {"agent:billing", :agent, "billing"}
        ] do
      assert {:ok, %Target{kind: ^kind, value: ^value}} = Target.parse(text)
    end

    for invalid <- [
          self(),
          :billing,
          "billing",
          "agent:",
          "invoke:",
          "#_invoke.",
          "pid:<0.1.0>",
          "Elixir.SomeAgent"
        ] do
      assert {:error, %Diagnostic{code: :invalid_runtime_target}} = Target.parse(invalid)
    end
  end

  test "requires an allowlisted event and an operation-id idempotency contract" do
    safe = target_registry(IdempotentAdapter, ["notice"])
    unsafe = target_registry(UnsafeAdapter, ["notice"])

    assert {:ok, %Target{kind: :agent, value: "billing"}} =
             Target.resolve("agent:billing", "notice", safe)

    assert {:error, %Diagnostic{code: :target_signal_type_not_allowed}} =
             Target.resolve("agent:billing", "secret", safe)

    assert {:error, %Diagnostic{code: :target_not_idempotent}} =
             Target.resolve("agent:billing", "notice", unsafe)

    assert {:error, %Diagnostic{code: :unknown_runtime_target}} =
             Target.resolve("agent:missing", "notice", safe)
  end

  test "parent requires an explicit idempotent capability and invoke waits for U8" do
    empty = Registry.new!(%{version: "targets-empty", entries: []})
    parent = target_registry(IdempotentAdapter, ["notice"], %{}, "parent")

    assert {:error, %Diagnostic{code: :unknown_runtime_target}} =
             Target.resolve("#_parent", "notice", empty)

    assert {:ok, %Target{kind: :parent, entry: %Registry.Entry{name: "parent"}}} =
             Target.resolve("#_parent", "notice", parent)

    assert {:error, %Diagnostic{code: :invoke_target_unsupported}} =
             Target.resolve("#_invoke.child", "notice", parent)
  end

  test "rejects stale and cross-Agent capability use" do
    stale = target_registry(IdempotentAdapter, ["notice"], %{"active" => false})

    assert {:error, %Diagnostic{code: :stale_runtime_target}} =
             Target.resolve("agent:billing", "notice", stale)

    owned =
      target_registry(IdempotentAdapter, ["notice"], %{"owner_agent_id" => "agent-one"})

    assert {:ok, target} = Target.resolve("agent:billing", "notice", owned)
    signal = Jido.Signal.new!("notice", %{}, source: "/test")

    assert {:error, {:permanent, :cross_agent_capability}} =
             Target.dispatch(target, signal, "operation-one", %{agent_id: "agent-two"})

    assert :ok =
             Target.dispatch(target, signal, "operation-one", %{agent_id: "agent-one"})
  end

  test "rejects missing permissions, remote scope, and malformed adapters" do
    denied = capability_registry(IdempotentAdapter, [], %{})

    no_idempotency =
      capability_registry(IdempotentAdapter, ["send:event", "delivery:at_least_once"], %{})

    remote =
      capability_registry(
        IdempotentAdapter,
        ["send:event", "delivery:at_least_once", "idempotency:operation_id"],
        %{"scope" => "remote"}
      )

    tuple_handler =
      capability_registry(
        {:adapter, :tuple},
        ["send:event", "delivery:at_least_once", "idempotency:operation_id"],
        %{}
      )

    raising =
      capability_registry(
        RaisingAdapter,
        ["send:event", "delivery:at_least_once", "idempotency:operation_id"],
        %{}
      )

    assert {:error, %Diagnostic{code: :target_permission_denied}} =
             Target.resolve("agent:billing", "notice", denied)

    assert {:error, %Diagnostic{code: :target_not_idempotent}} =
             Target.resolve("agent:billing", "notice", no_idempotency)

    assert {:error, %Diagnostic{code: :target_scope_not_allowed}} =
             Target.resolve("agent:billing", "notice", remote)

    assert {:error, %Diagnostic{code: :target_not_idempotent}} =
             Target.resolve("agent:billing", "notice", tuple_handler)

    assert {:error, %Diagnostic{code: :target_not_idempotent}} =
             Target.resolve("agent:billing", "notice", raising)

    assert {:error, %Diagnostic{code: :invalid_runtime_signal}} =
             Target.resolve("agent:billing", <<255>>, denied)

    signal = Jido.Signal.new!("notice", %{}, source: "/test")

    assert {:error, {:permanent, :self_delivery_not_authenticated}} =
             Target.dispatch(%Target{kind: :self}, signal, "operation", %{})
  end

  test "builds a stable Signal with separate operation and SCXML send identities" do
    chart = SemanticFixture.chart(~s(<state id="root"/>))
    session = SemanticFixture.session(chart, status: :active, configuration: ["root"])

    correlation = %{
      "kind" => "send",
      "event" => "notice",
      "data" => %{"value" => 1},
      "send_id" => "authored-send",
      "target" => "#_self"
    }

    operation =
      Session.Operation.new!(%{
        session_incarnation: session.incarnation,
        kind: :send,
        target: "#_self",
        payload_digest: Diagnostic.digest(correlation),
        generation: 7,
        key: "send:authored-send",
        correlation: correlation
      })

    assert {:ok, first} = Target.signal(operation, session)
    assert {:ok, second} = Target.signal(operation, session)
    assert first.id == operation.id
    assert second.id == first.id
    assert first.type == "notice"
    assert first.data == %{"value" => 1}
    assert Jido.Signal.get_context(first, "jidoscopid") == operation.id
    assert Jido.Signal.get_context(first, "jidoscsendid") == "authored-send"
    assert Jido.Signal.get_context(first, "jidoscgen") == 7
    assert Jido.Signal.get_context(first, "jidosceventclass") == "external"
    assert Jido.Signal.get_context(first, "jidoscsessionid") == session.id
    assert Jido.Signal.get_context(first, "jidoscturnid") == nil
    assert Jido.Signal.get_context(first, "jidoscsessionrev") == 0

    correlated = Map.put(correlation, "turn_id", "source-turn-42")

    correlated_operation =
      Session.Operation.new!(%{
        operation
        | id: nil,
          payload_digest: Diagnostic.digest(correlated),
          correlation: correlated
      })

    assert {:ok, correlated_signal} = Target.signal(correlated_operation, session)
    assert Jido.Signal.get_context(correlated_signal, "jidoscturnid") == "source-turn-42"
  end

  defp target_registry(handler, types, metadata \\ %{}, alias_name \\ "billing") do
    Registry.new!(%{
      version: "targets-1",
      entries: [
        %{
          kind: :target,
          alias: alias_name,
          permissions: [
            "delivery:at_least_once",
            "idempotency:operation_id",
            "send:event"
          ],
          metadata:
            Map.merge(
              %{
                "scope" => "local_agent",
                "allowed_signal_types" => types
              },
              metadata
            ),
          handler: handler
        }
      ]
    })
  end

  defp capability_registry(handler, permissions, metadata) do
    Registry.new!(%{
      version: "target-capability",
      entries: [
        %{
          kind: :target,
          alias: "billing",
          permissions: permissions,
          metadata: Map.put_new(metadata, "scope", "local_agent"),
          handler: handler
        }
      ]
    })
  end
end
