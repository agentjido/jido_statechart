defmodule Jido.Statechart.DataModel.JidoTest do
  use ExUnit.Case, async: true

  alias Jido.Expr
  alias Jido.Statechart.DataModel.Jido, as: JidoDataModel
  alias Jido.Statechart.{DataModel, Diagnostic, Expression, Limits, Location, Registry}
  alias Jido.Statechart.Expression.Reference

  test "resolves only registered expressions with declared permissions" do
    expression =
      Expr.new!(:and, [
        Expr.new!(:eq, [Reference.data("allowed"), true]),
        Reference.in_state("ready")
      ])

    registry = registry("enabled", expression, ["evaluate", "read:data", "read:configuration"])

    environment = %{
      data: %{"allowed" => true},
      system: %{"_sessionid" => "session-1"},
      active_state_ids: ["ready"]
    }

    assert {:ok, true} =
             JidoDataModel.condition("enabled", environment,
               registry: registry,
               limits: Limits.default()
             )

    assert {:error, %Diagnostic{code: :expression_not_registered}} =
             JidoDataModel.value("source text", environment,
               registry: registry,
               limits: Limits.default()
             )

    denied = registry("enabled", expression, ["evaluate"])

    assert {:error, %Diagnostic{code: :expression_permission_denied}} =
             JidoDataModel.condition("enabled", environment,
               registry: denied,
               limits: Limits.default()
             )

    scalar = registry("scalar", 1, ["evaluate"])

    assert {:error, %Diagnostic{code: :condition_not_boolean}} =
             JidoDataModel.condition("scalar", environment,
               registry: scalar,
               limits: Limits.default()
             )
  end

  test "reads system and loop bindings without exposing source evaluation" do
    expression =
      Expr.new!(:concat, [Reference.system("_event.name"), Reference.binding("suffix")])

    registry =
      registry("event_name", expression, ["evaluate", "read:system", "read:bindings"])

    environment = %{
      data: %{},
      system: %{"_event" => %{"name" => "work."}},
      bindings: %{"suffix" => "done"},
      active_state_ids: []
    }

    assert {:ok, "work.done"} =
             Expression.evaluate("event_name", environment,
               registry: registry,
               limits: Limits.default()
             )
  end

  test "assigns existing nested string-key locations and protects system variables" do
    data = %{"user" => %{"name" => "old"}, "_event" => %{"name" => "external"}}

    assert {:ok, updated} =
             JidoDataModel.assign("user.name", "new", data, limits: Limits.default())

    assert updated == %{"user" => %{"name" => "new"}, "_event" => %{"name" => "external"}}

    for location <- ["missing", "user.missing"] do
      assert {:error, %Diagnostic{code: :missing_location}} =
               JidoDataModel.assign(location, "new", data, limits: Limits.default())
    end

    assert {:error, %Diagnostic{code: :protected_location}} =
             JidoDataModel.assign("_event.name", "changed", data, limits: Limits.default())

    assert {:error, %Diagnostic{code: :invalid_location}} =
             JidoDataModel.assign("user.0", "changed", data, limits: Limits.default())

    assert {:error, %Diagnostic{code: :non_portable_value}} =
             JidoDataModel.assign("user.name", self(), data, limits: Limits.default())

    tiny = Limits.new!(%{data_bytes: 10})

    assert {:error, %Diagnostic{code: :data_limit_exceeded}} =
             JidoDataModel.assign("user.name", String.duplicate("x", 100), data, limits: tiny)
  end

  test "iterates one stable bounded snapshot" do
    list_registry = registry("items", ["b", "a"], ["evaluate"])

    assert {:ok, [{"b", 0}, {"a", 1}]} =
             JidoDataModel.iterate("items", %{data: %{}, active_state_ids: []},
               registry: list_registry,
               limits: Limits.default()
             )

    map_registry = registry("items", %{"b" => 2, "a" => 1}, ["evaluate"])

    assert {:ok, [{1, "a"}, {2, "b"}]} =
             JidoDataModel.iterate("items", %{data: %{}, active_state_ids: []},
               registry: map_registry,
               limits: Limits.default()
             )

    limits = Limits.new!(%{microsteps_per_macrostep: 1})

    assert {:error, %Diagnostic{code: :iteration_limit_exceeded}} =
             JidoDataModel.iterate("items", %{data: %{}, active_state_ids: []},
               registry: list_registry,
               limits: limits
             )
  end

  test "constructs expression, parameter, text, and embedded content values" do
    registry = registry("answer", 42, ["evaluate"])
    environment = %{data: %{"source" => "kept"}, active_state_ids: []}
    options = [registry: registry, limits: Limits.default()]

    assert {:ok, 42} =
             JidoDataModel.content(
               %{"expression" => "answer", "items" => []},
               environment,
               options
             )

    assert {:ok, "hello"} =
             JidoDataModel.content(
               %{"items" => [%{"kind" => "text", "value" => "hello"}]},
               environment,
               options
             )

    embedded = %{
      "items" => [
        %{
          "kind" => "element",
          "value" => %{
            "name" => %{"namespace" => "urn:test", "local" => "value"},
            "attributes" => [],
            "content" => [%{"kind" => "text", "value" => "x"}]
          }
        }
      ]
    }

    assert {:ok, ^embedded} = JidoDataModel.content(embedded, environment, options)

    assert {:ok,
            [
              %{"name" => "first", "value" => 42},
              %{"name" => "second", "value" => "kept"}
            ]} =
             JidoDataModel.construct(
               %{
                 "params" => [
                   %{"name" => "first", "expr" => "answer"},
                   %{"name" => "second", "location" => "source"}
                 ]
               },
               environment,
               options
             )
  end

  test "initializes string-keyed declarations and rejects unsafe shapes" do
    registry = registry("answer", 42, ["evaluate"])

    declarations = %{
      "count" => %{"expr" => "answer"},
      "message" => %{"content" => %{"items" => [%{"kind" => "text", "value" => "ok"}]}}
    }

    assert {:ok, %{"count" => 42, "message" => "ok"}} =
             JidoDataModel.initialize(declarations, %{data: %{}, active_state_ids: []},
               registry: registry,
               limits: Limits.default()
             )

    assert {:error, %Diagnostic{code: :invalid_data_key}} =
             JidoDataModel.initialize(%{atom_key: %{}}, %{}, limits: Limits.default())

    assert {:error, %Diagnostic{code: :protected_location}} =
             JidoDataModel.initialize(%{"_event" => %{}}, %{}, limits: Limits.default())

    assert {:error, %Diagnostic{code: :invalid_data_key}} =
             JidoDataModel.initialize(%{"user.name" => %{}}, %{}, limits: Limits.default())

    assert {:ok, %{"empty" => nil}} =
             JidoDataModel.initialize(%{"empty" => %{}}, %{}, limits: Limits.default())

    assert {:error, %Diagnostic{code: :invalid_data_declaration}} =
             JidoDataModel.initialize(%{"bad" => %{"unknown" => true}}, %{},
               limits: Limits.default()
             )

    assert {:error, %Diagnostic{code: :invalid_data}} =
             JidoDataModel.initialize([], %{}, limits: Limits.default())
  end

  test "initializes declarations by explicit document ordinal" do
    registry =
      Registry.new!(%{
        version: "registry-1",
        entries: [
          %{
            kind: :expression,
            alias: "z_value",
            permissions: ["evaluate"],
            handler: {:expression, 7}
          },
          %{
            kind: :expression,
            alias: "copy_z",
            permissions: ["evaluate", "read:data"],
            handler: {:expression, Reference.data("z")}
          }
        ]
      })

    declarations = %{
      "a" => %{"expr" => "copy_z", "ordinal" => 1},
      "z" => %{"expr" => "z_value", "ordinal" => 0}
    }

    assert {:ok, %{"a" => 7, "z" => 7}} =
             JidoDataModel.initialize(declarations, %{},
               registry: registry,
               limits: Limits.default()
             )
  end

  test "validates location and value edge cases without creating atoms" do
    assert JidoDataModel.capabilities().assignment
    assert {:ok, JidoDataModel} = DataModel.resolve("jido")
    assert {:ok, Jido.Statechart.DataModel.Null} = DataModel.resolve("null")
    assert {:error, %Diagnostic{code: :invalid_data_model}} = DataModel.resolve("dynamic")
    assert DataModel.protected_system_variables() == ~w(_event _sessionid _name _ioprocessors _x)
    refute DataModel.protected_location?(1)

    assert {:ok, ["user", "name"]} = Location.parse("user.name")
    assert {:ok, "Ada"} = Location.fetch(%{"user" => %{"name" => "Ada"}}, "user.name")

    assert {:error, %Diagnostic{code: :invalid_location}} = Location.parse(1)
    assert {:error, %Diagnostic{code: :missing_location}} = Location.fetch(%{}, "missing")
    assert {:error, %Diagnostic{code: :missing_location}} = Location.put(%{}, "missing", 1)

    assert_raise ArgumentError, fn -> Reference.data("bad.0") end
    assert_raise ArgumentError, fn -> Reference.in_state(1) end

    assert {:error, %Diagnostic{code: :invalid_data}} =
             JidoDataModel.assign("value", 1, [], limits: Limits.default())

    assert {:error, %Diagnostic{code: :invalid_iteration_value}} =
             JidoDataModel.iterate("scalar", %{data: %{}, active_state_ids: []},
               registry: registry("scalar", 1, ["evaluate"]),
               limits: Limits.default()
             )

    assert {:error, %Diagnostic{code: :invalid_data_key}} =
             DataModel.validate_value({%{atom_key: true}}, limits: Limits.default())

    assert {:error, %Diagnostic{code: :structured_data_forbidden}} =
             DataModel.validate_value(%{"nested" => [%URI{scheme: "https"}]},
               limits: Limits.default()
             )

    strict = Limits.new!(%{data_bytes: 10})

    assert {:error, %Diagnostic{code: :data_limit_exceeded}} =
             DataModel.validate_value(String.duplicate("x", 100),
               limits: strict,
               data_bytes: 10_000
             )
  end

  test "rejects malformed content and parameter containers" do
    options = [registry: registry("value", 1, ["evaluate"]), limits: Limits.default()]

    assert {:ok, nil} = JidoDataModel.construct(%{}, %{}, options)

    assert {:error, %Diagnostic{code: :invalid_content}} =
             JidoDataModel.construct(
               %{"params" => [%{"name" => "x", "expr" => "value"}], "content" => %{}},
               %{},
               options
             )

    assert {:ok,
            [
              %{"name" => "x", "value" => 1},
              %{"name" => "x", "value" => 1}
            ]} =
             JidoDataModel.construct(
               %{
                 "params" => [
                   %{"name" => "x", "expr" => "value"},
                   %{"name" => "x", "expr" => "value"}
                 ]
               },
               %{},
               options
             )

    assert {:error, %Diagnostic{code: :invalid_param}} =
             JidoDataModel.construct(%{"params" => [%{"name" => "x"}]}, %{}, options)

    assert {:error, %Diagnostic{code: :invalid_content}} =
             JidoDataModel.content([], %{}, options)

    assert {:error, %Diagnostic{code: :invalid_content}} =
             JidoDataModel.content(%{"expression" => 1}, %{}, options)

    assert {:error, %Diagnostic{code: :invalid_content}} =
             JidoDataModel.construct([], %{}, options)
  end

  test "enforces expression structure and resource limits" do
    limits = Limits.new!(%{expression_steps: 1})
    expression = Expr.new!(:eq, [1, 1])

    assert {:error, %Diagnostic{code: :expression_limit_exceeded}} =
             Expression.evaluate("limited", %{},
               registry: registry("limited", expression, ["evaluate"]),
               limits: limits
             )

    zero_bytes = Limits.new!(%{data_bytes: 0})

    assert {:error, %Diagnostic{code: :expression_limit_exceeded}} =
             Expression.evaluate("zero", %{},
               registry: registry("zero", nil, ["evaluate"]),
               limits: zero_bytes
             )

    assert {:error, %Diagnostic{code: :invalid_expression_id}} =
             Expression.evaluate(1, %{}, [])

    assert {:error, %Diagnostic{code: :invalid_expression_call}} =
             Expression.evaluate("value", %{}, [1])

    assert {:error, %Diagnostic{code: :invalid_limits}} =
             DataModel.validate_value(%{}, [1])

    assert {:error, %Diagnostic{code: :invalid_registry}} =
             Expression.evaluate("value", %{}, limits: Limits.default())

    assert {:error, %Diagnostic{code: :invalid_limits}} =
             Expression.evaluate("value", %{},
               registry: registry("value", 1, ["evaluate"]),
               limits: :invalid
             )

    forged = %{Limits.default() | expression_steps: 0}

    assert {:error, %Diagnostic{code: :limit_out_of_range}} =
             DataModel.validate_value(%{}, limits: forged)

    assert {:error, %Diagnostic{code: :limit_out_of_range}} =
             Expression.evaluate("value", %{},
               registry: registry("value", 1, ["evaluate"]),
               limits: forged
             )

    assert {:error, %Diagnostic{code: :limit_out_of_range}} =
             JidoDataModel.initialize(%{}, %{}, limits: forged)
  end

  test "accepts only inert registered expression values" do
    assert {:ok, 6} =
             Expression.evaluate("value", %{},
               registry: registry_handler("value", {:expression, 6}),
               limits: Limits.default()
             )

    for handler <- [String, {:invalid}, fn -> 7 end] do
      assert {:error, %Diagnostic{code: :invalid_expression_handler}} =
               Expression.evaluate("value", %{},
                 registry: registry_handler("value", handler),
                 limits: Limits.default()
               )
    end

    invalid_reference = %Reference{kind: :unknown}

    assert {:error, %Diagnostic{code: :invalid_expression_reference}} =
             Expression.evaluate("value", %{},
               registry: registry("value", invalid_reference, ["evaluate"]),
               limits: Limits.default()
             )
  end

  defp registry(name, expression, permissions) do
    registry_handler(name, {:expression, expression}, permissions)
  end

  defp registry_handler(name, handler, permissions \\ ["evaluate"]) do
    Registry.new!(%{
      version: "registry-1",
      entries: [
        %{
          kind: :expression,
          alias: name,
          permissions: permissions,
          handler: handler
        }
      ]
    })
  end
end
