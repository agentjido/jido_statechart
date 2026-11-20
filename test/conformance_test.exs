defmodule Jido.Statechart.ConformanceTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Jido.{AgentServer, Signal, Statechart}
  alias Jido.Statechart.Conformance
  alias Jido.Statechart.Conformance.HTTPListener
  alias Jido.Statechart.Plugin
  alias Mix.Tasks.Statechart.W3c

  @fixture Path.expand("fixtures/w3c/355/test355.txml", __DIR__)
  @origin_type_fixture Path.expand("fixtures/w3c/352/test352.txml", __DIR__)
  @manual_http Path.expand("fixtures/w3c/513/test513.txt", __DIR__)
  @templates Path.wildcard(Path.expand("fixtures/w3c/*/*.txml", __DIR__))
             |> Enum.reject(&Regex.match?(~r/\Atest\d+sub\d+\.txml\z/, Path.basename(&1)))

  test "W3C fixture 355 uses the first state in document order" do
    assert capture_io(fn -> W3c.run([@fixture]) end) =~ "PASS #{@fixture}"
  end

  @tag :tmp_dir
  test "the W3C manifest reports every start and fails on an unexpected result", %{tmp_dir: tmp} do
    fixtures = Path.dirname(Path.dirname(@fixture))

    for id <- [198, 352, 355] do
      file = "#{id}/test#{id}.txml"
      destination = Path.join(tmp, file)
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(Path.join(fixtures, file), destination)
    end

    manifest = Path.join(tmp, "manifest.xml")

    File.write!(manifest, """
    <assertions>
      <assert specnum="3.2">
        <test><start uri="missing.txml"/><start uri="355/test355.txml"/></test>
      </assert>
      <assert specnum="6.2"><test><start uri="198/test198.txml"/></test></assert>
      <assert specnum="C.1"><test><start uri="352/test352.txml"/></test></assert>
      <assert specnum="5.8"><test><start uri="301/test301.txml"/></test></assert>
    </assertions>
    """)

    output =
      capture_io(fn ->
        assert_raise Mix.Error, "W3C manifest has unexpected results", fn ->
          W3c.run(["--manifest", manifest])
        end
      end)

    assert output =~ "FAIL missing.txml"
    assert output =~ "PASS 355/test355.txml"
    assert output =~ "ADJUSTED 198/test198.txml"
    assert output =~ "XFAIL 352/test352.txml"
    assert output =~ "DEFERRED 301/test301.txml"
    assert output =~ "TOTAL 5  PASS 1  ADJUSTED 1  XFAIL 1  DEFERRED 1  FAIL 1"
  end

  for path <- [@manual_http | @templates] -- [@fixture, @origin_type_fixture] do
    test "W3C fixture #{Path.basename(path)} passes in a live Agent" do
      path = unquote(path)

      assert capture_io(fn -> W3c.run([path]) end) =~ "PASS #{path}"
    end
  end

  test "fixture 352 disagrees with the published SCXML origintype requirement" do
    assert_raise Mix.Error, ~r/^FAIL .*fixture_reached_fail/, fn ->
      W3c.run([@origin_type_fixture])
    end

    chart =
      Statechart.compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
        <state id="waiting">
          <onentry>
            <send event="received" type="http://www.w3.org/TR/scxml/#SCXMLEventProcessor"/>
          </onentry>
          <transition event="received" target="done"/>
        </state>
        <final id="done"/>
      </scxml>
      """)

    agent = Plugin.agent_definition("origin_type", chart, %{})

    assert :ok =
             Conformance.run(%{
               agent: agent,
               expect: %{
                 status: :completed,
                 event: %{
                   name: "received",
                   type: "external",
                   origin: "#_scxml_fixture",
                   origintype: "scxml"
                 }
               }
             })
  end

  test "a foreach loop cannot declare a system variable" do
    chart =
      Statechart.compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="jido">
        <state id="waiting">
          <onentry><foreach array="[7]" item="_sessionid"/></onentry>
          <transition event="error.execution" cond="full_event" target="done"/>
        </state>
        <final id="done"/>
      </scxml>
      """)

    agent =
      Plugin.agent_definition("read_only_system_variables", chart, %{
        guards: %{"full_event" => {__MODULE__, :full_event?}}
      })

    assert :ok =
             Conformance.run(%{
               agent: agent,
               expect: %{status: :completed, data: %{}}
             })
  end

  def full_event?(%{event: event}) do
    Enum.sort(Map.keys(event)) == ~w(data invokeid name origin origintype sendid type)a
  end

  test "child finalize writes returned data to the specified locations" do
    for {attributes, params, finalize, expected} <- [
          {~s(namelist="count"), "", "<finalize/>", 7},
          {"", ~s(<param name="count" location="count"/>), "<finalize/>", 7},
          {"", ~s(<param name="count" expr="count"/>), "<finalize/>", 1},
          {~s(namelist="count"), "", "", 1},
          {"", "", ~s(<finalize><assign location="count" expr="_event.data.count"/></finalize>),
           7}
        ] do
      chart =
        Statechart.compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="jido">
          <datamodel><data id="count" expr="1"/></datamodel>
          <state id="waiting">
            <invoke id="child" #{attributes}>
              #{params}
              <content>
                <scxml version="1.0" datamodel="jido">
                  <datamodel><data id="count"/></datamodel>
                  <final id="done"><donedata><param name="count" expr="7"/></donedata></final>
                </scxml>
              </content>
              #{finalize}
            </invoke>
            <transition event="done.invoke.child" target="finished"/>
          </state>
          <final id="finished"/>
        </scxml>
        """)

      agent = Plugin.agent_definition("finalize", chart, %{})

      assert :ok =
               Conformance.run(%{
                 agent: agent,
                 expect: %{status: :completed, data: %{"count" => expected}}
               })
    end
  end

  test "finalize rejects a nested event raise" do
    assert_raise ArgumentError, "SCXML finalize cannot execute raise", fn ->
      Statechart.compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
        <state id="waiting">
          <invoke src="urn:child">
            <finalize><if cond="In(waiting)"><raise event="bad"/></if></finalize>
          </invoke>
        </state>
      </scxml>
      """)
    end
  end

  test "an invoked Agent stops when its owner stops" do
    chart =
      Jido.Statechart.compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
        <state id="waiting">
          <invoke id="child">
            <content><scxml version="1.0"><state id="running"/></scxml></content>
          </invoke>
        </state>
      </scxml>
      """)

    instance = __MODULE__.OwnedInstance
    {:ok, root} = Jido.start_link(name: instance, namespace: "statechart-owned-invoke")

    try do
      parent = Jido.Statechart.Plugin.agent_definition("ownership_test", chart, %{})
      assert {:ok, server} = Jido.start_agent(instance, parent, id: "parent")
      assert {:ok, %{status: :committed}} = Jido.Statechart.initialize(server)
      assert {:ok, _status} = Jido.AgentServer.quiesce(server)

      child = Jido.Statechart.session(server).invocations["waiting"].child
      pid = Jido.whereis_agent(instance, child)
      monitor = Process.monitor(pid)
      assert :ok = Jido.stop_agent(instance, server)
      assert_receive {:DOWN, ^monitor, :process, ^pid, {:shutdown, :parent_down}}, 1_000
    after
      Supervisor.stop(root)
    end
  end

  test "child completion retries after the parent queue fills" do
    instance = __MODULE__.CompletionInstance

    {:ok, root} =
      Jido.start_link(name: instance, namespace: "statechart-completion", max_tasks: 1)

    handler = make_ref()

    assert :ok =
             :telemetry.attach_many(
               handler,
               [[:jido, :statechart, :log], [:jido, :statechart, :completion_retry]],
               &__MODULE__.observe_completion/4,
               {self(), instance}
             )

    try do
      child_start = ~s(<state id="running"><transition event="finish" target="finished"/></state>)
      agent = completion_parent(child_start)

      assert {:ok, parent} =
               Jido.start_agent(instance, agent, id: "gated_parent", max_postponed_signals: 0)

      assert {:ok, %{status: :committed}} = Statechart.initialize(parent)
      assert {:ok, _status} = AgentServer.quiesce(parent)
      assert {:ok, _status} = AgentServer.resume(parent)

      child_id = Statechart.session(parent).invocations["waiting"].child
      child = Jido.whereis_agent(instance, child_id)
      assert is_pid(child)
      monitor = Process.monitor(child)

      assert {:ok, %{status: :committed}} =
               AgentServer.call(parent, Signal.new!("hold", %{}, source: "/test"))

      assert_receive {:parent_held, gate}, 1_000

      try do
        assert {:ok, %{status: :committed}} =
                 AgentServer.call(child, Signal.new!("finish", %{}, source: "/test"))

        assert_receive {:completion_retry, ^parent, ^child_id, 0}, 1_000

        assert {:ok, %{status: :committed}} =
                 AgentServer.call(child, Signal.new!("probe", %{}, source: "/test"),
                   timeout: 1_000
                 )

        assert %{state: "waiting", data: %{"count" => 0}} = Statechart.session(parent)
      after
        send(gate, :release_parent)
      end

      assert_receive {:DOWN, ^monitor, :process, ^child, _reason}, 2_000
      assert_completed_invocation(parent)

      assert {:ok, fast_parent} =
               Jido.start_agent(instance, completion_parent(""), id: "fast_parent")

      assert {:ok, %{status: :committed}} = Statechart.initialize(fast_parent)
      assert_receive {:parent_finished, "fast_parent"}, 2_000
      assert {:ok, _status} = AgentServer.quiesce(fast_parent)
      assert_completed_invocation(fast_parent)

      assert Enum.sort(Jido.list_agents(instance)) == [
               {"fast_parent", fast_parent},
               {"gated_parent", parent}
             ]
    after
      :telemetry.detach(handler)
      Supervisor.stop(root)
    end
  end

  defp completion_parent(child_start) do
    chart =
      Statechart.compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" xmlns:j="urn:jido:statechart:1"
             version="1.0" datamodel="jido">
        <datamodel><data id="count" expr="0"/></datamodel>
        <state id="waiting">
          <invoke id="child">
            <content>
              <scxml version="1.0">
                #{child_start}
                <final id="finished"><onexit><send target="#_parent" event="reply"/></onexit></final>
              </scxml>
            </content>
          </invoke>
          <transition event="hold"><log label="hold parent"/></transition>
          <transition event="reply"><j:action id="count"/></transition>
          <transition event="done.invoke.child" target="finished"/>
        </state>
        <final id="finished"><onentry><log label="parent finished"/></onentry></final>
      </scxml>
      """)

    Plugin.agent_definition("completion_test", chart, %{
      actions: %{"count" => __MODULE__.CountReply}
    })
  end

  defp assert_completed_invocation(parent) do
    assert %{
             status: :completed,
             state: "finished",
             data: %{"count" => 1},
             invocations: invocations,
             event: %{name: "done.invoke.child"}
           } = Statechart.session(parent)

    assert invocations == %{}
  end

  def observe_completion(
        [:jido, :statechart, :log],
        _measurements,
        %{label: "hold parent", instance: instance, agent: "gated_parent"},
        {test, instance}
      ) do
    send(test, {:parent_held, self()})

    receive do
      :release_parent -> :ok
    after
      3_000 -> :ok
    end
  end

  def observe_completion(
        [:jido, :statechart, :log],
        _measurements,
        %{label: "parent finished", instance: instance, agent: "fast_parent"},
        {test, instance}
      ),
      do: send(test, {:parent_finished, "fast_parent"})

  def observe_completion(
        [:jido, :statechart, :completion_retry],
        _measurements,
        %{parent: parent, child: child, limit: limit},
        {test, _instance}
      ),
      do: send(test, {:completion_retry, parent, child, limit})

  def observe_completion(_event, _measurements, _metadata, _config), do: :ok

  defmodule CountReply do
    use Jido.Action, name: "count_child_reply"

    @impl true
    def run(params, _context), do: {:ok, %{"count" => params["count"] + 1}}
  end

  test "leaving an invoking state runs the child's exit handler before it stops" do
    Process.register(self(), __MODULE__.NotifyExit)

    chart =
      Statechart.compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" xmlns:j="urn:jido:statechart:1"
             version="1.0">
        <state id="waiting">
          <invoke id="child">
            <content>
              <scxml version="1.0">
                <state id="running"><onexit><j:action id="notify"/></onexit></state>
              </scxml>
            </content>
          </invoke>
          <transition event="leave" target="done"/>
        </state>
        <final id="done"/>
      </scxml>
      """)

    agent =
      Plugin.agent_definition("exit_handler", chart, %{
        actions: %{"notify" => __MODULE__.NotifyExit}
      })

    assert :ok =
             Conformance.run(%{
               agent: agent,
               events: ["leave"],
               expect: %{status: :completed, invocations: %{}},
               agent_count: 1
             })

    assert_receive :child_exited
  end

  defmodule NotifyExit do
    use Jido.Action, name: "notify_child_exit"

    @impl true
    def run(_params, _context) do
      send(Process.whereis(__MODULE__), :child_exited)
      {:ok, %{}}
    end
  end

  test "a failed child initialization clears its invocation and raises a chart error" do
    chart =
      Statechart.compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
        <state id="waiting">
          <invoke id="child" src="urn:test:child"/>
          <transition event="error.execution" target="recovered"/>
        </state>
        <final id="recovered"/>
      </scxml>
      """)

    child = Jido.Agent.define!(%{name: "no_chart"})

    agent =
      Plugin.agent_definition("failed_child", chart, %{invokes: %{"urn:test:child" => child}})

    assert :ok =
             Conformance.run(%{
               agent: agent,
               expect: %{state: "recovered", status: :completed, invocations: %{}},
               agent_count: 1
             })
  end

  test "send preserves raw text and empty data across a Signal" do
    for {content, expected} <- [{"", nil}, {"<content>  padded  </content>", "  padded  "}] do
      chart =
        Statechart.compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="jido">
          <datamodel><data id="event_name" expr="&quot;message&quot;"/></datamodel>
          <state id="waiting">
            <onentry><send eventexpr="event_name">#{content}</send></onentry>
            <transition event="message" target="finished"/>
          </state>
          <final id="finished"/>
        </scxml>
        """)

      agent = Plugin.agent_definition("send_contents", chart, %{})

      event = %{
        name: "message",
        type: "external",
        data: expected,
        origin: "#_scxml_fixture",
        origintype: "scxml"
      }

      assert :ok = Conformance.run(%{agent: agent, expect: %{status: :completed, event: event}})
    end
  end

  test "failed HTTP delivery raises error.communication for immediate and delayed sends" do
    assert {:ok, listener} = HTTPListener.start(self())

    try do
      port = :httpd.info(listener, [:port])[:port]

      for delay <- ["0", "1ms"] do
        chart =
          Statechart.compile!("""
          <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
            <state id="waiting">
              <onentry>
                <send event="test" delay="#{delay}" target="http://127.0.0.1:#{port}/missing"
                      type="http://www.w3.org/TR/scxml/#BasicHTTPEventProcessor"/>
              </onentry>
              <transition event="error.communication" target="recovered"/>
            </state>
            <final id="recovered"/>
          </scxml>
          """)

        agent = Plugin.agent_definition("failed_http", chart, %{})
        assert :ok = Conformance.run(%{agent: agent, expect: %{state: "recovered"}, http: true})
      end
    after
      :inets.stop(:httpd, listener)
    end
  end

  @tag :tmp_dir
  test "a synthetic template that reaches fail produces a failed Mix task", %{tmp_dir: tmp} do
    path = Path.join(tmp, "fails.txml")

    File.write!(path, """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0"
           xmlns:test="http://www.w3.org/2005/scxml-conformance" initial="test">
      <state id="test"><transition test:targetfail=""/></state>
      <test:pass/>
      <test:fail/>
    </scxml>
    """)

    assert_raise Mix.Error, ~r/^FAIL .*fixture_reached_fail/, fn -> W3c.run([path]) end
  end

  @tag :tmp_dir
  test "unsupported template markup produces a skip", %{tmp_dir: tmp} do
    path = Path.join(tmp, "unsupported.txml")

    File.write!(path, """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0"
           xmlns:test="http://www.w3.org/2005/scxml-conformance">
      <test:script/>
      <state id="test"><transition test:targetpass=""/></state>
      <test:pass/>
      <test:fail/>
    </scxml>
    """)

    assert_raise Mix.Error, ~r/^SKIP .*script/, fn -> W3c.run([path]) end
  end

  test "missing template produces an error rather than a verdict" do
    assert_raise Mix.Error, ~r/^ERROR /, fn ->
      W3c.run([@fixture <> ".missing"])
    end
  end

  @tag :tmp_dir
  test "a template must reach a verdict to pass", %{tmp_dir: tmp} do
    path = Path.join(tmp, "no-verdict.txml")

    File.write!(path, """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0"
           xmlns:conf="http://www.w3.org/2005/scxml-conformance">
      <final id="finished"/>
      <conf:pass/>
      <conf:fail/>
    </scxml>
    """)

    assert_raise Mix.Error, ~r/^FAIL .*missing_fixture_verdict/, fn -> W3c.run([path]) end
  end

  test "the Mix task requires a fixture or an example file" do
    assert_raise Mix.Error, ~r/^Usage:/, fn -> W3c.run([]) end
  end

  @tag :tmp_dir
  test "a raw SCXML file cannot act as a W3C template without its verdict markers", %{
    tmp_dir: tmp
  } do
    path = Path.join(tmp, "plain.txml")

    File.write!(path, """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
      <final id="finished"/>
    </scxml>
    """)

    assert_raise Mix.Error, ~r/^SKIP .*pass and fail marker/, fn -> W3c.run([path]) end
  end
end
