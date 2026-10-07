defmodule Jido.Statechart.ProfileConformance.Assertion355Agent do
  use Jido.Agent,
    name: "w3c_assertion_355_agent",
    extensions: [Jido.Statechart.Agent.Extension]

  agent do
    schema(Zoi.object(%{label: Zoi.string() |> Zoi.default("w3c")}))
  end

  routes do
    route("go", statechart: Jido.Statechart.Conformance.Assertion355Chart)
  end
end

defmodule Jido.Statechart.ProfileConformance.Assertion403AAgent do
  use Jido.Agent,
    name: "w3c_assertion_403a_agent",
    extensions: [Jido.Statechart.Agent.Extension]

  agent do
    schema(Zoi.object(%{label: Zoi.string() |> Zoi.default("w3c")}))
  end

  routes do
    route("go", statechart: Jido.Statechart.Conformance.Assertion403AChart)
  end
end

defmodule Jido.Statechart.ProfileConformance.Assertion403BAgent do
  use Jido.Agent,
    name: "w3c_assertion_403b_agent",
    extensions: [Jido.Statechart.Agent.Extension]

  agent do
    schema(Zoi.object(%{label: Zoi.string() |> Zoi.default("w3c")}))
  end

  routes do
    route("go", statechart: Jido.Statechart.Conformance.Assertion403BChart)
  end
end

defmodule Jido.Statechart.ProfileConformance.Assertion403CAgent do
  use Jido.Agent,
    name: "w3c_assertion_403c_agent",
    extensions: [Jido.Statechart.Agent.Extension]

  agent do
    schema(Zoi.object(%{label: Zoi.string() |> Zoi.default("w3c")}))
  end

  routes do
    route("go", statechart: Jido.Statechart.Conformance.Assertion403CChart)
  end
end

defmodule Jido.Statechart.ProfileConformance.Assertion436Agent do
  use Jido.Agent,
    name: "w3c_assertion_436_agent",
    extensions: [Jido.Statechart.Agent.Extension]

  agent do
    schema(Zoi.object(%{label: Zoi.string() |> Zoi.default("w3c")}))
  end

  routes do
    route("go", statechart: Jido.Statechart.Conformance.Assertion436Chart)
  end
end

