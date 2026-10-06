defmodule JidoStatechartTest.CompilerTest do
  use ExUnit.Case, async: true
  alias Jido.Statechart.{Compiler, Error, Limits, Registry, Validator}
  import JidoStatechartTest.Fixtures

  test "string data and Elixir input share normalized behavior" do
    atom_data = flat()
    string_data = atom_data |> Jason.encode!() |> Jason.decode!()
    assert {:ok, definition} = Compiler.compile(atom_data)
    assert {:ok, ^definition} = Compiler.compile(string_data)
    assert :ok = Validator.definition(definition)
    assert Compiler.compile!(Compiler.to_data(definition)) == definition
  end

  test "DSL and data API share the normalized definition" do
    data = %{
      id: "nested",
      initial: "parent",
      states: [
        %{
          id: "parent",
          type: :compound,
          initial: "child",
          transitions: [%{event: "finish", target: "end"}]
        },
        %{id: "child", parent: "parent", transitions: [%{event: "tick"}]},
        %{id: "end", type: :final}
      ]
    }

    assert Compiler.compile!(data) == JidoStatechartTest.NestedDSL.chart_definition()
  end

  test "fingerprints include version, structure, actions, priorities and limits" do
    base = Compiler.compile!(flat())
    assert byte_size(base.fingerprint) == 64

    for input <- [
          flat(%{version: "2"}),
          flat(%{limits: %{macrostep: 50}}),
          %{flat() | states: [%{id: "off", transitions: [%{event: "toggle", priority: 1}]}]}
        ] do
      refute Compiler.compile!(input).fingerprint == base.fingerprint
    end

    assert {:error, %Error{code: :definition_mismatch}} =
             Validator.definition(%{base | fingerprint: "other"})
  end

  test "rejects unknown fields and duplicate aliases at each authoring boundary" do
    bad = [
      Map.put(flat(), :script, "evil"),
      Map.put(flat(), "id", "duplicate"),
      %{id: "x", initial: "a", states: [%{id: "a", history: true}]},
      %{id: "x", initial: "a", states: [%{id: "a", transitions: [%{invoke: "x"}]}]},
      %{id: "x", initial: "a", states: [%{id: "a", entry: [%{id: "x", effect: "y"}]}]},
      %{id: "x", initial: "a", states: [%{id: "a", entry: [%{id: "x", data: %{}}]}]}
    ]

    for input <- bad, do: assert({:error, %Error{}} = Compiler.compile(input))
  end

  test "rejects malformed states, references, hierarchy and initial states" do
    cases = [
      {%{id: "x", initial: "a", states: []}, :invalid_definition},
      {%{id: "x", initial: "a", states: [%{id: "a"}, %{id: "a"}]}, :duplicate_state},
      {%{id: "x", initial: "missing", states: [%{id: "a"}]}, :invalid_initial},
      {%{id: "x", initial: "a", states: [%{id: "a", parent: "missing"}]}, :invalid_initial},
      {%{id: "x", initial: "root", states: [%{id: "root"}, %{id: "a", parent: "missing"}]},
       :unknown_parent},
      {%{
         id: "x",
         initial: "root",
         states: [%{id: "root"}, %{id: "a", parent: "b"}, %{id: "b", parent: "a"}]
       }, :state_cycle},
      {%{id: "x", initial: "a", states: [%{id: "a", type: :compound}]}, :invalid_initial},
      {%{id: "x", initial: "a", states: [%{id: "a", type: :compound, initial: "b"}, %{id: "b"}]},
       :invalid_initial},
      {%{id: "x", initial: "a", states: [%{id: "a"}, %{id: "b", parent: "a"}]},
       :invalid_definition},
      {%{id: "x", initial: "a", states: [%{id: "a", initial: "a"}]}, :invalid_definition},
      {%{id: "x", initial: "a", states: [%{id: "a", type: :final, transitions: [%{event: "x"}]}]},
       :invalid_definition},
      {%{id: "x", initial: "a", states: [%{id: "a", transitions: [%{target: "missing"}]}]},
       :unknown_target},
      {%{
         id: "x",
         initial: "a",
         states: [%{id: "a", transitions: [%{target: "a", kind: :internal}]}]
       }, :invalid_definition},
      {%{id: "x", initial: "a", states: [%{id: "a", transitions: [%{priority: "high"}]}]},
       :invalid_definition}
    ]

    for {input, code} <- cases,
        do: assert({:error, %Error{code: ^code}} = Compiler.compile(input))
  end

  test "rejects unsupported features and unsafe values" do
    for type <- [:parallel, :history, "parallel", "history"] do
      assert {:error, %Error{code: :unsupported_feature}} =
               Compiler.compile(%{id: "x", initial: "a", states: [%{id: "a", type: type}]})
    end

    for value <- [
          nil,
          42,
          [],
          %URI{},
          %{id: :unsafe, initial: "a", states: [%{id: "a"}]},
          flat(%{states: [%{id: "off", entry: [fn -> :ok end]}]}),
          flat(%{states: [%{id: "off"} | :tail]})
        ] do
      assert {:error, %Error{}} = Compiler.compile(value)
    end

    assert_raise Error, fn -> Compiler.compile!(%{}) end
    assert {:error, %Error{}} = Validator.definition(%{Compiler.compile!(flat()) | states: nil})
    assert {:error, %Error{}} = Validator.definition(%{})
  end

  test "hard limits cannot be raised and lists, depth, IDs and size are bounded" do
    assert {:ok, limits} = Limits.new(%{"macrostep" => 20})
    assert limits.macrostep == 20

    for input <- [%{macrostep: 1025}, %{depth: 0}, %{unknown: 2}, %{macrostep: "1"}, []] do
      assert {:error, %Error{code: :invalid_limit}} = Limits.new(input)
    end

    for input <- [
          flat(%{limits: %{states: 1}}),
          flat(%{limits: %{definition_bytes: 1}}),
          flat(%{id: String.duplicate("x", 4097)}),
          flat(%{states: [%{id: "off", entry: ["a", "b"]}], limits: %{actions_per_list: 1}}),
          flat(%{
            states: [%{id: "off", transitions: [%{event: "a"}, %{event: "b"}]}],
            limits: %{transitions: 1}
          }),
          %{
            id: "n",
            initial: "a",
            limits: %{depth: 1},
            states: [%{id: "a", type: :compound, initial: "b"}, %{id: "b", parent: "a"}]
          },
          %{
            id: "n",
            initial: "a",
            limits: %{active_states: 1},
            states: [%{id: "a", type: :compound, initial: "b"}, %{id: "b", parent: "a"}]
          }
        ] do
      assert {:error, %Error{}} = Compiler.compile(input)
    end
  end

  test "normalizes reducer, raise and effect actions and rejects invalid requests" do
    defn =
      Compiler.compile!(%{
        id: "a",
        initial: "a",
        states: [
          %{
            id: "a",
            entry: ["log", %{id: "log", params: %{x: 1}}, %{raise: "next"}, %{effect: "send"}]
          }
        ]
      })

    assert length(defn.states["a"].entry) == 4

    for action <- [
          %{},
          %{raise: "done.state.a"},
          %{raise: "$init"},
          %{effect: "send", data: []},
          %{id: "x", params: []},
          "",
          0
        ] do
      assert {:error, %Error{}} =
               Compiler.compile(%{id: "a", initial: "a", states: [%{id: "a", entry: [action]}]})
    end
  end

  test "trusted registry validates callbacks and checks all references" do
    assert {:ok, registry} =
             Registry.new(%{"yes" => fn _, _ -> true end}, %{
               "log" => fn data, _, _ -> {:ok, data} end
             })

    defn =
      Compiler.compile!(%{
        id: "a",
        initial: "a",
        states: [%{id: "a", entry: ["log"], transitions: [%{event: "x", guard: "yes"}]}]
      })

    assert :ok = Registry.validate(defn, registry)
    assert {:error, %Error{code: :unknown_behavior}} = Registry.validate(defn, %Registry{})

    for {guards, reducers} <- [
          {[], %{}},
          {%{yes: fn _, _ -> true end}, %{}},
          {%{"yes" => fn -> true end}, %{}},
          {%{}, %{"log" => :module}}
        ] do
      assert {:error, %Error{code: :invalid_registry}} = Registry.new(guards, reducers)
    end

    assert {:error, %Error{}} = Registry.validate(defn, nil)
  end

  test "generated completion identities must fit the configured string bound" do
    assert {:error, %Error{code: :limit_exceeded}} =
             Compiler.compile(%{
               id: "x",
               initial: "p",
               limits: %{expression_bytes: 8},
               states: [
                 %{id: "p", type: :compound, initial: "f"},
                 %{id: "f", parent: "p", type: :final}
               ]
             })
  end
end
