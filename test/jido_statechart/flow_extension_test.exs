defmodule Jido.Statechart.FlowExtensionTest do
  use ExUnit.Case, async: true

  alias Jido.Statechart.{Chart, Flow, SemanticFixture}

  @chart SemanticFixture.chart("""
         <state id="root" initial="a">
           <state id="a"><transition event="go" target="done"/></state>
           <final id="done"/>
         </state>
         """)
  defmodule BoundChart do
    @chart SemanticFixture.chart("""
           <state id="root" initial="a">
             <state id="a"><transition event="go" target="done"/></state>
             <final id="done"/>
           </state>
           """)
    @registry SemanticFixture.registry()

    use Chart, chart: @chart, registry: @registry
  end

  defmodule ExtendedParent do
    use Jido.Flow,
      name: "statechart_parent",
      extensions: [Jido.Statechart.Flow.Extension]

    flow do
      statechart("chart", BoundChart, %{session: input(:session), event: input(:event)})
      output(result("chart"))
    end
  end

  defmodule ExplicitParent do
    use Jido.Flow, name: "statechart_parent"

    flow do
      step("chart",
        action: BoundChart,
        params: %{session: input(:session), event: input(:event)}
      )

      output(result("chart"))
    end
  end

  defmodule GenericExtendedParent do
    use Jido.Flow,
      name: "generic_statechart_parent",
      extensions: [Jido.Statechart.Flow.Extension]

    flow do
      statechart("chart", input(:statechart))
      output(result("chart"))
    end
  end

  defmodule GenericExplicitParent do
    use Jido.Flow, name: "generic_statechart_parent"

    flow do
      step("chart", action: Flow, params: input(:statechart))
      output(result("chart"))
    end
  end

  test "module and generic extension forms lower to explicit Subflows" do
    assert ExtendedParent.flow() == ExplicitParent.flow()
    assert GenericExtendedParent.flow() == GenericExplicitParent.flow()
    assert [%Jido.Flow.Subflow{}] = ExtendedParent.flow().components
    assert [%Jido.Flow.Subflow{}] = GenericExtendedParent.flow().components
  end

  test "the parent Subflow matches direct chart execution" do
    session = SemanticFixture.session(@chart, status: :active, configuration: ["a"])
    input = %{session: session, event: %{name: "go"}}
    assert {:ok, direct} = Jido.Exec.run(BoundChart, input)
    assert {:ok, ^direct} = Jido.Exec.run(ExtendedParent, input)
  end
end
