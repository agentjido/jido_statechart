defmodule Jido.Statechart.ProfileTest do
  use ExUnit.Case, async: true

  alias Jido.Statechart.{Diagnostic, Limits, Profile, Registry, Session}

  defmodule TestAction do
    use Jido.Action, name: "profile_test_action"

    @impl true
    def run(params, _context), do: {:ok, params}
  end

  test "the capability manifest has deterministic status and evidence rows" do
    first = Profile.manifest()
    second = Profile.manifest()

    assert Profile.version() == "jido-scxml-1.0/profile-2"
    assert first == second
    assert first["profile"] == Profile.version()
    assert is_binary(first["digest"])

    assert Enum.all?(
             first["features"],
             &(&1["status"] in ~w(supported unsupported deviation not_applicable))
           )

    assert Enum.all?(
             first["features"],
             &(is_binary(&1["evidence_key"]) and &1["evidence_key"] != "")
           )

    feature_index = Map.new(first["features"], &{&1["id"], &1})
    assert feature_index["scxml_element"]["assertions"] == ["355", "576"]
    assert feature_index["null_datamodel"]["assertions"] == ["436"]
    assert feature_index["in_predicate"]["w3c_section"] == "5.9.1"
    assert feature_index["in_predicate"]["assertions"] == ["310", "436"]
    assert feature_index["event_descriptor_matching"]["assertions"] == ["396", "399"]
    assert feature_index["transition_external"]["assertions"] == ["504", "506", "533"]
    assert feature_index["transition_internal"]["assertions"] == ["505", "506", "533"]
    assert feature_index["transition_targetless"]["assertions"] == ["503"]
    assert feature_index["transition_multi_target"]["assertions"] == []
    assert feature_index["transition_eventless"]["assertions"] == ["419"]
    assert feature_index["remote_invocation"]["assertions"] == []
    assert feature_index["executable_content_order"]["assertions"] == ["158"]
    assert feature_index["executable_content_abort_on_error"]["assertions"] == ["159"]
    assert feature_index["invoke_idlocation_assignment"]["assertions"] == ["223"]
    assert feature_index["invoke_generated_id_form"]["assertions"] == ["224"]
    assert feature_index["invoke_generated_id_uniqueness"]["assertions"] == ["225"]

    assert feature_index["invoke_data_model_injection"]["assertions"] == [
             "240",
             "243",
             "244",
             "245"
           ]

    assert feature_index["invoke_input_metadata"]["assertions"] == ["241"]
    assert feature_index["event_system_field_shape"]["assertions"] == ["330"]
    assert feature_index["event_system_type"]["assertions"] == ["331"]
    assert feature_index["event_system_send_id"]["assertions"] == ["332", "333"]
    assert feature_index["event_system_origin"]["assertions"] == ["335"]
    assert feature_index["event_system_origin_type"]["assertions"] == ["336", "337"]
    assert feature_index["event_system_invoke_id"]["assertions"] == ["338", "339"]
    assert feature_index["event_system_name"]["assertions"] == ["342"]

    assert feature_index["scxml_event_io_processor"]["assertions"] == [
             "253",
             "189",
             "190",
             "191",
             "192",
             "193",
             "347",
             "348",
             "349",
             "350",
             "351",
             "352",
             "354",
             "495",
             "496",
             "500",
             "501"
           ]

    assert :ok = Jido.PortableTerm.validate(first, :manifest)
  end

  test "unknown profile status text does not create an atom" do
    status = "unknown-status-#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(status) end

    assert {:error, %Diagnostic{code: :invalid_profile_status}} =
             Profile.Feature.new(%{
               id: :test_feature,
               status: status,
               w3c_section: "3",
               evidence_key: "profile:test-feature"
             })

    assert_raise ArgumentError, fn -> String.to_existing_atom(status) end
  end

  test "profile feature validation covers text status and malformed input shapes" do
    attrs = %{
      id: :test_feature,
      status: "supported",
      w3c_section: "1.0",
      assertions: ["one"],
      evidence_key: "profile:test_feature"
    }

    assert {:ok, %Profile.Feature{status: :supported}} = Profile.Feature.new(attrs)

    assert {:error, %Diagnostic{code: :invalid_profile_feature, path: [:profile]}} =
             Profile.Feature.new(:invalid)

    assert {:error, %Diagnostic{code: :invalid_profile_feature, path: [:profile, :id]}} =
             Profile.Feature.new(%{attrs | id: "test_feature"})

    assert {:error, %Diagnostic{code: :invalid_profile_status, path: [:profile, :status]}} =
             Profile.Feature.new(%{attrs | status: 1})

    assert {:error, %Diagnostic{code: :invalid_profile_feature, path: [:profile, :assertions]}} =
             Profile.Feature.new(%{attrs | assertions: "one"})
  end

  test "each limit accepts its boundaries and rejects the first value outside them" do
    defaults = Limits.defaults()

    for {name, %{min: min, max: max}} <- Limits.bounds() do
      assert {:ok, %Limits{}} = Limits.new(Map.put(defaults, name, min))
      assert {:ok, %Limits{}} = Limits.new(Map.put(defaults, name, max))

      assert {:error, %Diagnostic{code: :limit_out_of_range, path: [:limits, ^name]}} =
               Limits.new(Map.put(defaults, name, min - 1))

      assert {:error, %Diagnostic{code: :limit_out_of_range, path: [:limits, ^name]}} =
               Limits.new(Map.put(defaults, name, max + 1))
    end
  end

  test "Registry manifests are typed, versioned, and bound to session state" do
    registry =
      Registry.new!(%{
        version: "registry-1",
        entries: [
          %{
            kind: :expression,
            alias: "is_ready",
            permissions: ["read:data"],
            handler: {Kernel, :is_map, 1}
          },
          %{
            kind: :action,
            alias: "record",
            permissions: ["read:data", "write:data"],
            handler: TestAction
          }
        ]
      })

    manifest = Registry.manifest(registry)
    assert manifest["version"] == "registry-1"
    assert manifest["digest"] == registry.digest
    refute inspect(manifest) =~ "Elixir.Kernel"
    assert :ok = Jido.PortableTerm.validate(manifest, :registry)

    session =
      Session.new!(%{
        id: "session-1",
        incarnation: "incarnation-1",
        chart_fingerprint: String.duplicate("a", 64),
        registry_digest: registry.digest,
        limits_digest: Limits.digest(Limits.default()),
        registry_version: registry.version
      })

    assert :ok = Session.validate_contract(session, registry, Limits.default())

    changed =
      Registry.new!(%{
        version: "registry-1",
        entries: [
          %{
            kind: :expression,
            alias: "is_ready",
            permissions: ["write:data"],
            handler: {Kernel, :is_map, 1}
          }
        ]
      })

    assert {:error, %Diagnostic{code: :registry_digest_mismatch}} =
             Session.validate_contract(session, changed, Limits.default())

    assert {:error, %Diagnostic{code: :limits_digest_mismatch}} =
             Session.validate_contract(
               session,
               registry,
               Limits.new!(%{Limits.defaults() | trace_entries: 2})
             )

    assert {:error, %Diagnostic{code: :limit_out_of_range}} =
             Session.validate_contract(
               session,
               registry,
               %{Limits.default() | data_bytes: -1}
             )
  end

  test "Registry rejects cross-kind aliases and duplicate replacements" do
    assert {:error, %Diagnostic{code: :duplicate_registry_alias}} =
             Registry.new(%{
               version: "registry-1",
               entries: [
                 %{kind: :expression, alias: "same", permissions: [], handler: __MODULE__},
                 %{kind: :target, alias: "same", permissions: [], handler: __MODULE__}
               ]
             })

    registry =
      Registry.new!(%{
        version: "registry-1",
        entries: [%{kind: :action, alias: "work", permissions: [], handler: TestAction}]
      })

    assert {:error, %Diagnostic{code: :registry_replacement}} =
             Registry.put(registry, %{
               kind: :action,
               alias: "work",
               permissions: [],
               handler: Kernel
             })

    assert {:ok, extended} =
             Registry.put(registry, %{
               kind: :target,
               alias: "parent",
               permissions: ["send:event"],
               handler: __MODULE__
             })

    assert {:ok, _entry} = Registry.fetch(extended, :target, "parent")
  end

  test "unsupported stored schema versions fail before runtime startup" do
    assert {:error, %Diagnostic{code: :invalid_session_version}} =
             Session.new(%{
               schema_version: 99,
               id: "session-1",
               incarnation: "incarnation-1",
               chart_fingerprint: String.duplicate("a", 64),
               registry_digest: String.duplicate("b", 64),
               limits_digest: Limits.digest(Limits.default())
             })
  end
end
