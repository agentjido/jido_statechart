defmodule JidoStatechartTest.SCXMLPropertyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties
  alias Jido.Statechart.{Compiler, Error, SCXML}

  property "arbitrary bytes and terms return typed results" do
    check all(input <- one_of([binary(max_length: 4096), term()]), max_runs: 200) do
      assert {:error, %Error{}} = SCXML.compile(input)
    end
  end

  property "bounded flat XML charts agree with normalized data" do
    check all(size <- integer(1..12), max_runs: 75) do
      ids = Enum.map(0..(size - 1), &"state-#{&1}")

      states =
        Enum.with_index(ids)
        |> Enum.map(fn {id, i} ->
          %{
            id: id,
            transitions: [
              %{event: "next", event_mode: :scxml, target: Enum.at(ids, rem(i + 1, size))}
            ]
          }
        end)

      body =
        Enum.map_join(states, fn state ->
          target = hd(state.transitions).target
          ~s(<s:state id="#{state.id}"><s:transition target="#{target}" event="next"/></s:state>)
        end)

      xml =
        ~s(<s:scxml xmlns:s="http://www.w3.org/2005/07/scxml" version="1.0" name="cycle">#{body}</s:scxml>)

      assert SCXML.compile!(xml) ==
               Compiler.compile!(%{id: "cycle", initial: hd(ids), states: states})
    end
  end

  test "the core loads without the optional parser and XML returns a useful error" do
    package_ebin = Mix.Project.compile_path()

    script = """
    false = Code.ensure_loaded?(Saxy)
    xml = "<scxml xmlns=\\"http://www.w3.org/2005/07/scxml\\" version=\\"1.0\\"><state id=\\"a\\"/></scxml>"
    {:error, %{code: :parser_unavailable}} = Jido.Statechart.SCXML.compile(xml)
    {:ok, _} = Jido.Statechart.compile(%{id: "core", initial: "a", states: [%{id: "a"}]})
    IO.puts("optional parser check passed")
    """

    assert {output, 0} =
             System.cmd("elixir", ["-pa", package_ebin, "-e", script], stderr_to_stdout: true)

    assert output =~ "optional parser check passed"
  end
end
