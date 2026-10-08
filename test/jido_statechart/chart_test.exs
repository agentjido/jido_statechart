defmodule Jido.Statechart.ChartTest do
  use ExUnit.Case, async: true

  alias Jido.Statechart.Model.Event
  alias Jido.Statechart.{Chart, Diagnostic, Flow, Limits, Result, SemanticFixture}

  @chart SemanticFixture.chart("""
         <state id="root" initial="a">
           <state id="a"><transition event="go" target="done"/></state>
           <final id="done"/>
         </state>
         """)
  @registry SemanticFixture.registry()

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

  test "a chart module binds its chart and Registry and matches the generic Flow" do
    session = SemanticFixture.session(@chart, status: :active, configuration: ["a"])
    event = %{name: "go"}

    generic_input = Flow.input(@chart, session, event, @registry)
    assert {:ok, %Result{} = generic} = Jido.Exec.run(Flow, generic_input)
    assert {:ok, ^generic} = Jido.Statechart.step(@chart, session, event, registry: @registry)
    assert {:ok, ^generic} = Jido.Statechart.run(@chart, session, event, @registry)
    assert {:ok, ^generic} = Jido.Exec.run(BoundChart, %{session: session, event: event})
    assert {:ok, ^generic} = BoundChart.run(session, event)
    assert BoundChart.flow() == Flow.flow()
  end

  test "initialization agrees through direct, generic, and chart module entry paths" do
    session = SemanticFixture.session(@chart)
    generic_input = Flow.input(@chart, session, nil, @registry, operation: :initialize)

    assert {:ok, %Result{} = generic} = Jido.Exec.run(Flow, generic_input)
    assert {:ok, ^generic} = Jido.Statechart.initialize(@chart, session, registry: @registry)
    assert {:ok, ^generic} = BoundChart.initialize(session)
  end

  test "a chart module rejects caller overrides and protected context" do
    session = SemanticFixture.session(@chart, status: :active, configuration: ["a"])
    input = %{session: session, event: %{name: "go"}}

    for override <- [
          %{chart: @chart},
          %{"chart" => @chart},
          %{registry: @registry},
          %{"registry" => @registry},
          %{context: %{}},
          %{"context" => %{}}
        ] do
      assert {:error, _error} = Jido.Exec.run(BoundChart, Map.merge(input, override))
    end

    for protected <- [:chart, "chart", :registry, "registry", :statechart, "statechart"] do
      assert {:error, _error} = Jido.Exec.run(BoundChart, input, %{protected => :replace})
    end
  end

  test "Chart helpers reject invalid input and invalid use options" do
    assert {:error, %{code: :invalid_flow_input}} = Chart.bind_input(:invalid, @chart, @registry)

    assert {:error, %{code: :invalid_flow_input}} =
             Chart.bind_input(%{session: :invalid}, @chart, @registry)

    assert_raise ArgumentError, ~r/options must be a keyword list/, fn ->
      Code.compile_string("""
      defmodule InvalidStatechartUse do
        use Jido.Statechart.Chart, :invalid
      end
      """)
    end

    assert_raise ArgumentError, ~r/unknown option/, fn ->
      Code.compile_string("""
      defmodule UnknownStatechartUse do
        use Jido.Statechart.Chart, chart: :chart, registry: :registry, unknown: true
      end
      """)
    end

    session = SemanticFixture.session(@chart, status: :active, configuration: ["a"])

    for options <- [%{}, [:timeout], [unknown: true], [timeout: 1, timeout: 2]] do
      assert {:error, %Diagnostic{code: :invalid_flow_options}} =
               BoundChart.run(session, %{name: "go"}, options)
    end

    assert {:error, %Jido.Exec.Error.TimeoutError{timeout: 0}} =
             BoundChart.run(session, %{name: "go"}, timeout: 0)

    limits = Limits.new!(%{microsteps_per_macrostep: 1})

    limited_session =
      SemanticFixture.session(@chart, status: :active, configuration: ["a"], limits: limits)

    assert {:ok, %Result{}} = BoundChart.run(limited_session, %{name: "go"}, limits: limits)
  end

  test "root helpers validate and forward their public options" do
    session = SemanticFixture.session(@chart, status: :active, configuration: ["a"])
    event = %{name: "go"}

    for options <- [%{}, [:timeout], [unknown: true], [timeout: 1, timeout: 2]] do
      options = if is_list(options), do: Keyword.put(options, :registry, @registry), else: options

      assert {:error, %Diagnostic{code: :invalid_flow_options}} =
               Jido.Statechart.step(@chart, session, event, options)
    end

    assert {:error, %Jido.Exec.Error.TimeoutError{timeout: 0}} =
             Jido.Statechart.step(@chart, session, event, registry: @registry, timeout: 0)
  end

  test "all direct entry paths require a valid external event" do
    session = SemanticFixture.session(@chart, status: :active, configuration: ["a"])

    runners = [
      fn event -> Flow.step(@chart, session, event, @registry) end,
      fn event -> Jido.Exec.run(Flow, Flow.input(@chart, session, event, @registry)) end,
      fn event -> Jido.Statechart.step(@chart, session, event, @registry) end,
      fn event -> BoundChart.run(session, event) end
    ]

    invalid_events = [
      %{},
      %{name: ""},
      %Event{name: nil, class: :external},
      %{name: "go", class: :internal},
      %{name: "go", class: :platform},
      Event.new!(%{name: "go", class: :internal}),
      Event.new!(%{name: "go", class: :platform})
    ]

    for runner <- runners, event <- invalid_events do
      assert {:error, _error} = runner.(event)
    end

    valid_events = [
      %{name: "go"},
      %{name: "go", class: :external},
      Event.new!(%{name: "go", class: :external})
    ]

    for runner <- runners, event <- valid_events do
      assert {:ok, %Result{session: %{configuration: ["done"]}}} = runner.(event)
    end
  end
end
