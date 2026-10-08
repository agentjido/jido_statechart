defmodule Jido.Statechart.Runtime.TimerTest do
  use ExUnit.Case, async: true

  alias Jido.Statechart.Runtime.Timer
  alias Jido.Statechart.{Diagnostic, Limits}

  @now ~U[2026-10-06 12:00:00Z]

  test "converts SCXML delay text to one absolute UTC due time" do
    limits = Limits.new!(%{timer_horizon_ms: 10_000})

    assert {:ok, nil} = Timer.due_at(nil, @now, limits)
    assert {:ok, "2026-10-06T12:00:00.250Z"} = Timer.due_at("250ms", @now, limits)
    assert {:ok, "2026-10-06T12:00:02.500Z"} = Timer.due_at("2.5s", @now, limits)

    assert {:error, %Diagnostic{code: :timer_horizon_exceeded}} =
             Timer.due_at("10001ms", @now, limits)

    for invalid <- ["", "-1ms", "1m", "tomorrow", 100] do
      assert {:error, %Diagnostic{code: :invalid_send_delay}} =
               Timer.due_at(invalid, @now, limits)
    end
  end

  test "uses generation tokens to reject replaced, canceled, and late timers" do
    timers = Timer.new()
    assert {:ok, timers, first} = Timer.replace(timers, "send:one", 1, 100)
    assert {:ok, timers, second} = Timer.replace(timers, "send:one", 2, 50)
    assert second != first
    assert :stale = Timer.fire(timers, "send:one", 1, first)
    assert {:ok, timers} = Timer.fire(timers, "send:one", 2, second)
    assert :missing = Timer.fire(timers, "send:one", 2, second)

    assert {:ok, timers, token} = Timer.replace(timers, "send:two", 3, 50)
    assert {:ok, timers} = Timer.cancel(timers, "send:two", 3)
    assert :missing = Timer.fire(timers, "send:two", 3, token)
  end

  test "invalid timer arithmetic returns an error" do
    assert {:error, %Diagnostic{code: :invalid_runtime_time}} =
             Timer.milliseconds_until("not-a-time", @now)

    assert {:error, %Diagnostic{code: :invalid_runtime_time}} =
             Timer.milliseconds_until("2026-10-06T12:00:01Z", "not-a-time")
  end
end
