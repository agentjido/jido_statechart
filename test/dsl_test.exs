defmodule JidoStatechartTest.DSLTest do
  use ExUnit.Case, async: false
  alias Jido.Statechart.{Checkpoint, Compiler, Error, Limits}

  test "authoring macros build a normal Agent module through the core conventions" do
    [{mod, _binary}] =
      Code.compile_quoted(
        quote do
          defmodule JidoStatechartTest.CompiledChart do
            use Jido.Statechart.Agent, name: "compiled_chart"

            statechart id: "compiled", initial: "parent" do
              state "parent", initial: "child" do
                state("child")
                transition "go", target: "end"
              end

              state "end", type: :final
            end
          end
        end
      )

    assert mod.vsn() == 1
    assert mod.registry() == %Jido.Statechart.Registry{}
    assert mod.effects() == %{}
    assert {:ok, instance} = Jido.Agent.instantiate(mod)
    signal = Jido.Signal.new!("go", %{}, source: "/test")
    assert {:ok, final, []} = mod.cmd(instance, signal)
    assert final.state.chart.status == "done"
    assert {:ok, checkpoint} = Jido.Agent.checkpoint(final)
    assert {:ok, ^final} = Jido.Agent.restore(mod, checkpoint)
    assert {:ok, instance} = mod.new()
    assert instance == mod.new!(id: instance.id)
  end

  test "DSL rejects non-state declarations and invalid transitions" do
    for block <- [
          quote(do: :invalid),
          quote(do: state("a", do: :invalid)),
          quote(do: state("a", do: transition("go", [], :bad)))
        ] do
      assert_raise ArgumentError, fn ->
        Code.compile_quoted(
          quote do
            defmodule JidoStatechartTest.BadDSL do
              use Jido.Statechart.Agent, name: "bad_dsl"

              statechart id: "bad", initial: "a" do
                unquote(block)
              end
            end
          end
        )
      end
    end
  end

  test "DSL requires one chart and rejects duplicate blocks" do
    assert_raise ArgumentError, fn ->
      Code.compile_quoted(
        quote do
          defmodule JidoStatechartTest.NoChart do
            use Jido.Statechart.Agent, name: "no_chart"
          end
        end
      )
    end

    assert_raise ArgumentError, fn ->
      Code.compile_quoted(
        quote do
          defmodule JidoStatechartTest.TwoCharts do
            use Jido.Statechart.Agent, name: "two_charts"

            statechart id: "one", initial: "a" do
              state("a")
            end

            statechart id: "two", initial: "b" do
              state("b")
            end
          end
        end
      )
    end
  end

  test "XML Agent declaration accepts compile options and rejects mixed declarations" do
    [{module, _}] =
      Code.compile_quoted(
        quote do
          defmodule JidoStatechartTest.XMLCompiled do
            use Jido.Statechart.Agent, name: "xml_compiled"

            statechart_xml(
              "<scxml xmlns=\"http://www.w3.org/2005/07/scxml\" version=\"1.0\"><state id=\"a\"/></scxml>",
              id: "custom",
              version: "2"
            )
          end
        end
      )

    assert module.chart_definition().id == "custom"
    assert module.chart_definition().version == "2"

    for xml_first? <- [true, false] do
      xml =
        quote do
          statechart_xml(
            "<scxml xmlns=\"http://www.w3.org/2005/07/scxml\" version=\"1.0\"><state id=\"a\"/></scxml>"
          )
        end

      data =
        quote do
          statechart id: "data", initial: "a" do
            state("a")
          end
        end

      declarations = if xml_first?, do: [xml, data], else: [data, xml]

      assert_raise ArgumentError, fn ->
        Code.compile_quoted(
          quote do
            defmodule JidoStatechartTest.MixedChart do
              use Jido.Statechart.Agent, name: "mixed_chart"
              unquote_splicing(declarations)
            end
          end
        )
      end
    end
  end

  test "core facade returns typed errors for invalid initialization and checkpoints" do
    assert {:error, %Error{}} = Jido.Statechart.init(%{})
    defn = Compiler.compile!(JidoStatechartTest.Fixtures.flat())
    assert {:error, %Error{}} = Checkpoint.dump(defn, %{})
    assert {:error, %Error{}} = Limits.new(%{"macrostep" => 2, macrostep: 1})
    assert {:error, %Error{}} = Limits.new(nil)
    assert {:error, %Error{}} = Jido.Statechart.Validator.definition(%{defn | states: %{}})
  end
end
