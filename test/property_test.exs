defmodule JidoStatechartTest.PropertyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties
  alias Jido.Statechart, as: Chart
  alias Jido.Statechart.{Checkpoint, Compiler, Error, Interpreter, Limits, Validator}
  import JidoStatechartTest.Fixtures

  property "flat cycles agree with a reference model and restore at every step" do
    check all(size <- integer(2..12), steps <- integer(0..50), max_runs: 75) do
      ids = Enum.map(0..(size - 1), &"state-#{&1}")

      states =
        ids
        |> Enum.with_index()
        |> Enum.map(fn {id, i} ->
          %{id: id, transitions: [%{event: "next", target: Enum.at(ids, rem(i + 1, size))}]}
        end)

      definition = Chart.compile!(%{id: "cycle", initial: hd(ids), states: states})
      {:ok, start} = Chart.init(definition)

      instance =
        Enum.reduce(List.duplicate(:next, steps), start.instance, fn _, instance ->
          {:ok, result} = Chart.step(definition, instance, event("next"))
          assert {:ok, ^result} = Chart.step(definition, instance, event("next"))
          assert :ok = Validator.instance(definition, result.instance)
          assert {:ok, payload} = Checkpoint.dump(definition, result.instance)
          assert {:ok, restored} = Checkpoint.load(definition, payload)
          assert restored == result.instance
          restored
        end)

      assert instance.configuration.active == [Enum.at(ids, rem(steps, size))]
      assert Compiler.compile!(Compiler.to_data(definition)) == definition
    end
  end

  property "arbitrary data never crashes compiler or event boundaries" do
    check all(input <- term(), max_runs: 150) do
      assert match?({:ok, _}, Compiler.compile(input)) or
               match?({:error, %Error{}}, Compiler.compile(input))

      assert match?({:error, %Error{}}, Jido.Statechart.Event.validate(input, Limits.defaults()))
    end
  end

  test "external string IDs never become atoms" do
    for i <- 1..250 do
      id = "external-untrusted-identity-#{i}"
      event_id = id <> "-event"
      assert_raise ArgumentError, fn -> String.to_existing_atom(id) end
      assert_raise ArgumentError, fn -> String.to_existing_atom(event_id) end
      chart = Chart.compile!(%{"id" => id, "initial" => id, "states" => [%{"id" => id}]})
      {:ok, result} = Chart.init(chart)

      assert {:error, %Error{code: :unhandled_event}} =
               Chart.step(chart, result.instance, event(event_id))

      assert_raise ArgumentError, fn -> String.to_existing_atom(id) end
      assert_raise ArgumentError, fn -> String.to_existing_atom(event_id) end
    end
  end

  property "non-terminating work always fails within the selected bound" do
    check all(budget <- integer(8..100), max_runs: 50) do
      definition =
        Chart.compile!(%{
          id: "loop",
          initial: "a",
          limits: %{macrostep: budget},
          states: [%{id: "a", transitions: [%{target: "a"}]}]
        })

      instance = Interpreter.new_instance(definition, %{})

      assert {:error, %Error{code: :limit_exceeded, details: %{limit: :macrostep}}} =
               Interpreter.init(definition)

      assert instance.configuration.status == :new
      assert instance.data == %{}
    end
  end
end
