defmodule JidoStatechartTest.InterpreterTest do
  use ExUnit.Case, async: true
  alias Jido.Statechart, as: Chart

  alias Jido.Statechart.{
    Configuration,
    Data,
    Effect,
    Error,
    Event,
    Interpreter,
    Limits,
    Registry,
    Validator
  }

  import JidoStatechartTest.Fixtures

  test "flat chart runs one event and rejects an unhandled event without changing input" do
    definition = Chart.compile!(flat())
    assert {:ok, start} = Chart.init(definition)
    assert start.instance.configuration.active == ["off"]
    assert start.trace == [%{op: :entry, state: "off"}]
    assert {:ok, result} = Chart.step(definition, start.instance, event("toggle"))
    assert result.instance.configuration.active == ["on"]
    assert result.stats.transitions == 1

    assert {:error, %Error{code: :unhandled_event}} =
             Chart.step(definition, start.instance, event("unknown"))

    assert start.instance.configuration.active == ["off"]
  end

  test "compound chart trace matches a fixed fixture and is deterministic" do
    definition = Chart.compile!(nested())
    registry = logger_registry()
    assert {:ok, start} = Chart.init(definition, %{}, registry)
    assert start.instance.configuration.active == ["work", "idle"]
    assert {:ok, result} = Chart.step(definition, start.instance, event("go"), registry)

    expected =
      File.read!(Path.join(__DIR__, "fixtures/nested_trace.exs")) |> Code.eval_string() |> elem(0)

    assert result.trace == expected
    assert result.instance.configuration.active == ["done"]
    assert result.instance.configuration.status == :done
    assert result.effects == [%Effect{id: "notify", data: %{}}]
    assert {:ok, ^result} = Chart.step(definition, start.instance, event("go"), registry)

    assert {:error, %Error{code: :chart_done}} =
             Chart.step(definition, result.instance, event("go"), registry)
  end

  test "deepest enabled source wins, then priority, then document order" do
    definition =
      Chart.compile!(%{
        id: "p",
        initial: "parent",
        states: [
          %{
            id: "parent",
            type: :compound,
            initial: "child",
            transitions: [%{event: "go", target: "fallback", priority: 999}]
          },
          %{
            id: "child",
            parent: "parent",
            transitions: [
              %{event: "go", target: "first", priority: 1, guard: "no"},
              %{event: "go", target: "second", priority: 1},
              %{event: "go", target: "third", priority: 0}
            ]
          },
          %{id: "fallback"},
          %{id: "first"},
          %{id: "second"},
          %{id: "third"}
        ]
      })

    registry = %Registry{guards: %{"no" => fn _, _ -> false end}}
    {:ok, start} = Chart.init(definition, %{}, registry)
    {:ok, result} = Chart.step(definition, start.instance, event("go"), registry)
    assert result.instance.configuration.active == ["second"]
    assert Enum.find(result.trace, &(&1.op == :guard)) == %{op: :guard, id: "no", enabled: false}

    swapped =
      Chart.compile!(%{
        id: "p",
        initial: "a",
        states: [
          %{
            id: "a",
            transitions: [
              %{event: "go", target: "b"},
              %{event: "go", target: "c", priority: 1}
            ]
          },
          %{id: "b"},
          %{id: "c"}
        ]
      })

    {:ok, start} = Chart.init(swapped)
    assert {:ok, result} = Chart.step(swapped, start.instance, event("go"))
    assert result.instance.configuration.active == ["c"]
  end

  test "ancestor fallback runs when every child guard rejects the event" do
    defn =
      Chart.compile!(%{
        id: "x",
        initial: "p",
        states: [
          %{id: "p", type: :compound, initial: "a", transitions: [%{event: "go", target: "b"}]},
          %{id: "a", parent: "p", transitions: [%{event: "go", guard: "no"}]},
          %{id: "b"}
        ]
      })

    reg = %Registry{guards: %{"no" => fn _, _ -> false end}}
    {:ok, start} = Chart.init(defn, %{}, reg)
    {:ok, result} = Chart.step(defn, start.instance, event("go"), reg)
    assert result.instance.configuration.active == ["b"]
  end

  test "external self transition exits and reenters but targetless transition does not" do
    defn =
      Chart.compile!(%{
        id: "x",
        initial: "a",
        states: [
          %{
            id: "a",
            transitions: [
              %{event: "self", target: "a"},
              %{event: "stay"}
            ]
          }
        ]
      })

    {:ok, start} = Chart.init(defn)
    {:ok, result} = Chart.step(defn, start.instance, event("self"))
    assert Enum.map(result.trace, & &1.op) == [:transition, :exit, :entry]
    {:ok, result} = Chart.step(defn, start.instance, event("stay"))
    assert Enum.map(result.trace, & &1.op) == [:transition]
  end

  test "internal descendant transition keeps the source, external transition reenters it" do
    for kind <- [:internal, :external] do
      defn =
        Chart.compile!(%{
          id: "x",
          initial: "p",
          states: [
            %{
              id: "p",
              type: :compound,
              initial: "a",
              transitions: [%{event: "go", target: "b", kind: kind}]
            },
            %{id: "a", parent: "p"},
            %{id: "b", parent: "p"}
          ]
        })

      {:ok, start} = Chart.init(defn)
      {:ok, result} = Chart.step(defn, start.instance, event("go"))
      assert result.instance.configuration.active == ["p", "b"]
      ops = Enum.map(result.trace, & &1.op)

      assert ops ==
               if(kind == :internal,
                 do: [:transition, :exit, :entry],
                 else: [:transition, :exit, :exit, :entry, :entry]
               )
    end
  end

  test "targeting an ancestor exits and reenters its initial descendant" do
    defn =
      Chart.compile!(%{
        id: "x",
        initial: "p",
        states: [
          %{id: "p", type: :compound, initial: "a"},
          %{id: "a", parent: "p", transitions: [%{event: "reset", target: "p"}]}
        ]
      })

    {:ok, start} = Chart.init(defn)
    {:ok, result} = Chart.step(defn, start.instance, event("reset"))
    assert Enum.map(result.trace, & &1.op) == [:transition, :exit, :exit, :entry, :entry]
  end

  test "FIFO raised events run after eventless transitions and use their own event data" do
    defn =
      Chart.compile!(%{
        id: "x",
        initial: "a",
        states: [
          %{
            id: "a",
            transitions: [
              %{
                event: "go",
                target: "b",
                actions: [
                  %{raise: "one", data: %{value: 1}},
                  %{raise: "two", data: %{value: 2}},
                  %{raise: "unused"}
                ]
              }
            ]
          },
          %{id: "b", transitions: [%{target: "c", actions: ["record"]}]},
          %{
            id: "c",
            transitions: [
              %{event: "one", actions: ["record"]},
              %{event: "two", actions: ["record"]}
            ]
          }
        ]
      })

    # Stored domain data is portable scalar/list/map data, so use map records.
    reg = %Registry{
      reducers: %{
        "record" => fn data, event, _ ->
          {:ok,
           Map.update(
             data,
             "seen",
             [%{type: event.type, data: event.data}],
             &(&1 ++ [%{type: event.type, data: event.data}])
           )}
        end
      }
    }

    {:ok, start} = Chart.init(defn, %{}, reg)
    {:ok, result} = Chart.step(defn, start.instance, event("go", %{value: 0}), reg)
    assert Enum.map(result.instance.data["seen"], & &1.type) == ["go", "one", "two"]
    assert Enum.map(result.instance.data["seen"], & &1.data.value) == [0, 1, 2]
    assert %{op: :unhandled_internal, event: "unused"} in result.trace
  end

  test "reducers can raise internal events and request ordered effects" do
    defn =
      Chart.compile!(%{
        id: "x",
        initial: "a",
        states: [
          %{
            id: "a",
            transitions: [
              %{event: "go", actions: ["reduce", %{effect: "last"}]},
              %{event: "inside", actions: [%{effect: "internal"}]}
            ]
          }
        ]
      })

    reg = %Registry{
      reducers: %{
        "reduce" => fn data, _, params ->
          assert params == %{}

          {:ok, Map.put(data, "ok", true),
           [%Effect{id: "first", data: %{}}, %Event{type: "inside", kind: :internal}]}
        end
      }
    }

    {:ok, start} = Chart.init(defn, %{}, reg)
    {:ok, result} = Chart.step(defn, start.instance, event("go"), reg)
    assert Enum.map(result.effects, & &1.id) == ["first", "last", "internal"]
    assert result.instance.data == %{"ok" => true}
  end

  test "first event initializes and processes in one budget" do
    defn = Chart.compile!(flat())
    new = Interpreter.new_instance(defn, %{})
    assert :ok = Validator.instance(defn, new)
    assert {:ok, result} = Chart.step(defn, new, event("toggle"))
    assert result.instance.configuration.active == ["on"]
    assert hd(result.trace) == %{op: :entry, state: "off"}
  end

  test "initial eventless transitions, completion and final root are supported" do
    defn =
      Chart.compile!(%{
        id: "x",
        initial: "a",
        states: [%{id: "a", transitions: [%{target: "b"}]}, %{id: "b", type: :final}]
      })

    {:ok, result} = Chart.init(defn)
    assert result.instance.configuration.status == :done

    defn =
      Chart.compile!(%{
        id: "x",
        initial: "p",
        states: [%{id: "p", type: :compound, initial: "f"}, %{id: "f", parent: "p", type: :final}]
      })

    {:ok, result} = Chart.init(defn)
    assert result.instance.configuration.status == :running
    assert %{op: :unhandled_internal, event: "done.state.p"} in result.trace
  end

  test "non-terminating eventless and internal-event loops return no candidate" do
    for transitions <- [
          [%{target: "a", actions: [%{effect: "never"}]}],
          [%{event: "spin", actions: [%{raise: "spin"}]}]
        ] do
      defn =
        Chart.compile!(%{
          id: "x",
          initial: "a",
          limits: %{macrostep: 40},
          states: [%{id: "a", transitions: transitions}]
        })

      if Map.get(hd(transitions), :event) == "spin" do
        {:ok, start} = Chart.init(defn)

        assert {:error, %Error{code: :limit_exceeded}} =
                 Chart.step(defn, start.instance, event("spin"))
      else
        assert {:error, %Error{code: :limit_exceeded}} = Chart.init(defn)
      end
    end
  end

  test "action, internal event, effect and work budgets are hard" do
    inputs = [
      {%{action_calls: 1}, [%{effect: "a"}, %{effect: "b"}]},
      {%{internal_events: 1}, [%{raise: "a"}, %{raise: "b"}]},
      {%{macrostep: 3}, []}
    ]

    for {limits, actions} <- inputs do
      defn =
        Chart.compile!(%{
          id: "x",
          initial: "a",
          limits: limits,
          states: [%{id: "a", transitions: [%{event: "go", actions: actions}]}]
        })

      {:ok, start} = Chart.init(defn)

      assert {:error, %Error{code: :limit_exceeded}} =
               Chart.step(defn, start.instance, event("go"))
    end
  end

  test "bad callback results, exceptions, exits and requests are typed failures" do
    defn =
      Chart.compile!(%{
        id: "x",
        initial: "a",
        states: [%{id: "a", transitions: [%{event: "go", guard: "guard", actions: ["reduce"]}]}]
      })

    callbacks = [
      fn _, _, _ -> :bad end,
      fn _, _, _ -> {:error, :bad} end,
      fn _, _, _ -> raise "bad" end,
      fn _, _, _ -> exit(:bad) end,
      fn _, _, _ -> throw(:bad) end,
      fn _, _, _ -> {:ok, []} end,
      fn _, _, _ -> {:ok, %{pid: self()}} end,
      fn data, _, _ -> {:ok, data, [:bad]} end,
      fn data, _, _ -> {:ok, data, [event("external")]} end,
      fn data, _, _ -> {:ok, data, [%Effect{id: "", data: %{}}]} end,
      fn data, _, _ -> {:ok, data, [1 | :bad]} end,
      fn data, _, _ -> {:ok, data, List.duplicate(%Effect{id: "x", data: %{}}, 513)} end
    ]

    for callback <- callbacks do
      reg = %Registry{
        guards: %{"guard" => fn _, _ -> true end},
        reducers: %{"reduce" => callback}
      }

      {:ok, start} = Chart.init(defn, %{}, reg)
      assert {:error, %Error{}} = Chart.step(defn, start.instance, event("go"), reg)
    end

    for guard <- [fn _, _ -> :yes end, fn _, _ -> raise "bad" end] do
      reg = %Registry{
        guards: %{"guard" => guard},
        reducers: %{"reduce" => fn data, _, _ -> {:ok, data} end}
      }

      {:ok, start} = Chart.init(defn, %{}, reg)
      assert {:error, %Error{}} = Chart.step(defn, start.instance, event("go"), reg)
    end
  end

  test "configuration, event and portable data validation rejects malformed input" do
    defn = Chart.compile!(flat())
    {:ok, start} = Chart.init(defn)

    for config <- [
          nil,
          %Configuration{fingerprint: "other", active: ["off"], status: :running},
          %{start.instance.configuration | active: []},
          %{start.instance.configuration | active: ["missing"]},
          %{start.instance.configuration | status: :done},
          %{start.instance.configuration | active: ["off", "on"]},
          %{start.instance.configuration | active: ["off" | :bad]}
        ] do
      assert {:error, %Error{}} =
               Chart.step(defn, %{start.instance | configuration: config}, event("toggle"))
    end

    assert {:error, %Error{}} = Validator.instance(defn, %{})
    assert {:error, %Error{}} = Validator.instance(defn, %{start.instance | data: []})

    assert {:error, %Error{}} =
             Chart.step(defn, start.instance, %Event{type: "toggle", kind: :internal})

    assert {:error, %Error{}} = Chart.step(defn, start.instance, :bad)

    for type <- ["", :name, String.duplicate("x", 4097), <<255>>, "done.state.x", "$init"] do
      assert {:error, %Error{}} = Event.new(type)
    end

    assert {:error, %Error{}} = Event.new("go", %{pid: self()})
    assert {:error, %Error{}} = Event.validate(%{}, Limits.defaults())

    for data <- [
          self(),
          make_ref(),
          fn -> :ok end,
          [1 | :bad],
          %URI{},
          %{1 => 1},
          <<1::1>>,
          String.duplicate("x", 1_048_577),
          <<255>>
        ] do
      assert {:error, %Error{}} = Data.validate(data, Limits.defaults())
    end

    assert :ok = Data.validate(%{"scalar" => [true, nil, 1, 1.5, "text"]}, Limits.defaults())
    assert {:error, %Error{}} = Data.validate([1, 2], %{Limits.defaults() | data_nodes: 1})
    assert {:error, %Error{}} = Data.validate(100, %{Limits.defaults() | data_bytes: 1})
  end

  test "nil events and malformed trusted definitions return typed errors" do
    defn = Chart.compile!(flat())
    {:ok, start} = Chart.init(defn)
    assert {:error, %Error{code: :invalid_event}} = Chart.step(defn, start.instance, nil)

    bad = %{
      defn
      | states: Map.new(1..513, fn i -> {Integer.to_string(i), defn.states["off"]} end)
    }

    assert {:error, %Error{code: :invalid_definition}} = Chart.init(bad)

    bad = %{
      defn
      | states: %{
          "off" => %{
            defn.states["off"]
            | transitions: List.duplicate(hd(defn.states["off"].transitions), 4097)
          }
        }
    }

    assert {:error, %Error{code: :invalid_definition}} = Chart.init(bad)
  end

  test "data map size, nesting, signed integer and effect batch bounds are enforced" do
    limits = Limits.defaults()

    assert {:error, %Error{}} =
             Data.validate(Map.new(1..100, &{Integer.to_string(&1), 0}), %{
               limits
               | data_nodes: 10
             })

    deep = Enum.reduce(1..65, "leaf", fn _, value -> [value] end)
    assert {:error, %Error{}} = Data.validate(deep, limits)
    assert {:error, %Error{}} = Data.validate(9_223_372_036_854_775_808, limits)
    assert {:error, %Error{}} = Data.validate(:long_atom, %{limits | data_bytes: 1})

    defn =
      Chart.compile!(%{
        id: "x",
        initial: "a",
        states: [%{id: "a", transitions: [%{event: "go", actions: ["many"]}]}]
      })

    reg = %Registry{
      reducers: %{
        "many" => fn data, _, _ ->
          {:ok, data, List.duplicate(%Effect{id: "x", data: %{}}, 513)}
        end
      }
    }

    {:ok, start} = Chart.init(defn, %{}, reg)

    assert {:error, %Error{code: :limit_exceeded, details: %{limit: :effects}}} =
             Chart.step(defn, start.instance, event("go"), reg)
  end

  test "eventless guards observe prior reducer changes before the next internal event" do
    defn =
      Chart.compile!(%{
        id: "counter",
        initial: "a",
        states: [
          %{
            id: "a",
            transitions: [%{target: "done", guard: "ready"}, %{event: "inc", actions: ["inc"]}]
          },
          %{id: "done", type: :final}
        ]
      })

    reg = %Registry{
      guards: %{"ready" => fn data, _ -> data["count"] >= 2 end},
      reducers: %{
        "inc" => fn data, _, _ ->
          data = Map.update!(data, "count", &(&1 + 1))
          requests = if data["count"] < 2, do: [%Event{type: "inc", kind: :internal}], else: []
          {:ok, data, requests}
        end
      }
    }

    {:ok, start} = Chart.init(defn, %{"count" => 0}, reg)
    {:ok, result} = Chart.step(defn, start.instance, event("inc"), reg)
    assert result.instance.configuration.status == :done
    assert result.instance.data["count"] == 2

    assert Enum.filter(result.trace, &(&1.op == :guard)) == [
             %{op: :guard, id: "ready", enabled: false},
             %{op: :guard, id: "ready", enabled: true}
           ]
  end
end