defmodule Jido.Statechart.ProfileConformanceTest do
  use ExUnit.Case, async: false

  alias Jido.Statechart.{Conformance, Profile}

  setup do
    name = String.to_atom("statechart_conformance_#{System.unique_integer([:positive])}")
    namespace = "statechart/conformance/#{System.unique_integer([:positive])}"
    start_supervised!({Jido, name: name, namespace: namespace})
    {:ok, jido: name}
  end

  for case_info <- Conformance.selected_cases() do
    @case_info case_info
    @case_id case_info["id"]

    test "W3C selected case #{@case_id} reproduces every declared behavior", %{jido: jido} do
      assert @case_info["execution_status"] == "run"
      assert @case_info["profile_status"] == "supported"
      assert @case_info["paths"] == ["pure", "direct", "live"]
      assert is_binary(@case_info["test_id"]) and @case_info["test_id"] != ""
      assert @case_info["behaviors"] != []

      expected = Conformance.expected(@case_id)
      assert Conformance.run_pure(@case_id) == expected
      assert Conformance.run_direct(@case_id) == expected
      assert Conformance.run_live(@case_id, jido) == expected
    end
  end

  test "the selected upstream fixture snapshot has fixed unchanged bytes" do
    for case_info <- Conformance.selected_cases() do
      fixture = case_info["fixture"]
      bytes = File.read!(Path.join(Conformance.fixture_root(), fixture["path"]))
      assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == fixture["sha256"]
    end
  end

  test "profile evidence: W3C 403 runs all selected transition-selection cases" do
    cases =
      Conformance.selected_cases()
      |> Enum.filter(&(&1["assertion_id"] == "403"))

    assert Enum.map(cases, & &1["id"]) == ["403a", "403b", "403c"]

    for case_info <- cases do
      assert Conformance.run_pure(case_info["id"]) == case_info["expected"]
      assert Conformance.run_direct(case_info["id"]) == case_info["expected"]
    end
  end

  test "the closed selected inventory accounts for each case exactly once" do
    manifest = Conformance.manifest()
    inventory = manifest["selected_assertion_inventory"]
    cases = manifest["cases"]
    feature_index = Map.new(Profile.features(), &{Atom.to_string(&1.id), &1})

    assert inventory["scope"] =~ "only"
    assert inventory["scope"] =~ "not a full W3C conformance claim"

    assert Enum.sort(inventory["assertion_ids"]) ==
             manifest["assertions"]
             |> Enum.filter(&(&1["execution_status"] == "run"))
             |> Enum.map(& &1["id"])
             |> Enum.sort()

    assert Enum.sort(inventory["case_ids"]) == Enum.sort(Enum.map(cases, & &1["id"]))
    assert Enum.uniq_by(cases, & &1["id"]) == cases

    for assertion <- manifest["assertions"] do
      assert assertion["execution_status"] in ~w(run skipped)
      assert assertion["profile_status"] in ~w(supported unsupported deviation not_applicable)

      if assertion["execution_status"] == "skipped" do
        assert is_binary(assertion["reason"]) and String.trim(assertion["reason"]) != ""
      else
        refute Map.has_key?(assertion, "reason")
      end
    end

    for assertion <- manifest["assertions"], feature_id <- assertion["profile_features"] do
      feature = Map.fetch!(feature_index, feature_id)
      assert assertion["id"] in feature.assertions
    end

    for assertion <- manifest["assertions"] do
      assert Enum.sort(assertion["case_ids"]) ==
               cases
               |> Enum.filter(&(&1["assertion_id"] == assertion["id"]))
               |> Enum.map(& &1["id"])
               |> Enum.sort()
    end

    for row <- cases do
      assert row["execution_status"] in ~w(run skipped)
      assert row["profile_status"] in ~w(supported unsupported deviation not_applicable)

      if row["execution_status"] == "skipped" do
        assert is_binary(row["reason"]) and String.trim(row["reason"]) != ""
      else
        refute Map.has_key?(row, "reason")
      end
    end
  end

  test "the official IR universe and profile-scoped inventory are complete and distinct" do
    manifest = Conformance.manifest()
    universe = manifest["official_ir_universe"]
    scope = manifest["profile_scoped_inventory"]
    assertions = manifest["assertions"]

    assert universe["assertion_count"] == 200

    assert universe["source_sha256"] ==
             "eff2152533b79792e350f4911f91ca3d50d977b74c45d43dbe9ab95d9e28eec1"

    assert universe["source_url"] == "https://www.w3.org/Voice/2013/scxml-irp/"
    assert universe["upstream_revision"] == "10 March 2015"
    assert universe["source_bytes"] == 156_603
    assert length(universe["assertion_ids"]) == 200
    assert Enum.uniq(universe["assertion_ids"]) == universe["assertion_ids"]
    assert scope["scope"] =~ "profile"
    assert scope["scope"] =~ "not a full W3C conformance claim"
    assert Enum.sort(scope["assertion_ids"]) == Enum.sort(Enum.map(assertions, & &1["id"]))
    assert length(assertions) == 200
    assert Enum.uniq_by(assertions, & &1["id"]) == assertions

    excluded_ids = Enum.map(scope["excluded_assertions"], & &1["id"])
    assert excluded_ids == []

    assert MapSet.disjoint?(MapSet.new(scope["assertion_ids"]), MapSet.new(excluded_ids))

    assert MapSet.new(universe["assertion_ids"]) ==
             MapSet.new(scope["assertion_ids"] ++ excluded_ids)

    referenced =
      Profile.features()
      |> Enum.flat_map(& &1.assertions)
      |> Enum.uniq()
      |> Enum.sort()

    assert referenced == Enum.sort(scope["assertion_ids"])

    for feature <- Profile.features() do
      expected_assertions =
        assertions
        |> Enum.filter(&(Atom.to_string(feature.id) in &1["profile_features"]))
        |> Enum.map(& &1["id"])

      assert feature.assertions == expected_assertions
    end

    assert Profile.features()
           |> Enum.filter(&is_nil(&1.w3c_section))
           |> Enum.map(& &1.id) == [:invoke_jido_element, :jido_action_extension]

    categories =
      assertions
      |> Enum.filter(&(&1["execution_status"] == "skipped"))
      |> Enum.map(& &1["category"])
      |> MapSet.new()

    assert MapSet.new(~w(manual multi_session timer invocation unsupported deferred))
           |> MapSet.subset?(categories)

    for assertion <- assertions do
      assert assertion["profile_features"] != []
      assert is_binary(assertion["abstract"]) and String.trim(assertion["abstract"]) != ""
      assert assertion["expected_behavior"] == assertion["abstract"]
      assert assertion["feature_relations"] != []
      assert assertion["source_url"] =~ "https://www.w3.org/Voice/2013/scxml-irp/"

      assert Enum.all?(
               assertion["test_urls"],
               &String.starts_with?(&1, "https://www.w3.org/Voice/2013/scxml-irp/")
             )

      for feature_id <- assertion["profile_features"] do
        feature = Enum.find(Profile.features(), &(Atom.to_string(&1.id) == feature_id))
        refute is_nil(feature)
        assert assertion["id"] in feature.assertions
      end

      for relation <- assertion["feature_relations"] do
        assert relation["relation"] in ~w(direct_required related)
        assert relation["feature"] in assertion["profile_features"]
      end

      direct_features =
        for %{"feature" => feature_id, "relation" => "direct_required"} <-
              assertion["feature_relations"],
            do: Enum.find(Profile.features(), &(Atom.to_string(&1.id) == feature_id))

      assert direct_features != []
      assert assertion["profile_status"] == expected_assertion_status(direct_features)

      if assertion["execution_status"] == "skipped" do
        assert assertion["category"] in ~w(manual multi_session timer invocation unsupported deferred)
        assert is_binary(assertion["reason"]) and String.trim(assertion["reason"]) != ""
      end
    end
  end

  test "official abstracts drive precise event, data-model, and invocation classifications" do
    assertions = Map.new(Conformance.manifest()["assertions"], &{&1["id"], &1})

    executable_features =
      ~w(onentry_element onexit_element raise_element if_element foreach_element assign_element log_element send_element cancel_element)

    assert direct(assertions["158"]) == ["executable_content_order"]
    assert related(assertions["158"]) == executable_features
    assert direct(assertions["159"]) == ["executable_content_abort_on_error"]
    assert related(assertions["159"]) == executable_features

    assert direct(assertions["396"]) == ["event_descriptor_matching"]
    assert direct(assertions["399"]) == ["event_descriptor_matching"]
    assert assertions["396"]["abstract"] =~ "event variable"
    assert assertions["399"]["abstract"] =~ "event descriptor"

    assert direct(assertions["451"]) == ["ecmascript_datamodel"]
    refute "in_predicate" in assertions["451"]["profile_features"]
    assert assertions["451"]["profile_status"] == "unsupported"

    expected = %{
      "215" => {"supported", ["invoke_scxml_element"], []},
      "216" => {"supported", ["invoke_scxml_element"], ["external_content_source"]},
      "220" => {"supported", ["invoke_scxml_element"], []},
      "223" => {"supported", ["invoke_idlocation_assignment"], ["invoke_scxml_element"]},
      "224" => {"deviation", ["invoke_generated_id_form"], ["invoke_scxml_element"]},
      "225" => {"supported", ["invoke_generated_id_uniqueness"], ["invoke_scxml_element"]},
      "226" => {"deviation", ["invoke_scxml_element", "post_commit_child_lifecycle"], []},
      "228" => {"supported", ["invoke_scxml_element"], []},
      "229" => {"supported", ["invoke_scxml_element", "invoke_autoforward"], []},
      "230" => {"supported", ["invoke_scxml_element", "invoke_autoforward"], []},
      "232" => {"supported", ["invoke_scxml_element"], []},
      "233" => {"supported", ["invoke_scxml_element", "finalize_element"], []},
      "234" => {"supported", ["invoke_scxml_element", "finalize_element"], []},
      "235" => {"supported", ["invoke_scxml_element"], []},
      "236" => {"supported", ["invoke_scxml_element"], []},
      "237" => {"deviation", ["invoke_scxml_element", "post_commit_child_lifecycle"], []},
      "239" =>
        {"unsupported", ["invoke_scxml_element", "external_content_source"], ["content_element"]},
      "240" =>
        {"unsupported", ["invoke_data_model_injection"],
         ["invoke_scxml_element", "param_element"]},
      "241" =>
        {"deviation", ["invoke_input_metadata"], ["invoke_scxml_element", "param_element"]},
      "242" =>
        {"unsupported", ["invoke_scxml_element", "external_content_source"], ["content_element"]},
      "243" =>
        {"unsupported", ["invoke_data_model_injection"],
         ["invoke_scxml_element", "param_element"]},
      "244" =>
        {"unsupported", ["invoke_data_model_injection"],
         ["invoke_scxml_element", "param_element"]},
      "245" =>
        {"unsupported", ["invoke_data_model_injection"],
         ["invoke_scxml_element", "param_element"]},
      "247" => {"supported", ["invoke_scxml_element"], []},
      "250" => {"deviation", ["invoke_scxml_element", "post_commit_child_lifecycle"], []},
      "252" => {"deviation", ["invoke_scxml_element", "post_commit_child_lifecycle"], []},
      "253" => {"unsupported", ["scxml_event_io_processor"], ["invoke_scxml_element"]},
      "530" => {"supported", ["invoke_scxml_element", "content_element"], []},
      "554" => {"supported", ["invoke_scxml_element"], []}
    }

    assert Map.keys(expected) |> Enum.sort() ==
             assertions
             |> Map.values()
             |> Enum.filter(&(&1["spec"] == "6.4"))
             |> Enum.map(& &1["id"])
             |> Enum.sort()

    for {id, {status, direct_features, related_features}} <- expected do
      assertion = Map.fetch!(assertions, id)
      assert assertion["profile_status"] == status
      assert direct(assertion) == direct_features
      assert related(assertion) == related_features
      refute "remote_invocation" in assertion["profile_features"]

      if status != "supported" do
        assert is_binary(assertion["reason"]) and String.trim(assertion["reason"]) != ""
      end
    end

    abstract_markers = %{
      "216" => "srcexpr attribute",
      "226" => "start a new logical instance",
      "232" => "return multiple events",
      "236" => "MUST NOT generate any other events",
      "239" => "markup to be executed",
      "240" => "injected into their data models",
      "241" => "param and namelist identically",
      "242" => "'src' and content identically",
      "250" => "execute the onexit handlers",
      "252" => "MUST NOT insert any events",
      "253" => "SCXML Event/IO processor"
    }

    for {id, marker} <- abstract_markers do
      assert Map.fetch!(assertions, id)["abstract"] =~ marker
    end

    assert assertions["224"]["reason"] =~ "stateid.platformid"
    assert assertions["224"]["reason"] =~ "deterministic hashed"

    for id <- ~w(240 243 244 245) do
      assert assertions[id]["reason"] =~ "top-level data model"
      assert assertions[id]["category"] == "unsupported"
    end

    assert assertions["241"]["reason"] =~ "ordered portable input metadata"

    event_fields = %{
      "330" => {"deviation", ["system_variables", "event_system_field_shape"]},
      "331" => {"deviation", ["system_variables", "event_system_type"]},
      "332" => {"deviation", ["system_variables", "event_system_send_id"]},
      "333" => {"deviation", ["system_variables", "event_system_send_id"]},
      "335" => {"supported", ["system_variables", "event_system_origin"]},
      "336" => {"deviation", ["system_variables", "event_system_origin_type"]},
      "337" => {"deviation", ["system_variables", "event_system_origin_type"]},
      "338" => {"deviation", ["system_variables", "event_system_invoke_id"]},
      "339" => {"deviation", ["system_variables", "event_system_invoke_id"]},
      "342" => {"supported", ["system_variables", "event_system_name"]}
    }

    for {id, {status, direct_features}} <- event_fields do
      assertion = Map.fetch!(assertions, id)
      assert assertion["profile_status"] == status
      assert direct(assertion) == direct_features
      assert related(assertion) == ["internal_event_queue"]
    end

    for id <- ~w(189 190 191 192 193 347 348 349 350 351 352 354 495 496 500 501) do
      assertion = Map.fetch!(assertions, id)
      assert assertion["profile_status"] == "unsupported"
      assert direct(assertion) == ["scxml_event_io_processor"]
      assert assertion["execution_status"] == "skipped"
      assert assertion["category"] == "unsupported"
      assert assertion["reason"] =~ "SCXML Event I/O Processor"
    end
  end

  test "every profile deviation maps to an existing regression" do
    root = Path.expand("../..", __DIR__)
    rows = Conformance.profile_matrix()
    deviations = Enum.filter(rows, &(&1.status == :deviation))

    assert Enum.sort(Enum.map(deviations, & &1.id)) ==
             Profile.features()
             |> Enum.filter(&(&1.status == :deviation))
             |> Enum.map(& &1.id)
             |> Enum.sort()

    for row <- deviations do
      assert row.regressions != []

      for regression <- row.regressions do
        source = File.read!(Path.join(root, regression["file"]))
        assert source =~ ~s(test "#{regression["name"]}")
        assert is_binary(regression["expected"]) and regression["expected"] != ""
      end
    end
  end

  test "the generated profile matrix gives every public row a stable evidence key and test" do
    root = Path.expand("../..", __DIR__)
    matrix = Conformance.profile_matrix()

    assert Enum.map(matrix, & &1.id) == Enum.map(Profile.features(), & &1.id)
    assert Enum.uniq_by(matrix, & &1.evidence_key) == matrix

    registered_ids =
      Conformance.evidence_registry()
      |> Enum.map(& &1["id"])

    assert registered_ids == Enum.map(Profile.features(), & &1.evidence_key)
    assert Enum.uniq(registered_ids) == registered_ids

    for row <- matrix do
      assert is_binary(row.evidence_key) and row.evidence_key != ""
      assert [%{"id" => evidence_id} = regression] = row.regressions
      assert evidence_id == row.evidence_key
      assert regression == Map.fetch!(Conformance.evidence_index(), row.evidence_key)
      assert regression["feature"] == Atom.to_string(row.id)

      source = File.read!(Path.join(root, regression["file"]))
      assert source =~ ~s(test "#{regression["name"]}")
      assert is_binary(regression["expected"]) and regression["expected"] != ""

      expected_cases =
        for assertion <- row.assertions,
            case_info <- Conformance.selected_cases(),
            case_info["assertion_id"] == assertion,
            do: Map.take(case_info, ["id", "test_id", "expected"])

      assert row.assertion_cases == expected_cases
    end
  end

  test "package files include public guides, examples, and licensed W3C evidence" do
    root = Path.expand("../..", __DIR__)
    package = Mix.Project.config()[:package]
    files = package[:files]

    assert package[:licenses] == ["Apache-2.0", "BSD-3-Clause"]
    assert Enum.all?(["guides", "examples", "test/fixtures/w3c"], &(&1 in files))

    for path <- [
          "guides/runtime.md",
          "examples/door.exs",
          "examples/door.scxml",
          "examples/parallel_approval.exs",
          "examples/parallel_approval.scxml",
          "test/fixtures/w3c/README.md",
          "test/fixtures/w3c/LICENSE",
          "test/fixtures/w3c/manifest.json"
        ] do
      assert File.regular?(Path.join(root, path))
    end

    license = File.read!(Path.join(root, "test/fixtures/w3c/LICENSE"))
    assert license =~ "W3C 3-clause BSD License"
    assert license =~ "https://www.w3.org/copyright/3-clause-bsd-license-2008/"
  end

  defp direct(assertion), do: related_by(assertion, "direct_required")
  defp related(assertion), do: related_by(assertion, "related")

  defp related_by(assertion, relation) do
    for row <- assertion["feature_relations"], row["relation"] == relation, do: row["feature"]
  end

  defp expected_assertion_status(features) do
    statuses = Enum.map(features, & &1.status)

    cond do
      :unsupported in statuses -> "unsupported"
      :deviation in statuses -> "deviation"
      :not_applicable in statuses -> "not_applicable"
      true -> "supported"
    end
  end
end
