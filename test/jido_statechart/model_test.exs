defmodule Jido.Statechart.ModelTest do
  use ExUnit.Case, async: true

  alias Jido.Statechart.{Diagnostic, Limits, Profile, Result, Session}
  alias Jido.Statechart.Model.{Chart, Event, Executable, Source, State, Transition}
  alias Jido.Statechart.Session.Operation

  test "builds an ordered normalized chart and round-trips it" do
    chart = chart_fixture()

    assert Enum.map(chart.states, & &1.id) == ["root", "regions", "left", "right"]
    assert Enum.map(chart.transitions, & &1.id) == ["t0"]
    assert chart.state_index["left"] == 2
    assert chart.transition_index["t0"] == 0
    assert {:ok, ^chart} = chart |> Chart.dump() |> Chart.load()
    assert :ok = Jido.PortableTerm.validate(Chart.dump(chart), :chart)
  end

  test "rejects malformed chart invariants with stable diagnostics" do
    chart = chart_fixture()

    assert {:error, %Diagnostic{code: :duplicate_id, path: [:states, 1, :id]}} =
             Chart.new(%{chart | states: [hd(chart.states), hd(chart.states)]})

    [root, regions, left, right] = chart.states

    assert {:error, %Diagnostic{code: :invalid_parent, path: [:states, 2, :parent]}} =
             Chart.new(%{chart | states: [root, regions, %{left | parent: "missing"}, right]})

    assert {:error, %Diagnostic{code: :invalid_ordinal, path: [:states, 1, :ordinal]}} =
             Chart.new(%{chart | states: [root, %{regions | ordinal: 3}, left, right]})

    assert {:error, %Diagnostic{code: :non_portable_value, path: [:metadata, "bad"]}} =
             Chart.new(%{chart | metadata: %{"bad" => self()}})
  end

  test "fingerprints equal normalized charts and changes semantic inputs" do
    chart = chart_fixture()
    same = chart_fixture()

    assert chart.fingerprint == same.fingerprint

    changed_profile = Chart.new!(%{chart | profile_version: "profile-2"})
    refute chart.fingerprint == changed_profile.fingerprint

    [transition] = chart.transitions
    changed_transition = %{transition | events: ["other.event"]}
    changed_chart = Chart.new!(%{chart | transitions: [changed_transition]})
    refute chart.fingerprint == changed_chart.fingerprint
  end

  test "generated identifiers are deterministic and contain no document atoms" do
    assert Chart.generated_id("state", [0, 2], 4) ==
             Chart.generated_id("state", [0, 2], 4)

    refute Chart.generated_id("state", [0, 2], 4) ==
             Chart.generated_id("transition", [0, 2], 4)

    unknown = "unknown-kind-#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    assert {:error, %Diagnostic{code: :invalid_state_kind}} =
             State.new(%{id: "s", ordinal: 0, kind: unknown})

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  test "events keep transport identity separate from SCXML send identity" do
    event =
      Event.new!(%{
        name: "job.done",
        class: :external,
        data: %{"result" => "ok"},
        message_id: "signal-1",
        send_id: "send-1",
        origin: "parent",
        origin_type: "jido",
        invoke_id: "worker-1",
        turn_id: "turn-1",
        session_id: "session-1"
      })

    assert event.message_id == "signal-1"
    assert event.send_id == "send-1"
    assert Event.dump(event)["class"] == "external"
    assert :ok = Jido.PortableTerm.validate(Event.dump(event), :event)
  end

  test "sessions and results round-trip without runtime handles" do
    operation =
      Operation.new!(%{
        session_incarnation: "incarnation-1",
        kind: :send,
        target: "parent",
        payload_digest: String.duplicate("c", 64),
        generation: 1,
        created_revision: 1
      })

    session =
      Session.new!(%{
        id: "session-1",
        incarnation: "incarnation-1",
        chart_fingerprint: String.duplicate("a", 64),
        registry_digest: String.duplicate("b", 64),
        limits_digest: Limits.digest(Limits.default()),
        registry_version: "registry-1",
        configuration: ["left"],
        operations: %{operation.id => operation},
        trace: [%{"event" => "job.start", "payload" => %{"secret" => true}}]
      })

    result =
      Result.new!(%{session: session, intents: [operation], operation_counts: %{"send" => 1}})

    assert {:ok, ^session} = session |> Session.dump() |> Session.load()
    assert {:ok, ^result} = result |> Result.dump() |> Result.new()
    assert :ok = Jido.PortableTerm.validate(Result.dump(result), :result)

    inspected = Jido.Statechart.inspect_session(session)
    assert inspected["pending_intent_ids"] == [operation.id]
    refute Map.has_key?(inspected, "trace")
    refute inspect(inspected) =~ "secret"
  end

  defp chart_fixture do
    source = Source.new!(%{uri: "memory://chart.scxml", path: ["scxml"], line: 1, column: 1})

    states = [
      State.new!(%{
        id: "root",
        ordinal: 0,
        kind: :compound,
        children: ["regions"],
        initial: ["regions"],
        source: source
      }),
      State.new!(%{
        id: "regions",
        ordinal: 1,
        kind: :parallel,
        parent: "root",
        children: ["left", "right"],
        source: source
      }),
      State.new!(%{
        id: "left",
        ordinal: 2,
        kind: :atomic,
        parent: "regions",
        transition_ids: ["t0"],
        source: source
      }),
      State.new!(%{id: "right", ordinal: 3, kind: :atomic, parent: "regions", source: source})
    ]

    executable = Executable.new!(%{kind: :log, ordinal: 0, data: %{"label" => "move"}})

    transitions = [
      Transition.new!(%{
        id: "t0",
        ordinal: 0,
        source_id: "left",
        target_ids: ["right"],
        events: ["advance"],
        executable: [executable],
        source: source
      })
    ]

    Chart.new!(%{
      id: "ordered-chart",
      name: "Ordered chart",
      profile_version: Profile.version(),
      datamodel: "jido",
      root_state_ids: ["root"],
      states: states,
      transitions: transitions,
      metadata: %{"owner" => "test"},
      source: source
    })
  end
end
