defmodule JidoStatechartTest.Fixtures do
  alias Jido.Statechart.{Event, Registry}

  def event(type, data \\ %{}), do: elem(Event.new(type, data), 1)

  def flat(overrides \\ %{}) do
    Map.merge(
      %{
        id: "switch",
        initial: "off",
        states: [
          %{id: "off", transitions: [%{event: "toggle", target: "on"}]},
          %{id: "on", transitions: [%{event: "toggle", target: "off"}]}
        ]
      },
      overrides
    )
  end

  def nested do
    %{
      id: "job",
      initial: "work",
      states: [
        %{
          id: "work",
          type: :compound,
          initial: "idle",
          entry: ["log"],
          exit: ["log"],
          transitions: [%{event: "done.state.work", target: "done"}]
        },
        %{
          id: "idle",
          parent: "work",
          entry: ["log"],
          exit: ["log"],
          transitions: [%{event: "go", target: "busy", actions: ["log", %{raise: "raised"}]}]
        },
        %{
          id: "busy",
          parent: "work",
          entry: ["log"],
          exit: ["log"],
          transitions: [%{target: "ready", actions: ["log"]}]
        },
        %{
          id: "ready",
          parent: "work",
          entry: ["log"],
          exit: ["log"],
          transitions: [
            %{event: "raised", target: "complete", actions: ["log", %{effect: "notify"}]}
          ]
        },
        %{id: "complete", parent: "work", type: :final, entry: ["log"], exit: ["log"]},
        %{id: "done", type: :final, entry: ["log"]}
      ]
    }
  end

  def logger_registry do
    %Registry{
      reducers: %{
        "log" => fn data, event, _ ->
          {:ok, Map.update(data, "events", [event.type], &(&1 ++ [event.type]))}
        end
      }
    }
  end
end

defmodule JidoStatechartTest.Door do
  use Jido.Statechart.Agent,
    name: "statechart_test_door",
    data_schema:
      Zoi.object(%{count: Zoi.integer() |> Zoi.min(0) |> Zoi.default(0)})
      |> Zoi.default(%{count: 0})

  statechart id: "door", initial: "closed" do
    state "closed", entry: ["increment"] do
      transition "open", target: "opened", actions: ["increment", %{effect: "notify"}]
      transition "invalid", actions: ["invalid"]
      transition "loop", target: "looping", actions: [%{effect: "notify"}]
      transition "missing_effect", actions: [%{effect: "missing"}]
    end

    state "opened" do
      transition "close", target: "closed"
    end

    state "looping" do
      transition nil, target: "looping"
    end
  end

  def registry do
    %Jido.Statechart.Registry{
      reducers: %{
        "increment" => fn data, _, _ -> {:ok, %{data | count: data.count + 1}} end,
        "invalid" => fn _, _, _ -> {:ok, %{count: -1}} end
      }
    }
  end

  def effects do
    %{
      "notify" => fn _ ->
        {:ok,
         %Jido.Agent.Directive.Emit{
           signal: %Jido.Signal{
             id: "statechart-effect",
             source: "/test",
             type: "chart.changed",
             time: "2026-10-06T00:00:00Z",
             data: %{}
           },
           dispatch: {:pid, [target: {:name, JidoStatechartTest.Observer}]}
         }}
      end
    }
  end
end

defmodule JidoStatechartTest.NestedDSL do
  use Jido.Statechart.Agent, name: "statechart_nested_dsl"

  statechart id: "nested", initial: "parent" do
    state "parent", initial: "child" do
      transition "finish", target: "end"

      state "child" do
        transition("tick")
      end
    end

    state "end", type: :final
  end
end
