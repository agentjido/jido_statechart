defmodule Jido.Statechart.ModelInvariantsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Jido.Statechart.{Diagnostic, Limits, Session}
  alias Jido.Statechart.Session.Operation

  property "duplicate and reordered operation results keep one terminal result" do
    check all(duplicates <- integer(1..8), max_runs: 30) do
      operation = operation_fixture()
      session = session_fixture(operation)

      assert {:ok, completed, :applied} =
               Session.apply_operation_result(
                 session,
                 operation.id,
                 operation.generation,
                 :confirmed_complete,
                 %{"receipt" => "ok"},
                 2
               )

      assert completed.revision_fence == 2
      assert {:ok, restored} = completed |> Session.dump() |> Session.load()

      final =
        Enum.reduce(1..duplicates, restored, fn _, current ->
          assert {:ok, next, :duplicate} =
                   Session.apply_operation_result(
                     current,
                     operation.id,
                     operation.generation,
                     :confirmed_complete,
                     %{"receipt" => "ok"},
                     2
                   )

          next
        end)

      assert final == restored
      assert final.operations[operation.id].state == :confirmed_complete
    end
  end

  property "older reordered results cannot replace a newer retryable result" do
    check all(newer_revision <- integer(2..100), max_runs: 20) do
      operation = operation_fixture()
      session = session_fixture(operation)

      assert {:ok, retryable, :applied} =
               Session.apply_operation_result(
                 session,
                 operation.id,
                 operation.generation,
                 :retryable_failure,
                 %{"reason" => "temporary"},
                 newer_revision
               )

      assert {:ok, ^retryable, :stale} =
               Session.apply_operation_result(
                 retryable,
                 operation.id,
                 operation.generation,
                 :confirmed_complete,
                 %{"receipt" => "old"},
                 newer_revision - 1
               )

      assert {:ok, complete, :applied} =
               Session.apply_operation_result(
                 retryable,
                 operation.id,
                 operation.generation,
                 :confirmed_complete,
                 %{"receipt" => "new"},
                 newer_revision + 1
               )

      assert complete.operations[operation.id].result == %{"receipt" => "new"}
    end
  end

  property "older and equal revisions are stale before transition legality" do
    check all(
            current_revision <- integer(2..100),
            incoming_revision <- integer(0..current_revision),
            max_runs: 30
          ) do
      operation =
        operation_fixture(%{
          state: :retryable_failure,
          attempt_count: 1,
          result: %{"reason" => "temporary"},
          result_revision: current_revision
        })

      session = session_fixture(operation)

      assert {:ok, ^session, :stale} =
               Session.apply_operation_result(
                 session,
                 operation.id,
                 operation.generation,
                 :canceled,
                 %{"reason" => "late"},
                 incoming_revision
               )
    end
  end

  property "stale generations and late tombstoned duplicates cannot change state" do
    check all(stale_generation <- integer(0..2), max_runs: 20) do
      operation = operation_fixture(%{generation: 3})
      session = session_fixture(operation)

      assert {:ok, unchanged, :stale} =
               Session.apply_operation_result(
                 session,
                 operation.id,
                 stale_generation,
                 :confirmed_complete,
                 %{"receipt" => "stale"},
                 2
               )

      assert unchanged == session

      {:ok, completed, :applied} =
        Session.apply_operation_result(
          session,
          operation.id,
          3,
          :confirmed_complete,
          %{"receipt" => "ok"},
          2
        )

      collected = Session.collect_terminal(completed, 1)
      refute Map.has_key?(collected.operations, operation.id)
      assert Map.has_key?(collected.operation_tombstones, operation.id)

      assert {:ok, ^collected, :duplicate} =
               Session.apply_operation_result(
                 collected,
                 operation.id,
                 3,
                 :confirmed_complete,
                 %{"receipt" => "ok"},
                 2
               )

      assert {:error, %Diagnostic{code: :operation_result_conflict}} =
               Session.apply_operation_result(
                 collected,
                 operation.id,
                 3,
                 :permanent_failure,
                 %{"reason" => "conflict"},
                 3
               )
    end
  end

  defp session_fixture(operation) do
    revision_fence = max(operation.created_revision, operation.result_revision || 0)

    Session.new!(%{
      id: "session-1",
      incarnation: "incarnation-1",
      chart_fingerprint: String.duplicate("a", 64),
      registry_digest: String.duplicate("b", 64),
      limits_digest: Limits.digest(Limits.default()),
      registry_version: "registry-1",
      revision_fence: revision_fence,
      operation_counter: operation.generation + 1,
      operations: %{operation.id => operation}
    })
  end

  defp operation_fixture(overrides \\ %{}) do
    attrs = %{
      session_incarnation: "incarnation-1",
      kind: :send,
      target: "parent",
      payload_digest: String.duplicate("c", 64),
      generation: 1,
      created_revision: 1,
      retention_class: :active
    }

    Operation.new!(Map.merge(attrs, overrides))
  end
end
