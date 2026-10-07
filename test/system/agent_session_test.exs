defmodule Jido.Statechart.AgentSessionTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Jido.AgentServer
  alias Jido.AgentServer.Plugin.Admission
  alias Jido.Statechart.Agent.Extension
  alias Jido.Statechart.Plugin.Runtime
  alias Jido.Statechart.{Agent, Chart, Flow, Limits, Plugin, Registry, Result, SemanticFixture}

  defmodule ParentAdapter do
    def idempotency, do: :operation_id

    def deliver(_signal, _operation_id, _context) do
      Process.sleep(500)
      :ok
    end
  end

  defmodule BoundChart do
    @chart SemanticFixture.chart("""
           <state id="root">
             <transition event="emit">
               <send event="notice" target="parent"/>
             </transition>
             <transition event="finish" target="done"/>
           </state>
           <final id="done"/>
           """)
    @registry Registry.new!(%{
                version: "agent-parent-1",
                entries: [
                  %{
                    kind: :target,
                    alias: "parent",
                    permissions: [
                      "delivery:at_least_once",
                      "idempotency:operation_id",
                      "send:event"
                    ],
                    metadata: %{
                      "allowed_signal_types" => ["notice"],
                      "scope" => "local_agent"
                    },
                    handler: Jido.Statechart.AgentSessionTest.ParentAdapter
                  }
                ]
              })
    use Chart, chart: @chart, registry: @registry
  end

  defmodule LiveAgent do
    use Jido.Agent,
      name: "statechart_live_agent",
      extensions: [Extension]

    agent do
      schema(Zoi.object(%{label: Zoi.string() |> Zoi.default("kept")}))
      plugin(Plugin, config: [duplicate_window: 2])
    end

    routes do
      route("finish", statechart: BoundChart)
    end
  end

  defmodule StoppingAgent do
    use Jido.Agent,
      name: "statechart_stopping_agent",
      extensions: [Extension]

    agent do
      schema(Zoi.object(%{label: Zoi.string() |> Zoi.default("kept")}))
      plugin(Plugin, config: [stop_on_done: true, rescan_interval: 10])
    end

    routes do
      route("finish", statechart: BoundChart)
    end
  end

  defmodule ProbeStore do
    @behaviour Jido.Persistence.Adapter

    def start_link(_opts), do: Elixir.Agent.start_link(fn -> %{} end)

    def child_spec(opts) do
      %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
    end

    @impl true
    def get(key, opts) do
      Elixir.Agent.get(Keyword.fetch!(opts, :store), fn records ->
        case Map.fetch(records, key) do
          {:ok, value} -> {:ok, value}
          :error -> {:error, :not_found}
        end
      end)
    end

    @impl true
    def put(key, value, opts),
      do: Elixir.Agent.update(Keyword.fetch!(opts, :store), &Map.put(&1, key, value))

    @impl true
    def compare_and_swap(key, expected, value, opts) do
      record = :erlang.binary_to_term(value, [:safe])

      Elixir.Agent.get_and_update(Keyword.fetch!(opts, :store), fn records ->
        if Map.get(records, key, :not_found) == expected do
          result = if record.revision == 0, do: :ok, else: {:error, :indeterminate}
          {result, Map.put(records, key, value)}
        else
          {{:error, :conflict}, records}
        end
      end)
    end

    @impl true
    def delete(key, opts),
      do: Elixir.Agent.update(Keyword.fetch!(opts, :store), &Map.delete(&1, key))
  end

  defmodule DropServer do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      {:ok,
       %{
         observer: Keyword.fetch!(opts, :observer),
         plugin_state: Keyword.fetch!(opts, :plugin_state),
         attempts: 0
       }}
    end

    @impl true
    def handle_call({:plugin_state, Plugin}, _from, state) do
      {:reply, {:ok, state.plugin_state}, state}
    end

    def handle_call(:status, _from, state) do
      {:reply, %{runtime: %{parent: nil}}, state}
    end

    @impl true
    def handle_cast({:signal, _token, signal}, state) do
      attempt = state.attempts + 1
      send(state.observer, {:cleanup_attempt, attempt, signal})
      {:noreply, %{state | attempts: attempt}}
    end
  end

  setup do
    jido = String.to_atom("statechart_jido_#{System.unique_integer([:positive])}")
    namespace = "statechart/test/#{System.unique_integer([:positive])}"
    start_supervised!({Jido, name: jido, namespace: namespace})
    {:ok, jido: jido}
  end

  test "the helper uses one authenticated initialization Turn", %{jido: jido} do
    assert {:error, :statechart_agent_not_found} = Agent.initialize(:missing_statechart_agent)
    assert {:error, :statechart_agent_not_found} = Runtime.rotate(:missing_statechart_agent)

    {:ok, server} = Jido.start_agent(jido, LiveAgent, id: "initialize-agent")
    assert AgentServer.snapshot(server).state_version == 0

    business = Jido.Signal.new!("finish", %{}, id: "before-init", source: "/test")
    assert {:error, :statechart_session_not_initialized} = AgentServer.call(server, business)
    assert AgentServer.snapshot(server).state_version == 0

    assert {:ok, initialized} = Agent.initialize(server)
    assert initialized.state.label == "kept"
    assert initialized.state.statechart.session.status == :active
    assert initialized.state.statechart.session.configuration == ["root"]
    assert AgentServer.snapshot(server).state_version == 1
  end

  test "live AgentServer state and direct Agent state use the same macrostep result", %{
    jido: jido
  } do
    {:ok, server} = Jido.start_agent(jido, LiveAgent, id: "equal-agent")
    assert {:ok, initialized} = Agent.initialize(server)

    signal = Jido.Signal.new!("emit", %{}, id: "shared-id", source: "/test")
    session = initialized.state.statechart.session
    event = Plugin.event(signal, session)

    assert {:ok, %Result{} = flow_result} =
             Flow.step(BoundChart.chart(), session, event, BoundChart.registry())

    assert [_intent] = flow_result.intents
    assert {:ok, direct, [_commit]} = Jido.Agent.cmd(initialized, signal)
    assert {:ok, live} = AgentServer.call(server, signal)
    assert live.state == direct.state
    assert AgentServer.snapshot(server).state_version == 2

    live_session = live.state.statechart.session

    assert live_session.operations
           |> Map.values()
           |> Enum.sort_by(& &1.generation) == flow_result.intents

    assert %{live_session | operations: %{}} == flow_result.session

    assert {:error, {:duplicate_signal, "shared-id"}} = AgentServer.call(server, signal)
    assert AgentServer.snapshot(server).state_version == 2
  end

  test "forged reserved Signals fail before route execution", %{jido: jido} do
    {:ok, first} = Jido.start_agent(jido, LiveAgent, id: "proof-first")
    {:ok, second} = Jido.start_agent(jido, LiveAgent, id: "proof-second")

    for type <- Agent.reserved_signal_types() do
      forged =
        Jido.Signal.new!(type, %{},
          id: "forged-#{type}",
          source: "/jido/statechart"
        )

      assert {:error, :invalid_runtime_proof} == AgentServer.call(first, forged), type
    end

    assert AgentServer.snapshot(first).state_version == 0

    assert {:ok, signed} = Runtime.initialization_signal(first)
    assert {:error, :invalid_runtime_proof} = AgentServer.call(second, signed)

    changed = %{signed | data: %{"changed" => true}}
    assert {:error, :invalid_runtime_proof} = AgentServer.call(first, changed)

    assert :ok = Runtime.rotate(first)
    assert {:error, :invalid_runtime_proof} = AgentServer.call(first, signed)

    assert {:ok, _agent} = Agent.initialize(first)
    state = AgentServer.plugin_state(first, Plugin) |> elem(1)
    assert {:ok, dumped} = Plugin.dump(state, persistence_context(:dump), chart: BoundChart)
    refute inspect(state) =~ "jidoscproof"
    refute inspect(dumped) =~ "jidoscproof"
  end

  test "proof signing rejects data above the configured data byte limit" do
    {server, runtime} = start_proof_runtime(Limits.new!(data_bytes: 0))

    assert {:error, :invalid_runtime_proof} = Runtime.initialization_signal(server)
    assert Process.alive?(runtime)
  end

  test "proof verification rejects data above the configured data byte limit" do
    data = %{"payload" => :binary.copy("x", 100)}
    data_bytes = :erlang.external_size(data, [:deterministic])
    {_server, runtime} = start_proof_runtime(Limits.new!(data_bytes: data_bytes))

    signal =
      Jido.Signal.new!(Agent.initialization_signal_type(), data,
        source: "/jido/statechart/runtime"
      )

    assert {:ok, signed} = GenServer.call(runtime, {:sign, signal, "initialize", 0})

    :sys.replace_state(runtime, fn state ->
      put_in(state, [:options, :limits], Limits.new!(data_bytes: data_bytes - 1))
    end)

    admission = %Admission{
      plugin: Plugin,
      agent_id: "proof-agent",
      agent_module: LiveAgent,
      signal: signed,
      caller_context: %{},
      plugin_state: Plugin.state(nil),
      prepared_input: %{},
      state_version: 0
    }

    assert {:error, :invalid_runtime_proof} = Runtime.verify(runtime, admission)
  end

  test "stop_on_done waits for a later authenticated cleanup Turn", %{jido: jido} do
    {:ok, server} = Jido.start_agent(jido, StoppingAgent, id: "stopping-agent")
    assert {:ok, _initialized} = Agent.initialize(server)
    assert :ok = eventually(fn -> AgentServer.status(server).phase == :idle end)
    monitor = Process.monitor(server)

    signal = Jido.Signal.new!("finish", %{}, id: "finish-id", source: "/test")
    assert {:ok, completed} = AgentServer.call(server, signal)
    assert completed.state.statechart.session.status == :completed
    assert completed.state.label == "kept"

    assert_receive {:DOWN, ^monitor, :process, ^server, :normal}, 2_000
  end

  test "a replacement runtime rescans a completed commit after a lost wake", %{jido: jido} do
    {:ok, server} = Jido.start_agent(jido, StoppingAgent, id: "replacement-rescan-agent")
    assert {:ok, _initialized} = Agent.initialize(server)
    monitor = Process.monitor(server)

    capture_log(fn ->
      runtime = :global.whereis_name({Runtime, server})
      assert is_pid(runtime)
      :ok = :sys.suspend(runtime)

      signal = Jido.Signal.new!("finish", %{}, id: "lost-wake-finish", source: "/test")
      assert {:ok, completed} = AgentServer.call(server, signal)
      assert completed.state.statechart.session.status == :completed

      Process.exit(runtime, :kill)

      assert_receive {:DOWN, ^monitor, :process, ^server, :normal}, 2_000
    end)
  end

  test "cleanup rescan retries the same request after a best-effort cast is dropped" do
    session =
      BoundChart.chart()
      |> SemanticFixture.session(
        status: :completed,
        configuration: ["done"],
        registry: BoundChart.registry()
      )
      |> then(&%{&1 | revision: 2, revision_fence: 2})

    server =
      start_supervised!(
        {DropServer, observer: self(), plugin_state: Plugin.state(session)},
        id: {:drop_server, System.unique_integer([:positive])}
      )

    init = %Jido.Plugin.Init{
      agent_server: server,
      agent_id: "drop-agent",
      module: Plugin,
      plugin_state: Plugin.state(session),
      state_version: 2,
      jido: nil,
      partition: nil,
      options: [stop_on_done: true, rescan_interval: 10]
    }

    runtime =
      start_supervised!({Runtime, init}, id: {:drop_runtime, System.unique_integer([:positive])})

    assert :ok = Runtime.await_ready(runtime, [])
    assert_receive {:cleanup_attempt, 1, first}, 1_000
    assert_receive {:cleanup_attempt, 2, second}, 1_000
    assert first.id == second.id
    assert first.data == second.data

    assert Jido.Signal.get_context(first, "jidoscproof") ==
             Jido.Signal.get_context(second, "jidoscproof")
  end

  test "a restored completed session is cleaned by readiness rescan", %{jido: jido} do
    table = String.to_atom("statechart_restore_#{System.unique_integer([:positive])}")
    persistence = {Jido.Persistence.ETS, table: table}
    id = "restored-completed-agent"

    session =
      BoundChart.chart()
      |> SemanticFixture.session(
        status: :completed,
        configuration: ["done"],
        registry: BoundChart.registry()
      )
      |> then(&%{&1 | revision: 2, revision_fence: 2})

    saved =
      StoppingAgent.new!(
        id: id,
        state: %{label: "kept", statechart: Plugin.state(session, ["finish-id"])}
      )

    assert :ok =
             Jido.Persistence.save_agent(persistence, saved, instance: jido, revision: 2)

    assert {:ok, server} =
             Jido.start_agent(jido, StoppingAgent,
               id: id,
               persistence: persistence,
               restore: :required,
               restart: :temporary
             )

    monitor = Process.monitor(server)
    assert_receive {:DOWN, ^monitor, :process, ^server, :normal}, 2_000

    assert {:ok, restored, 3} =
             Jido.Persistence.load_agent_with_revision(persistence, StoppingAgent, id,
               instance: jido
             )

    assert restored.state.statechart.session.status == :stopped
  end

  test "an indeterminate persisted initialization stops before dispatch and restores state", %{
    jido: jido
  } do
    store = start_supervised!(ProbeStore)
    persistence = {ProbeStore, store: store}
    id = "lost-persistence-agent"

    {:ok, server} =
      Jido.start_agent(jido, LiveAgent,
        id: id,
        persistence: persistence,
        restore: false,
        restart: :temporary
      )

    monitor = Process.monitor(server)
    assert {:error, {:persistence_failed, :indeterminate}} = Agent.initialize(server)
    assert_receive {:DOWN, ^monitor, :process, ^server, _reason}, 1_000
    refute Process.alive?(server)

    assert {:ok, restored, 1} =
             Jido.Persistence.load_agent_with_revision(persistence, LiveAgent, id, instance: jido)

    assert restored.state.statechart.session.status == :active
    assert restored.state.statechart.session.configuration == ["root"]
  end

  defp persistence_context(direction) do
    %Jido.Persistence.Plugin.Context{
      plugin: Plugin,
      plugin_vsn: 2,
      record_format: 3,
      direction: direction,
      reason: :test
    }
  end

  defp start_proof_runtime(limits) do
    server =
      start_supervised!(
        {DropServer, observer: self(), plugin_state: Plugin.state(nil)},
        id: {:proof_server, System.unique_integer([:positive])}
      )

    init = %Jido.Plugin.Init{
      agent_server: server,
      agent_id: "proof-agent",
      module: Plugin,
      plugin_state: Plugin.state(nil),
      state_version: 0,
      jido: nil,
      partition: nil,
      options: [chart: BoundChart, limits: limits]
    }

    runtime =
      start_supervised!(
        {Runtime, init},
        id: {:proof_runtime, System.unique_integer([:positive])}
      )

    {server, runtime}
  end

  defp eventually(predicate, attempts \\ 100)

  defp eventually(predicate, attempts) when attempts > 0 do
    if predicate.() do
      :ok
    else
      Process.sleep(10)
      eventually(predicate, attempts - 1)
    end
  end

  defp eventually(_predicate, 0), do: {:error, :timeout}
end
