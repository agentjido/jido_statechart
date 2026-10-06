defmodule JidoStatechartTest.SCXMLTest do
  use ExUnit.Case, async: true
  alias Jido.Statechart, as: Chart
  alias Jido.Statechart.{Checkpoint, Compiler, Error, Registry, SCXML, Validator}
  import JidoStatechartTest.Fixtures

  @namespace "http://www.w3.org/2005/07/scxml"
  @job File.read!(Path.join(__DIR__, "fixtures/job.scxml"))

  defp xml(body, attrs \\ ""),
    do:
      ~s(<scxml xmlns="#{@namespace}" xmlns:j="urn:jido:statechart:1" version="1.0" #{attrs}>#{body}</scxml>)

  defp matching_data(data) do
    Map.update!(data, :states, fn states ->
      Enum.map(states, fn state ->
        Map.update(state, :transitions, [], fn transitions ->
          Enum.map(transitions, &Map.put(&1, :event_mode, :scxml))
        end)
      end)
    end)
  end

  test "fixed XML fixture produces the same definition and macrostep as data" do
    definition = SCXML.compile!(@job)
    data_definition = Compiler.compile!(matching_data(nested()))
    assert definition == data_definition
    assert :ok = Validator.definition(definition)
    assert definition == Compiler.compile!(Compiler.to_data(definition))
    registry = logger_registry()
    assert {:ok, start} = Chart.init(definition, %{}, registry)
    assert {:ok, ^start} = Chart.init(data_definition, %{}, registry)
    assert {:ok, result} = Chart.step(definition, start.instance, event("go"), registry)
    assert {:ok, ^result} = Chart.step(data_definition, start.instance, event("go"), registry)
    assert result.instance.configuration.active == ["done"]
    assert result.instance.configuration.status == :done
    assert [%{id: "notify"}] = result.effects
    assert {:ok, checkpoint} = Checkpoint.dump(definition, result.instance)
    assert {:ok, restored} = Checkpoint.load(definition, checkpoint)
    assert restored == result.instance
  end

  test "prefixes, attribute order, comments and whitespace do not change behavior" do
    simple =
      xml(
        ~s(<state id="a"><transition event="go" target="b"/></state><final id="b"/>),
        ~s(name="sample")
      )

    prefixed =
      ~s(<?xml version="1.0"?><s:scxml version="1.0" name="sample" xmlns:s="#{@namespace}">
      <!-- Safe text: &unused; <!DOCTYPE harmless> -->
      <s:state id="a"><s:transition target="b" event="go"/></s:state><s:final id="b"/>
    </s:scxml>)

    assert SCXML.compile!(simple) == SCXML.compile!(prefixed)
    assert SCXML.compile!(simple, id: "override", version: "2").id == "override"
    assert SCXML.compile!(simple, version: "2").version == "2"
  end

  test "initial selection uses document order and supports a target-only initial element" do
    input =
      xml(
        ~s(<state id="parent"><initial><transition target="z"/></initial><state id="a"/><state id="z"/></state>)
      )

    definition = SCXML.compile!(input, limits: %{transitions: 1})
    assert {:ok, start} = Chart.init(definition)
    assert start.instance.configuration.active == ["parent", "z"]
    assert SCXML.compile!(xml(~s(<state id="z"/><state id="a"/>))).initial == "z"
  end

  test "event descriptors use dot prefixes and alternatives with one guard call" do
    for {descriptor, type, matches?} <- [
          {"order", "order", true},
          {"order", "order.created", true},
          {"order.", "order.created", true},
          {"order.*", "order", true},
          {"order.*", "ordering", false},
          {"order", "Order", false},
          {"order other", "other.created", true},
          {"*", "anything", true},
          {"order order.created *", "order.created", true}
        ] do
      definition =
        SCXML.compile!(
          xml(
            ~s(<state id="a"><transition event="#{descriptor}" cond="allowed" target="b"/></state><final id="b"/>)
          )
        )

      registry = %Registry{
        guards: %{
          "allowed" => fn _, _ ->
            send(self(), :guard)
            true
          end
        }
      }

      {:ok, start} = Chart.init(definition, %{}, registry)
      result = Chart.step(definition, start.instance, event(type), registry)

      if matches? do
        assert {:ok, result} = result
        assert result.instance.configuration.active == ["b"]
        assert result.stats.guard_calls == 1
        assert_received :guard
        refute_received :guard
      else
        assert {:error, %Error{code: :unhandled_event}} = result
        refute_received :guard
      end
    end
  end

  test "wildcard transitions do not match eventless stabilization" do
    definition =
      SCXML.compile!(
        xml(~s(<state id="a"><transition event="*" target="b"/></state><final id="b"/>))
      )

    assert {:ok, start} = Chart.init(definition)
    assert start.instance.configuration.active == ["a"]
    assert {:ok, result} = Chart.step(definition, start.instance, event("go"))
    assert result.instance.configuration.active == ["b"]
  end

  test "exact event mode and its existing checkpoint fingerprint are unchanged" do
    definition = Compiler.compile!(flat())

    assert definition.fingerprint ==
             "febad667187e1539f213b59e168ace31d664837d0d8678001627eeaa11a9c11f"

    {:ok, start} = Chart.init(definition)

    assert {:error, %Error{code: :unhandled_event}} =
             Chart.step(definition, start.instance, event("toggle.more"))

    xml_definition =
      SCXML.compile!(
        xml(
          ~s(<state id="off"><transition event="toggle" target="on"/></state><state id="on"><transition event="toggle" target="off"/></state>)
        ),
        id: "switch"
      )

    refute xml_definition.fingerprint == definition.fingerprint
  end

  test "internal compound transitions retain their source; other internal types act external" do
    input =
      xml(
        ~s(<state id="p"><onentry><j:action id="log"/></onentry><transition type="internal" event="reset" target="a"/><state id="a"><transition type="internal" event="again" target="a"/></state></state>)
      )

    definition = SCXML.compile!(input)
    assert hd(definition.states["p"].transitions).kind == :internal
    assert hd(definition.states["a"].transitions).kind == :external
    {:ok, start} = Chart.init(definition, %{}, logger_registry())

    assert {:ok, reset} =
             Chart.step(definition, start.instance, event("reset"), logger_registry())

    assert reset.instance.data == start.instance.data
  end

  test "trusted action payloads decode as JSON objects and execute in document order" do
    input =
      xml(
        ~s(<state id="a"><onentry><j:action id="set" params='{"value":"A &amp; B &#x43;"}'/></onentry><onentry><raise event="next" j:data='{"ok":true}'/></onentry><transition event="next" cond="allowed" target="b"><j:effect id="notify" data='{"value":42}'/></transition></state><final id="b"/>)
      )

    registry = %Registry{
      reducers: %{"set" => fn _, _, params -> {:ok, params} end},
      guards: %{"allowed" => fn _, event -> event.data["ok"] == true end}
    }

    definition = SCXML.compile!(input)
    assert {:ok, result} = Chart.init(definition, %{}, registry)
    assert result.instance.data == %{"value" => "A & B C"}
    assert [%{id: "notify", data: %{"value" => 42}}] = result.effects
    assert result.instance.configuration.status == :done
  end

  test "XML edge rejects DTDs, entities, resource loading and executable languages" do
    unsafe = [
      ~s(<!DOCTYPE scxml SYSTEM "file:///etc/passwd">) <> xml(~s(<state id="a"/>)),
      ~s(<!DOCTYPE scxml SYSTEM "https://example.invalid/x.dtd">) <> xml(~s(<state id="a"/>)),
      ~s(<!DOCTYPE scxml [<!ENTITY x "boom"><!ENTITY y "&x;&x;">]>) <> xml(~s(<state id="a"/>)),
      xml(~s(<state id="&unknown;"/>)),
      xml(~s(<state id="a"><![CDATA[ ]]></state>)),
      xml(~s(<state id="a"><?run do-something?></state>)),
      ~s(<?xml-stylesheet href="file:///tmp/x"?>) <> xml(~s(<state id="a"/>)),
      xml(~s(<state id="a"><script>evil</script></state>)),
      xml(
        ~s(<state id="a"><onentry><send event="x" target="https://example.invalid"/></onentry></state>)
      ),
      xml(~s(<state id="a"><invoke src="file:///tmp/x"/></state>)),
      xml(
        ~s(<state id="a"><xi:include xmlns:xi="http://www.w3.org/2001/XInclude" href="file:///tmp/x"/></state>)
      ),
      xml(~s(<state id="a"><transition cond="data.x > 0" target="b"/></state><state id="b"/>)),
      xml(~s(<state id="a"/>), ~s(datamodel="ecmascript"))
    ]

    for input <- unsafe, do: assert({:error, %Error{}} = SCXML.compile(input))
  end

  test "unsupported grammar and ambiguous attributes fail explicitly" do
    bodies = [
      ~s(<parallel id="p"/>),
      ~s(<history id="h"/>),
      ~s(<state id="a"><datamodel/></state>),
      ~s(<state id="a" id="b"/>),
      ~s(<state id="a" src="x"/>),
      ~s(<state id="a"><transition event="x" target="a b"/></state>),
      ~s(<state id="a"><transition/></state>),
      ~s(<state id="a"><transition event="x" type="unknown"/></state>),
      ~s(<final id="a"><transition event="x"/></final>),
      ~s(<state id="p" initial="a"><initial><transition target="a"/></initial><state id="a"/></state>),
      ~s(<state id="p"><initial><transition target="a"/><transition target="a"/></initial><state id="a"/></state>),
      ~s(<state id="p"><initial><transition target="a"><raise event="x"/></transition></initial><state id="a"/></state>),
      ~s(<state id="a"><initial><transition target="a"/></initial></state>),
      ~s(<state id="a"><onentry><raise/></onentry></state>),
      ~s(<state id="a"><onentry><raise event="x y"/></onentry></state>),
      ~s(<state id="a"><onentry><raise event="done.state.a"/></onentry></state>),
      ~s(<state id="a"><onentry><j:action id="x" params="[]"/></onentry></state>),
      ~s(<state id="a"><onentry><j:effect id="x" data="invalid"/></onentry></state>),
      ~s(<state id="a"><onentry><j:effect id="x"><raise event="x"/></j:effect></onentry></state>),
      ~s(<onentry/><state id="a"/>),
      ~s(<initial><transition target="a"/></initial><state id="a"/>),
      ~s(<state id="a">text</state>),
      ~s(<state id="a"/><state id="a"/>),
      ~s(<state/>),
      ""
    ]

    for body <- bodies,
        do: assert({:error, %Error{}} = SCXML.compile(xml(body)))

    assert {:error, %Error{}} = SCXML.compile(xml(~s(<state id="a"/>), ~s(binding="late")))
    assert_raise Error, fn -> SCXML.compile!("<bad/>") end
  end

  test "namespaces are checked on elements and expanded attributes" do
    invalid = [
      ~s(<scxml version="1.0"><state id="a"/></scxml>),
      ~s(<scxml xmlns="wrong" version="1.0"><state id="a"/></scxml>),
      xml(~s(<state xmlns="wrong" id="a"/>)),
      xml(~s(<unknown:state id="a"/>)),
      xml(~s(<state id="a"><onentry><action id="x"/></onentry></state>)),
      xml(~s(<state id="a"><onentry><j:action xmlns:j="wrong" id="x"/></onentry></state>)),
      xml(~s(<state xmlns:xml="wrong" id="a"/>)),
      xml(~s(<state xmlns:xmlns="wrong" id="a"/>)),
      xml(~s(<state xmlns:x="http://www.w3.org/XML/1998/namespace" id="a"/>)),
      xml(
        ~s(<state xmlns:x="urn:jido:statechart:1" id="a"><onentry><raise event="x" j:data="{}" x:data="{}"/></onentry></state>)
      ),
      xml(~s(<state xmlns:x="wrong" id="a" x:id="b"/>))
    ]

    for input <- invalid, do: assert({:error, %Error{}} = SCXML.compile(input))
  end

  test "XML syntax, character references and encodings are checked" do
    for input <- [
          nil,
          42,
          [],
          <<255>>,
          <<0>>,
          "<",
          "<scxml>",
          xml(~s(<state id="a"></final>)),
          xml(~s(<state id="&#0;"/>)),
          xml(~s(<state id="&#xD800;"/>)),
          xml(~s(<state id="&#999999999999999999999999;"/>)),
          xml(~s(<state id="&#xZZ;"/>)),
          xml(~s(<state id="a"/><!-- invalid -- comment -->)),
          ~s(<?xml version="1.1"?>) <> xml(~s(<state id="a"/>)),
          ~s(<?xml version="1.0" encoding="ISO-8859-1"?>) <> xml(~s(<state id="a"/>)),
          xml(~s(<state id="a"/>)) <> xml(~s(<state id="b"/>))
        ] do
      assert {:error, %Error{}} = SCXML.compile(input)
    end
  end

  test "large unfinished references and comments fail within the input bound" do
    for input <- [String.duplicate("&#", 100_000), String.duplicate("<!--", 100_000)] do
      task = Task.async(fn -> SCXML.compile(input) end)
      assert {:error, %Error{code: :invalid_xml}} = Task.await(task, 5000)
    end

    assert {:ok, _} = SCXML.compile(<<239, 187, 191>> <> xml(~s(<state id="a"/>)))
  end

  test "all XML limits can only decrease and stop parsing" do
    input = xml(~s(<state id="a"><transition event="next"/></state>))

    for limits <- [
          %{bytes: 1},
          %{depth: 1},
          %{elements: 1},
          %{attributes: 1},
          %{attribute_bytes: 1},
          %{name_bytes: 1}
        ] do
      assert {:error, %Error{code: :limit_exceeded}} = SCXML.compile(input, xml_limits: limits)
    end

    assert {:error, %Error{code: :limit_exceeded}} =
             SCXML.compile(xml("  <state id=\"a\"/>"), xml_limits: %{text_bytes: 1})

    for limits <- [
          %{bytes: 1_048_577},
          %{depth: 0},
          %{unknown: 1},
          %{bytes: "1"},
          %{"bytes" => 2, bytes: 1},
          nil,
          %URI{}
        ] do
      assert {:error, %Error{code: :invalid_limit}} = SCXML.compile(input, xml_limits: limits)
    end

    assert {:ok, _} = SCXML.compile(input, xml_limits: %{"depth" => 5})

    for opts <- [nil, [unknown: 1], [id: "one", id: "two"]],
        do: assert({:error, %Error{}} = SCXML.compile(input, opts))

    assert {:error, %Error{code: :limit_exceeded}} =
             SCXML.compile(xml(~s(<state id="a"/><state id="b"/>)), limits: %{states: 1})

    assert {:error, %Error{}} = SCXML.compile(input, limits: %{depth: 0})
  end

  test "descriptor counts and matching work have fixed limits" do
    for descriptor <- ["", ".", "a..b", "a*", "a.*.*", String.duplicate("a ", 33)] do
      assert {:error, %Error{}} =
               SCXML.compile(xml(~s(<state id="a"><transition event="#{descriptor}"/></state>)))
    end

    descriptors = Enum.map_join(1..32, " ", &"event#{&1}")

    definition =
      SCXML.compile!(xml(~s(<state id="a"><transition event="#{descriptors}"/></state>)),
        limits: %{macrostep: 20}
      )

    {:ok, start} = Chart.init(definition)

    assert {:error, %Error{code: :limit_exceeded}} =
             Chart.step(definition, start.instance, event("unknown"))

    transition = hd(definition.states["a"].transitions)
    bad = put_in(definition.states["a"].transitions, [%{transition | event_descriptors: [:any]}])
    assert {:error, %Error{code: :definition_mismatch}} = Validator.definition(bad)
  end

  test "external XML names and JSON keys never become atoms" do
    for index <- 1..100 do
      id = "xml_external_#{index}"
      assert_raise ArgumentError, fn -> String.to_existing_atom(id) end

      input =
        xml(
          ~s(<state id="#{id}"><transition event="#{id}" cond="#{id}"><j:action id="#{id}" params='{"#{id}":1}'/></transition></state>)
        )

      assert {:ok, _} = SCXML.compile(input)
      assert_raise ArgumentError, fn -> String.to_existing_atom(id) end
      assert {:error, %Error{}} = SCXML.compile(xml("<#{id}/><state id=\"a\"/>"))
      assert_raise ArgumentError, fn -> String.to_existing_atom(id) end
    end
  end
end
