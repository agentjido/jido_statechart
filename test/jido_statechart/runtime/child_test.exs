defmodule Jido.Statechart.Runtime.ChildTest do
  use ExUnit.Case, async: true

  alias Jido.Statechart.Runtime.Child

  test "the child tag binds incarnation, invoke id, and generation" do
    first = Child.tag("incarnation-1", "worker", 7)

    assert first == Child.tag("incarnation-1", "worker", 7)
    assert first != Child.tag("incarnation-2", "worker", 7)
    assert first != Child.tag("incarnation-1", "other", 7)
    assert first != Child.tag("incarnation-1", "worker", 8)
    assert String.starts_with?(first, "jido-sc-")
  end

  test "matching ownership requires the stable tag and immutable operation metadata" do
    tag = Child.tag("incarnation-1", "worker", 2)

    operation = %{
      id: "operation-1",
      session_incarnation: "incarnation-1",
      generation: 2,
      target: tag,
      correlation: %{"invoke_id" => "worker"}
    }

    child = %{
      tag: tag,
      id: "parent/#{tag}",
      meta: %{
        "jido_statechart_operation_id" => "operation-1",
        "jido_statechart_generation" => 2,
        "jido_statechart_invoke_id" => "worker",
        "jido_statechart_session_incarnation" => "incarnation-1"
      }
    }

    assert Child.owned?(child, operation)
    refute Child.owned?(put_in(child, [:meta, "jido_statechart_generation"], 1), operation)
    refute Child.owned?(put_in(child, [:meta, "jido_statechart_invoke_id"], "stale"), operation)

    refute Child.owned?(
             put_in(child, [:meta, "jido_statechart_session_incarnation"], "stale"),
             operation
           )
  end
end
