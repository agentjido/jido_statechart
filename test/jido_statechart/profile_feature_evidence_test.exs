defmodule Jido.Statechart.ProfileFeatureEvidenceTest do
  use ExUnit.Case, async: true

  alias Jido.Statechart.Runtime.Target
  alias Jido.Statechart.Model.Event
  alias Jido.Statechart.{DataModel, Diagnostic, Flow, SCXML, SemanticFixture}

  @uri "http://www.w3.org/2005/07/scxml"

  test "profile evidence: SCXML root default initial selects its first state" do
    chart =
      SCXML.compile!(
        ~s(<scxml xmlns="#{@uri}" version="1.0"><state id="first"/><state id="second"/></scxml>)
      )

    registry = SemanticFixture.registry()
    session = SemanticFixture.session(chart, registry: registry)

    assert {:ok, result} = Flow.initialize(chart, session, registry)
    assert result.session.configuration == ["first"]
  end

  test "profile evidence: script is rejected without source evaluation" do
    assert {:error, %Diagnostic{code: :unsupported_script}} =
             SCXML.compile(
               document(~s|<state id="s"><onentry><script>unsafe()</script></onentry></state>|)
             )
  end

  test "profile evidence: external data source is rejected" do
    assert {:error, %Diagnostic{code: :external_source_unsupported}} =
             SCXML.compile(
               document(
                 ~s(<state id="s"><datamodel><data id="x" src="https://example.invalid/data"/></datamodel></state>)
               )
             )
  end

  test "profile evidence: external invocation content source is rejected" do
    assert {:error, %Diagnostic{code: :external_source_unsupported}} =
             SCXML.compile(
               document(
                 ~s(<state id="s"><invoke type="scxml" src="https://example.invalid/child.scxml"/></state>)
               )
             )
  end

  test "profile evidence: ECMAScript data model is rejected" do
    assert {:error, %Diagnostic{code: :unsupported_datamodel}} =
             SCXML.compile(document(~s(<state id="s"/>), ~s( datamodel="ecmascript")))
  end

  test "profile evidence: XPath data model is rejected" do
    assert {:error, %Diagnostic{code: :unsupported_datamodel}} =
             SCXML.compile(document(~s(<state id="s"/>), ~s( datamodel="xpath")))
  end

  test "profile evidence: DOM binding is absent from the closed data model resolver" do
    assert {:ok, Jido.Statechart.DataModel.Null} = DataModel.resolve("null")
    assert {:ok, Jido.Statechart.DataModel.Jido} = DataModel.resolve("jido")
    assert {:error, %Diagnostic{code: :invalid_data_model}} = DataModel.resolve("dom")
  end

  test "profile evidence: SCXML Event I/O Processor session targets are rejected" do
    assert {:error, %Diagnostic{code: :invalid_runtime_target}} =
             Target.parse("#_scxml_session-1")

    assert {:error, %Diagnostic{code: :invalid_runtime_target}} =
             Target.parse("#_invokeid")
  end

  test "profile evidence: Basic HTTP Event I/O targets are rejected" do
    assert {:error, %Diagnostic{code: :invalid_runtime_target}} =
             Target.parse("https://example.invalid/events")
  end

  test "profile evidence: event system fields use normalized Jido names and values" do
    external =
      Event.new!(%{
        name: "work.received",
        class: :external,
        data: %{"job" => "one"},
        message_id: "message-1",
        send_id: "send-1",
        origin: "/agents/sender",
        origin_type: "jido.signal",
        invoke_id: "child-1",
        turn_id: "turn-1",
        session_id: "session-1"
      })
      |> Event.dump()

    assert external == %{
             "name" => "work.received",
             "class" => "external",
             "data" => %{"job" => "one"},
             "message_id" => "message-1",
             "send_id" => "send-1",
             "origin" => "/agents/sender",
             "origin_type" => "jido.signal",
             "invoke_id" => "child-1",
             "turn_id" => "turn-1",
             "session_id" => "session-1"
           }

    refute Map.has_key?(external, "type")
    refute Map.has_key?(external, "sendid")
    refute Map.has_key?(external, "origintype")
    refute Map.has_key?(external, "invokeid")

    for class <- [:internal, :platform] do
      event = Event.new!(%{name: "error.execution", class: class}) |> Event.dump()
      assert event["class"] == Atom.to_string(class)
      assert event["send_id"] == nil
      assert event["origin"] == nil
      assert event["origin_type"] == nil
      assert event["invoke_id"] == nil
    end
  end

  defp document(body, attributes \\ "") do
    ~s(<scxml xmlns="#{@uri}" version="1.0"#{attributes}>#{body}</scxml>)
  end
end
