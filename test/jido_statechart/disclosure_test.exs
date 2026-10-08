defmodule Jido.Statechart.DisclosureTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Jido.Statechart.Runtime.Server
  alias Jido.Statechart.Session.Operation

  alias Jido.Statechart.{
    ActionRunner,
    Diagnostic,
    Flow,
    Limits,
    Plugin,
    Registry,
    SCXML,
    SemanticFixture
  }

  @secret "JIDO_DISCLOSURE_MARKER_7bf8d5"
  @control "\e[31mCONTROL\e[0m"

  defmodule LeakingAction do
    use Jido.Action, name: "statechart_disclosure_action"

    @impl true
    def run(_params, context),
      do: {:error, {:private_action_failure, context, "JIDO_DISCLOSURE_MARKER_7bf8d5\e[31m"}}
  end

  defmodule LeakingTarget do
    def idempotency, do: :operation_id

    def deliver(_signal, _operation_id, _context),
      do: {:error, "JIDO_DISCLOSURE_MARKER_7bf8d5\e[31m"}
  end

  test "XML diagnostics redact unrecognized names, text, and terminal controls" do
    xml = """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
      <state id="safe"><#{@secret}>#{@secret}</#{@secret}></state>
    </scxml>
    """

    assert {:error, diagnostic} = SCXML.compile(xml)
    refute_disclosure(diagnostic)
    assert "$unrecognized" in diagnostic.path

    controlled =
      "<scxml xmlns=\"http://www.w3.org/2005/07/scxml\" version=\"1.0\">" <>
        @control <> "</scxml>"

    assert {:error, controlled_diagnostic} = SCXML.compile(controlled)
    refute_disclosure(controlled_diagnostic)
  end

  test "Signal data does not enter default trace or safe session inspection" do
    chart = SemanticFixture.chart(~s(<state id="root"/>))
    registry = SemanticFixture.registry()

    session =
      SemanticFixture.session(chart,
        registry: registry,
        status: :active,
        configuration: ["root"]
      )

    signal =
      Jido.Signal.new!("unhandled", %{"secret" => @secret, "control" => @control},
        id: "disclosure-signal",
        source: "/disclosure"
      )

    event = Plugin.event(signal, session)
    assert {:ok, result} = Flow.step(chart, session, event, registry)
    refute_disclosure(result.trace)
    refute_disclosure(Jido.Statechart.inspect_session(result.session))
  end

  test "Action errors and package context do not enter diagnostics or logs" do
    registry =
      Registry.new!(%{
        version: "disclosure-action-1",
        entries: [
          %{
            kind: :action,
            alias: "leak",
            permissions: ["execute"],
            handler: LeakingAction
          }
        ]
      })

    environment = %{
      session_id: @secret,
      event: %{"name" => "work", "data" => %{"secret" => @secret, "control" => @control}},
      configuration: ["ready"],
      turn_id: @control
    }

    log =
      capture_log(fn ->
        send(
          self(),
          {:action_result,
           ActionRunner.run("leak", %{}, environment,
             registry: registry,
             limits: Limits.default()
           )}
        )
      end)

    assert_receive {:action_result, {:error, diagnostic}}
    assert diagnostic.code == :action_failed
    refute_disclosure(diagnostic)
    refute_disclosure(log)
  end

  test "runtime adapter errors become bounded reason codes without payload disclosure" do
    registry =
      Registry.new!(%{
        version: "disclosure-runtime-1",
        entries: [
          %{
            kind: :target,
            alias: "sink",
            permissions: [
              "delivery:at_least_once",
              "idempotency:operation_id",
              "send:event"
            ],
            metadata: %{"allowed_signal_types" => ["notice"], "scope" => "local_agent"},
            handler: LeakingTarget
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
      "data" => %{"secret" => @secret, "control" => @control},
      "target" => "agent:sink"
    }

    operation =
      Operation.new!(%{
        session_incarnation: session.incarnation,
        kind: :send,
        target: "agent:sink",
        payload_digest: Diagnostic.digest(correlation),
        generation: 0,
        state: :result_unknown,
        attempt_count: 1,
        correlation: correlation
      })

    assert {:result_unknown, result} =
             Server.dispatch(operation, session, registry, %{}, retry_backoff_ms: 1)

    assert result["reason"] == "delivery_failed"
    refute_disclosure(result)
  end

  defp refute_disclosure(value) do
    rendered = inspect(value, limit: :infinity, printable_limit: :infinity)
    refute rendered =~ @secret
    refute rendered =~ "\e["
  end
end
