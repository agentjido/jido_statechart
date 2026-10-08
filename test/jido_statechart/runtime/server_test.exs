defmodule Jido.Statechart.Runtime.ServerTest do
  use ExUnit.Case, async: true

  alias Jido.Statechart.Runtime.Server
  alias Jido.Statechart.Session.Operation
  alias Jido.Statechart.{Diagnostic, Registry, SemanticFixture}

  defmodule UncertainAdapter do
    def idempotency, do: :operation_id
    def deliver(_signal, _operation_id, _context), do: {:error, :timeout}
  end

  defmodule RetryableAdapter do
    def idempotency, do: :operation_id
    def deliver(_signal, _operation_id, _context), do: {:error, {:retryable, :unavailable}}
  end

  defmodule ExplicitUncertainAdapter do
    def idempotency, do: :operation_id
    def deliver(_signal, _operation_id, _context), do: {:error, {:uncertain, :transport}}
  end

  defmodule ThrowingAdapter do
    def idempotency, do: :operation_id
    def deliver(_signal, _operation_id, _context), do: throw(:transport)
  end

  defmodule TupleErrorAdapter do
    def idempotency, do: :operation_id
    def deliver(_signal, _operation_id, _context), do: {:error, {:network, :down}}
  end

  test "uncertain outcomes stay unknown and only confirmed no-effect outcomes retry" do
    {unknown, unknown_session, unknown_registry} = fixture(UncertainAdapter, "unknown")

    assert {:result_unknown, unknown_result} =
             Server.dispatch(unknown, unknown_session, unknown_registry, %{},
               retry_limit: 2,
               retry_backoff_ms: 10
             )

    assert unknown_result["operation_id"] == unknown.id
    assert unknown_result["outcome"] == "result_unknown"
    assert {:ok, _datetime, 0} = DateTime.from_iso8601(unknown_result["next_attempt_at"])

    {retryable, retryable_session, retryable_registry} = fixture(RetryableAdapter, "retryable")

    assert {:retryable_failure, retry_result} =
             Server.dispatch(retryable, retryable_session, retryable_registry, %{},
               retry_limit: 2,
               retry_backoff_ms: 10
             )

    assert retry_result["operation_id"] == retryable.id
    assert retry_result["outcome"] == "retryable_failure"
  end

  test "explicit uncertainty and adapter throws cannot become retryable failures" do
    {explicit, explicit_session, explicit_registry} =
      fixture(ExplicitUncertainAdapter, "explicit")

    assert {:result_unknown, %{"reason" => "transport"}} =
             Server.dispatch(explicit, explicit_session, explicit_registry, %{},
               retry_backoff_ms: 10
             )

    {throwing, throwing_session, throwing_registry} = fixture(ThrowingAdapter, "throwing")

    assert {:result_unknown, %{"reason" => "throw"}} =
             Server.dispatch(throwing, throwing_session, throwing_registry, %{},
               retry_backoff_ms: 10
             )

    {tuple, tuple_session, tuple_registry} = fixture(TupleErrorAdapter, "tuple")

    assert {:result_unknown, %{"reason" => "network:down"}} =
             Server.dispatch(tuple, tuple_session, tuple_registry, %{}, retry_backoff_ms: 10)

    empty_registry = Registry.new!(%{version: "empty-targets", entries: []})
    chart = SemanticFixture.chart(~s(<state id="root"/>))

    empty_session =
      SemanticFixture.session(chart,
        registry: empty_registry,
        status: :active,
        configuration: ["root"]
      )

    correlation = %{"kind" => "send", "event" => "notice", "target" => "agent:missing"}

    missing =
      Operation.new!(%{
        session_incarnation: empty_session.incarnation,
        kind: :send,
        target: "agent:missing",
        payload_digest: Diagnostic.digest(correlation),
        generation: 0,
        state: :result_unknown,
        attempt_count: 1,
        correlation: correlation
      })

    assert {:permanent_failure, %{"reason" => "unknown_runtime_target"}} =
             Server.dispatch(missing, empty_session, empty_registry, %{}, [])
  end

  defp fixture(handler, alias_name) do
    registry =
      Registry.new!(%{
        version: "server-targets-#{alias_name}",
        entries: [
          %{
            kind: :target,
            alias: alias_name,
            permissions: ["delivery:at_least_once", "idempotency:operation_id", "send:event"],
            metadata: %{"allowed_signal_types" => ["notice"], "scope" => "local_agent"},
            handler: handler
          }
        ]
      })

    chart = SemanticFixture.chart(~s(<state id="root"/>))

    session =
      SemanticFixture.session(chart,
        registry: registry,
        status: :active,
        configuration: ["root"]
      )

    correlation = %{
      "kind" => "send",
      "event" => "notice",
      "data" => %{"value" => 1},
      "target" => "agent:#{alias_name}"
    }

    operation =
      Operation.new!(%{
        session_incarnation: session.incarnation,
        kind: :send,
        target: "agent:#{alias_name}",
        payload_digest: Diagnostic.digest(correlation),
        generation: 0,
        state: :result_unknown,
        attempt_count: 1,
        correlation: correlation
      })

    {operation, session, registry}
  end
end
