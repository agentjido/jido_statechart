defmodule Jido.Statechart.DataModel.NullTest do
  use ExUnit.Case, async: true

  alias Jido.Statechart.DataModel.Null
  alias Jido.Statechart.{Diagnostic, Limits}

  test "supports only the null data model and In predicate" do
    assert Null.capabilities() == %{
             assignment: false,
             content: true,
             data: false,
             iteration: false,
             predicate: ["In"]
           }

    environment = %{active_state_ids: ["ready", "child"]}

    assert {:ok, true} = Null.condition("In('ready')", environment, [])
    assert {:ok, false} = Null.condition(~s|In("other")|, environment, [])

    assert {:error, %Diagnostic{code: :invalid_null_expression}} =
             Null.condition("ready == true", environment, [])

    assert {:error, %Diagnostic{code: :null_data_forbidden}} =
             Null.initialize(%{"value" => 1}, environment, [])

    assert {:ok, %{}} = Null.initialize(%{}, environment, [])
  end

  test "rejects value, assignment, and iteration operations" do
    assert {:error, %Diagnostic{code: :null_expression_forbidden}} =
             Null.value("value", %{}, [])

    assert {:error, %Diagnostic{code: :null_assignment_forbidden}} =
             Null.assign("value", 1, %{}, [])

    assert {:error, %Diagnostic{code: :null_iteration_forbidden}} =
             Null.iterate("items", %{}, [])

    assert Null.protected?("_event")
    refute Null.protected?("value")
  end

  test "constructs bounded literal content without evaluating an expression" do
    content = %{
      "items" => [
        %{"kind" => "text", "value" => "hello "},
        %{"kind" => "cdata", "value" => "world"}
      ]
    }

    options = [limits: Limits.default()]

    assert {:ok, "hello world"} = Null.content(content, %{}, options)

    assert {:error, %Diagnostic{code: :null_expression_forbidden}} =
             Null.content(Map.put(content, "expression", "value"), %{}, options)

    assert {:ok, "hello world"} = Null.construct(%{"content" => content}, %{}, options)

    assert {:ok, nil} = Null.construct(%{}, %{}, [])

    assert {:error, %Diagnostic{code: :null_expression_forbidden}} =
             Null.construct(%{"params" => [%{"name" => "value", "expr" => "x"}]}, %{}, [])

    assert {:error, %Diagnostic{code: :invalid_content}} = Null.content([], %{}, [])
    assert {:error, %Diagnostic{code: :invalid_content}} = Null.construct([], %{}, [])
    assert {:error, %Diagnostic{code: :invalid_null_expression}} = Null.condition(1, %{}, [])

    forged = %{Limits.default() | data_bytes: -1}

    assert {:error, %Diagnostic{code: :limit_out_of_range}} =
             Null.condition("In('ready')", %{active_state_ids: ["ready"]}, limits: forged)
  end
end
