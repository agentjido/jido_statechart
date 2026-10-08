defmodule Jido.Statechart.ExecutableContentTest do
  use ExUnit.Case, async: true

  alias Jido.Statechart.DataModel.Jido, as: JidoDataModel
  alias Jido.Statechart.DataModel.Null, as: NullDataModel
  alias Jido.Statechart.{ExecutableContent, Limits, Registry, Session}
  alias Jido.Statechart.Expression.Reference
  alias Jido.Statechart.Model.Executable

  defmodule ReplaceDataAction do
    use Jido.Action, name: "replace_statechart_data"

    @impl true
    def run(params, _context), do: {:ok, params}
  end

  test "runs authored condition, raise, log, and data content in order" do
    registry =
      registry([
        expression("yes", true),
        expression("message", "selected"),
        expression("bad", self())
      ])

    commands = [
      executable(:log, 0, %{"label" => "before", "expr" => "message"}),
      %Executable{
        kind: :if,
        ordinal: 1,
        data: %{
          "branches" => [
            %{"kind" => "if", "condition" => "yes", "start" => 0, "count" => 2},
            %{"kind" => "else", "condition" => nil, "start" => 2, "count" => 1}
          ]
        },
        children: [
          executable(:raise, 0, %{"event" => "chosen"}),
          executable(:log, 1, %{"label" => "branch", "expr" => "message"}),
          executable(:raise, 2, %{"event" => "wrong"})
        ]
      },
      executable(:assign, 2, %{"location" => "value", "expr" => "bad"}),
      executable(:log, 3, %{"label" => "after", "expr" => "message"})
    ]

    state = %{
      data: %{"value" => "old"},
      system: %{"_event" => %{"name" => "external"}, "_sessionid" => "session-1"},
      active_state_ids: ["ready"],
      internal_queue: [],
      logs: [],
      intents: []
    }

    assert {:ok, result} =
             ExecutableContent.run(commands, state,
               data_model: JidoDataModel,
               registry: registry,
               limits: Limits.default()
             )

    assert result.data == state.data
    assert result.system == state.system
    assert Enum.map(result.logs, & &1["label"]) == ["before", "branch"]
    assert Enum.map(result.internal_queue, & &1["name"]) == ["chosen", "error.execution"]
    assert List.last(result.internal_queue)["data"]["code"] == "non_portable_value"
  end

  test "foreach uses stable snapshots and scoped loop bindings" do
    registry =
      registry([
        expression("items", %{"b" => 2, "a" => 1}),
        expression("item", Reference.binding("item")),
        expression("index", Reference.binding("index"))
      ])

    command = %Executable{
      kind: :foreach,
      ordinal: 0,
      data: %{"array" => "items", "item" => "item", "index" => "index"},
      children: [
        executable(:log, 0, %{"label" => "item", "expr" => "item"}),
        executable(:log, 1, %{"label" => "index", "expr" => "index"})
      ]
    }

    state = %{
      data: %{},
      system: %{"_event" => nil},
      bindings: %{"outside" => true},
      active_state_ids: [],
      internal_queue: [],
      logs: [],
      intents: []
    }

    assert {:ok, result} =
             ExecutableContent.run([command], state,
               data_model: JidoDataModel,
               registry: registry,
               limits: Limits.default()
             )

    assert Enum.map(result.logs, & &1["value"]) == [1, "a", 2, "b"]
    assert result.bindings == %{"outside" => true}
  end

  test "charges one shared work budget for commands and nested loop iterations" do
    registry =
      registry([
        expression("outer", [1, 2]),
        expression("inner", [3, 4])
      ])

    command = %Executable{
      kind: :foreach,
      ordinal: 0,
      data: %{"array" => "outer", "item" => "outer_item"},
      children: [
        %Executable{
          kind: :foreach,
          ordinal: 0,
          data: %{"array" => "inner", "item" => "inner_item"},
          children: [executable(:log, 0, %{"label" => "item"})]
        }
      ]
    }

    assert {:error, diagnostic} =
             ExecutableContent.run([command], %{},
               data_model: JidoDataModel,
               registry: registry,
               limits: Limits.new!(%{microsteps_per_macrostep: 5})
             )

    assert diagnostic.code == :executable_work_limit_exceeded
  end

  test "builds send and cancel intent without changing the current event" do
    registry = registry([expression("payload", 7), target("parent")])

    commands = [
      executable(:send, 0, %{
        "event" => "notice",
        "target" => "parent",
        "id" => "send-1",
        "params" => [%{"name" => "id", "expr" => "payload"}]
      }),
      executable(:cancel, 1, %{"sendid" => "send-1"})
    ]

    event = %{"name" => "external", "data" => %{"safe" => true}}
    state = %{data: %{}, system: %{"_event" => event}, active_state_ids: []}

    assert {:ok, result} =
             ExecutableContent.run(commands, state,
               data_model: JidoDataModel,
               registry: registry,
               limits: Limits.default()
             )

    assert result.system["_event"] == event
    assert result.generated_id_counter == 0

    assert result.intents == [
             %{
               "kind" => "send",
               "event" => "notice",
               "target" => "parent",
               "send_id" => "send-1",
               "delay" => nil,
               "type" => nil,
               "data" => [%{"name" => "id", "value" => 7}]
             },
             %{"kind" => "cancel", "send_id" => "send-1"}
           ]
  end

  test "builds send namelist payload in authored order and assigns a generated ID" do
    command =
      executable(:send, 0, %{
        "event" => "notice",
        "target" => "parent",
        "namelist" => "z a",
        "idlocation" => "send_id"
      })

    state = %{
      data: %{"send_id" => nil, "z" => 9, "a" => 1},
      system: %{"_sessionid" => "session-1"},
      session_incarnation: "incarnation-1",
      generated_id_counter: 4
    }

    assert {:ok, generated_id} =
             Session.generated_send_id("session-1", "incarnation-1", 4)

    assert {:ok, result} =
             ExecutableContent.run([command], state,
               data_model: JidoDataModel,
               registry: registry([target("parent")]),
               limits: Limits.default()
             )

    assert result.data["send_id"] == generated_id
    assert result.generated_id_counter == 5

    assert [
             %{
               "send_id" => ^generated_id,
               "data" => [
                 %{"name" => "z", "value" => 9},
                 %{"name" => "a", "value" => 1}
               ]
             }
           ] =
             result.intents

    assert {:ok, restored_counter} =
             %{Session.new!(session_attrs()) | generated_id_counter: result.generated_id_counter}
             |> Session.dump()
             |> Session.load()

    next_state =
      Map.merge(state, %{
        data: result.data,
        generated_id_counter: restored_counter.generated_id_counter,
        work_count: 0,
        intents: []
      })

    assert {:ok, next_result} =
             ExecutableContent.run([command], next_state,
               data_model: JidoDataModel,
               registry: registry([target("parent")]),
               limits: Limits.default()
             )

    assert {:ok, next_id} = Session.generated_send_id("session-1", "incarnation-1", 5)
    assert next_result.data["send_id"] == next_id
    refute next_id == generated_id
  end

  test "preserves duplicate namelist and param occurrences in authored order" do
    command =
      executable(:send, 0, %{
        "event" => "notice",
        "namelist" => "z z",
        "params" => [%{"name" => "z", "location" => "a"}]
      })

    assert {:ok, result} =
             ExecutableContent.run([command], %{data: %{"z" => 9, "a" => 1}},
               data_model: JidoDataModel,
               registry: registry([]),
               limits: Limits.default()
             )

    assert [
             %{
               "send_id" => nil,
               "data" => [
                 %{"name" => "z", "value" => 9},
                 %{"name" => "z", "value" => 9},
                 %{"name" => "z", "value" => 1}
               ]
             }
           ] = result.intents

    assert result.generated_id_counter == 0
  end

  test "rejects content-only send and prevalidates malformed commands" do
    commands = [
      executable(:send, 0, %{
        "content" => %{"items" => [%{"kind" => "text", "value" => "body"}]}
      })
    ]

    assert {:error, %{code: :invalid_executable_content}} =
             ExecutableContent.run(commands, %{},
               data_model: JidoDataModel,
               registry: registry([]),
               limits: Limits.default()
             )

    event_with_content =
      executable(:send, 0, %{
        "event" => "notice",
        "content" => %{"items" => [%{"kind" => "text", "value" => "body"}]}
      })

    assert {:ok, result} =
             ExecutableContent.run([event_with_content], %{},
               data_model: JidoDataModel,
               registry: registry([]),
               limits: Limits.default()
             )

    assert [%{"event" => "notice", "data" => "body", "send_id" => nil}] = result.intents

    malformed = [
      executable(:log, 0, %{"label" => "must-not-run"}),
      executable(:assign, 1, %{"location" => "value"})
    ]

    assert {:error, %{code: :invalid_executable_content}} =
             ExecutableContent.run(malformed, %{data: %{"value" => nil}},
               data_model: JidoDataModel,
               registry: registry([]),
               limits: Limits.default()
             )

    invalid_send =
      executable(:send, 0, %{
        "content" => %{"items" => []},
        "params" => [%{"name" => "value", "location" => "value"}]
      })

    assert {:error, %{code: :invalid_executable_content}} =
             ExecutableContent.run([invalid_send], %{data: %{"value" => 1}},
               data_model: JidoDataModel,
               registry: registry([]),
               limits: Limits.default()
             )

    reserved_id =
      executable(:send, 0, %{
        "event" => "notice",
        "id" => "#{Session.generated_id_prefix()}authored"
      })

    assert {:error, %{code: :invalid_executable_content}} =
             ExecutableContent.run([reserved_id], %{},
               data_model: JidoDataModel,
               registry: registry([]),
               limits: Limits.default()
             )
  end

  test "converts an empty required event expression to error.execution" do
    command = executable(:send, 0, %{"eventexpr" => "missing_event", "target" => "parent"})

    assert {:ok, result} =
             ExecutableContent.run([command], %{},
               data_model: JidoDataModel,
               registry: registry([expression("missing_event", nil)]),
               limits: Limits.default()
             )

    assert result.intents == []

    assert [%{"name" => "error.execution", "data" => %{"code" => "invalid_executable_value"}}] =
             result.internal_queue
  end

  test "converts send target, type, and permission failures to error.execution" do
    denied_permissions = ["delivery:at_least_once", "idempotency:operation_id"]

    cases = [
      {executable(:send, 0, %{"event" => "notice", "target" => "bad target"}), registry([]),
       :invalid_runtime_target},
      {executable(:send, 0, %{"event" => "notice", "type" => "urn:unsupported"}), registry([]),
       :unsupported_send_type},
      {executable(:send, 0, %{"event" => "notice", "target" => "parent"}),
       registry([target("parent", denied_permissions)]), :target_permission_denied}
    ]

    for {command, registry, code} <- cases do
      assert {:ok, result} =
               ExecutableContent.run([command], %{},
                 data_model: JidoDataModel,
                 registry: registry,
                 limits: Limits.default()
               )

      assert result.intents == []

      assert [%{"name" => "error.execution", "data" => %{"code" => error_code}}] =
               result.internal_queue

      assert error_code == Atom.to_string(code)
    end
  end

  test "enforces data bytes on complete log, event, and intent aggregates" do
    commands = [
      {executable(:log, 0, %{"label" => "bounded"}), :logs},
      {executable(:raise, 0, %{"event" => "bounded"}), :internal_queue},
      {executable(:send, 0, %{"event" => "bounded", "target" => "parent"}), :intents}
    ]

    for {command, field} <- commands do
      assert {:ok, first} =
               ExecutableContent.run([command], %{},
                 data_model: JidoDataModel,
                 registry: registry([target("parent")]),
                 limits: Limits.default()
               )

      aggregate_bytes = first |> Map.fetch!(field) |> portable_bytes()
      limited = Limits.new!(%{data_bytes: aggregate_bytes})
      state = Map.put(first, :work_count, 0)

      assert {:error, %{code: :data_limit_exceeded}} =
               ExecutableContent.run([command], state,
                 data_model: JidoDataModel,
                 registry: registry([target("parent")]),
                 limits: limited
               )
    end
  end

  test "treats statechart limit exhaustion as fatal" do
    limits = Limits.new!(%{internal_queue_events: 0})
    state = %{data: %{}, system: %{}, active_state_ids: [], internal_queue: []}
    command = executable(:raise, 0, %{"event" => "too-many"})

    assert {:error, diagnostic} =
             ExecutableContent.run([command], state,
               data_model: JidoDataModel,
               registry: registry([]),
               limits: limits
             )

    assert diagnostic.code == :internal_queue_limit_exceeded
  end

  test "runs a registered Action and applies its portable data result" do
    registry =
      registry([
        expression("params", %{"value" => "next"}),
        %{
          kind: :action,
          alias: "replace",
          permissions: ["execute"],
          handler: ReplaceDataAction
        }
      ])

    state = %{
      data: %{"value" => "old"},
      system: %{"_sessionid" => "session-1", "_event" => %{"name" => "work"}},
      active_state_ids: ["ready"]
    }

    command = executable(:action, 0, %{"id" => "replace", "params" => "params"})

    assert {:ok, result} =
             ExecutableContent.run([command], state,
               data_model: JidoDataModel,
               registry: registry,
               limits: Limits.default()
             )

    assert result.data == %{"value" => "next"}
  end

  test "rejects Actions and nonempty data under the null data model" do
    registry =
      registry([
        %{
          kind: :action,
          alias: "replace",
          permissions: ["execute"],
          handler: ReplaceDataAction
        }
      ])

    command = executable(:action, 0, %{"id" => "replace"})

    assert {:ok, result} =
             ExecutableContent.run([command], %{},
               data_model: NullDataModel,
               registry: registry,
               limits: Limits.default()
             )

    assert [%{"name" => "error.execution", "class" => "platform"}] = result.internal_queue

    assert {:error, %{code: :invalid_execution_state}} =
             ExecutableContent.run([], %{data: %{"unexpected" => true}},
               data_model: NullDataModel,
               registry: registry,
               limits: Limits.default()
             )
  end

  test "converts runtime expression type failures to error.execution" do
    conditional = %Executable{
      kind: :if,
      ordinal: 0,
      data: %{
        "branches" => [%{"kind" => "if", "condition" => "number", "start" => 0, "count" => 0}]
      },
      children: []
    }

    assert {:ok, result} =
             ExecutableContent.run([conditional], %{},
               data_model: JidoDataModel,
               registry: registry([expression("number", 1)]),
               limits: Limits.default()
             )

    assert [%{"name" => "error.execution", "data" => %{"code" => "condition_not_boolean"}}] =
             result.internal_queue
  end

  test "keeps internal sends in the FIFO queue and selects else branches" do
    registry = registry([expression("no", false)])

    conditional = %Executable{
      kind: :if,
      ordinal: 0,
      data: %{
        "branches" => [
          %{"kind" => "if", "condition" => "no", "start" => 0, "count" => 1},
          %{"kind" => "else", "condition" => nil, "start" => 1, "count" => 1}
        ]
      },
      children: [
        executable(:raise, 0, %{"event" => "wrong"}),
        executable(:send, 1, %{"event" => "inside", "target" => "#_internal"})
      ]
    }

    assert {:ok, result} =
             ExecutableContent.run([conditional], %{data: %{}, system: %{}, active_state_ids: []},
               data_model: JidoDataModel,
               registry: registry,
               limits: Limits.default()
             )

    assert Enum.map(result.internal_queue, & &1["name"]) == ["inside"]
    assert result.intents == []
  end

  test "rejects invalid execution contracts before content runs" do
    empty_registry = registry([])

    assert {:error, %{code: :invalid_executable_content}} = ExecutableContent.run(:bad, %{}, [])

    assert {:error, %{code: :invalid_executable_content}} =
             ExecutableContent.run([], %{}, [1])

    assert {:error, %{code: :invalid_registry}} =
             ExecutableContent.run([], %{}, data_model: JidoDataModel)

    assert {:error, %{code: :invalid_limits}} =
             ExecutableContent.run([], %{},
               data_model: JidoDataModel,
               registry: empty_registry,
               limits: :bad
             )

    forged_limits = %{Limits.default() | data_bytes: -1}

    assert {:error, %{code: :limit_out_of_range}} =
             ExecutableContent.run([], %{},
               data_model: JidoDataModel,
               registry: empty_registry,
               limits: forged_limits
             )

    assert {:error, %{code: :invalid_execution_state}} =
             ExecutableContent.run([], %{data: []},
               data_model: JidoDataModel,
               registry: empty_registry,
               limits: Limits.default()
             )

    for active_state_ids <- [["bad id"], [<<255>>], [String.duplicate("a", 256)]] do
      assert {:error, %{code: :invalid_execution_state}} =
               ExecutableContent.run([], %{active_state_ids: active_state_ids},
                 data_model: JidoDataModel,
                 registry: empty_registry,
                 limits: Limits.default()
               )
    end

    active_state_ids = [String.duplicate("a", 100)]
    active_bytes = portable_bytes(active_state_ids)

    assert {:error, %{code: :invalid_execution_state}} =
             ExecutableContent.run([], %{active_state_ids: active_state_ids},
               data_model: JidoDataModel,
               registry: empty_registry,
               limits: Limits.new!(%{data_bytes: active_bytes - 1})
             )

    assert {:ok, result} =
             ExecutableContent.run([executable(:log, 0, %{"label" => "empty"})], %{},
               data_model: JidoDataModel,
               registry: empty_registry,
               limits: Limits.default()
             )

    assert result.logs == [%{"label" => "empty", "value" => nil}]
  end

  defp executable(kind, ordinal, data) do
    %Executable{kind: kind, ordinal: ordinal, data: data, children: []}
  end

  defp expression(name, value) do
    %{
      kind: :expression,
      alias: name,
      permissions: [
        "evaluate",
        "read:bindings",
        "read:configuration",
        "read:data",
        "read:system"
      ],
      handler: {:expression, value}
    }
  end

  defp target(
         name,
         permissions \\ ["delivery:at_least_once", "idempotency:operation_id", "send:event"]
       ) do
    %{
      kind: :target,
      alias: name,
      permissions: permissions,
      handler: __MODULE__
    }
  end

  def idempotency, do: :operation_id
  def deliver(_signal, _operation_id, _context), do: :ok

  defp registry(entries), do: Registry.new!(%{version: "registry-1", entries: entries})

  defp portable_bytes(value),
    do: value |> :erlang.term_to_binary([:deterministic]) |> byte_size()

  defp session_attrs do
    %{
      id: "session-1",
      incarnation: "incarnation-1",
      chart_fingerprint: String.duplicate("a", 64),
      registry_digest: String.duplicate("b", 64),
      limits_digest: Limits.digest(Limits.default()),
      registry_version: "registry-1"
    }
  end
end
