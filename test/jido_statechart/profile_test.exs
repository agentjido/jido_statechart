defmodule Jido.Statechart.ProfileTest do
  use ExUnit.Case, async: true

  alias Jido.Statechart.{Diagnostic, Limits, Profile, Registry, Session}

  test "the capability manifest has deterministic status and evidence rows" do
    first = Profile.manifest()
    second = Profile.manifest()

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
            handler: __MODULE__
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
        entries: [%{kind: :action, alias: "work", permissions: [], handler: __MODULE__}]
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
