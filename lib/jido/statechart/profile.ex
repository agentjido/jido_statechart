defmodule Jido.Statechart.Profile do
  @moduledoc "The machine-readable Jido SCXML 1.0 Profile."

  alias Jido.Statechart.Diagnostic

  @version "jido-scxml-1.0/profile-1"

  @features [
    {:scxml_element, :supported, "3.2", ["test436"], nil},
    {:state_atomic, :supported, "3.3", [], nil},
    {:state_compound, :supported, "3.3", [], nil},
    {:state_parallel, :supported, "3.4", [], nil},
    {:state_final, :supported, "3.7", [], nil},
    {:initial_element, :supported, "3.6", [], nil},
    {:history_shallow, :supported, "3.10", [], nil},
    {:history_deep, :supported, "3.10", [], nil},
    {:transition_external, :supported, "3.5", [], nil},
    {:transition_internal, :supported, "3.5", [], nil},
    {:transition_targetless, :supported, "3.5", [], nil},
    {:transition_multi_target, :supported, "3.5", [], nil},
    {:transition_eventless, :supported, "3.5", [], nil},
    {:onentry_element, :supported, "3.8", [], nil},
    {:onexit_element, :supported, "3.9", [], nil},
    {:datamodel_element, :supported, "5.2", [], nil},
    {:data_element, :supported, "5.3", [], nil},
    {:donedata_element, :supported, "5.5", [], nil},
    {:param_element, :supported, "5.7", [], nil},
    {:content_element, :supported, "5.6", [], nil},
    {:raise_element, :supported, "4.2", [], nil},
    {:if_element, :supported, "4.3", [], nil},
    {:elseif_element, :supported, "4.3", [], nil},
    {:else_element, :supported, "4.3", [], nil},
    {:foreach_element, :supported, "4.6", [], nil},
    {:assign_element, :supported, "5.4", [], nil},
    {:log_element, :supported, "4.7", [], nil},
    {:send_element, :supported, "6.2", [], nil},
    {:cancel_element, :supported, "6.3", [], nil},
    {:invoke_scxml_element, :supported, "6.4", [], nil},
    {:invoke_jido_element, :deviation, nil, [],
     "A typed Jido extension invokes an allowlisted local Agent capability."},
    {:finalize_element, :supported, "6.5", [], nil},
    {:invoke_autoforward, :supported, "6.4", [], nil},
    {:binding_early, :supported, "3.2", [], nil},
    {:binding_late, :supported, "3.2", [], nil},
    {:internal_event_queue, :supported, "5.10", [], nil},
    {:run_to_completion, :supported, "3.13", [], nil},
    {:null_datamodel, :supported, "B.1", [], nil},
    {:jido_datamodel, :deviation, nil, [],
     "A restricted Jido data model replaces source evaluation."},
    {:in_predicate, :supported, "5.9.1", [], nil},
    {:system_variables, :supported, "5.10", [], nil},
    {:jido_action_extension, :deviation, nil, [],
     "An allowlisted effect-free Jido Action can provide executable content."},
    {:script_element, :unsupported, "5.8", [], "The profile does not evaluate source code."},
    {:external_data_source, :unsupported, "5.3", [],
     "The secure profile does not fetch external data resources."},
    {:external_content_source, :unsupported, "5.6", [],
     "The secure profile does not fetch external content resources."},
    {:ecmascript_datamodel, :unsupported, "B.2", [],
     "The first profile does not embed ECMAScript."},
    {:xpath_datamodel, :unsupported, "B.3", [], "The first profile does not embed XPath."},
    {:basic_http_event_io, :unsupported, "C.2", [],
     "The first profile supports local Jido targets only."},
    {:remote_invocation, :unsupported, "6.4", [],
     "The first profile invokes local allowlisted capabilities only."},
    {:bounded_macrostep, :deviation, "D", [],
     "A configured limit can stop run-to-completion work."},
    {:restricted_xml, :deviation, "E", [],
     "DTD, entity, external resource, and unsupported encoding input is rejected."},
    {:commit_then_dispatch, :deviation, "6.2", [],
     "External work starts after the Jido Agent commit."},
    {:post_commit_child_lifecycle, :deviation, "6", [],
     "Local child start and stop operations use later control Turns."},
    {:dom_binding, :not_applicable, "B.2", [],
     "The supported data models do not expose a DOM object."}
  ]

  defmodule Feature do
    @moduledoc "One feature claim in the Jido SCXML Profile."

    alias Jido.Statechart.Diagnostic

    @statuses [:supported, :unsupported, :deviation, :not_applicable]
    @fields [:id, :status, :w3c_section, :assertions, :reason, :evidence_key]

    defstruct id: nil,
              status: nil,
              w3c_section: nil,
              assertions: [],
              reason: nil,
              evidence_key: nil

    @type t :: %__MODULE__{}

    @spec new(map()) :: {:ok, t()} | {:error, Diagnostic.t()}
    def new(attrs) when is_map(attrs) do
      with :ok <- Diagnostic.validate_fields(attrs, @fields, [:profile]),
           {:ok, id} <- id(Diagnostic.fetch(attrs, :id)),
           {:ok, status} <- status(Diagnostic.fetch(attrs, :status)),
           {:ok, section} <- Diagnostic.optional_string(attrs, :w3c_section, [:profile]),
           {:ok, assertions} <- strings(Diagnostic.fetch(attrs, :assertions, []), :assertions),
           {:ok, reason} <- Diagnostic.optional_string(attrs, :reason, [:profile]),
           {:ok, evidence_key} <-
             Diagnostic.require_string(attrs, :evidence_key, [:profile]),
           :ok <- reason_for_status(status, reason) do
        {:ok,
         %__MODULE__{
           id: id,
           status: status,
           w3c_section: section,
           assertions: assertions,
           reason: reason,
           evidence_key: evidence_key
         }}
      end
    end

    def new(_attrs),
      do:
        {:error,
         Diagnostic.new(:invalid_profile_feature, "profile feature must be a map",
           path: [:profile]
         )}

    @spec new!(map()) :: t()
    def new!(attrs), do: attrs |> new() |> Diagnostic.unwrap!()

    @spec dump(t()) :: map()
    def dump(%__MODULE__{} = feature) do
      %{
        "id" => Atom.to_string(feature.id),
        "status" => Atom.to_string(feature.status),
        "w3c_section" => feature.w3c_section,
        "assertions" => feature.assertions,
        "reason" => feature.reason,
        "evidence_key" => feature.evidence_key
      }
    end

    defp id(id) when is_atom(id) and id not in [nil, true, false], do: {:ok, id}

    defp id(_id),
      do:
        {:error,
         Diagnostic.new(:invalid_profile_feature, "profile feature ID must be package-owned",
           path: [:profile, :id]
         )}

    defp status(status) when status in @statuses, do: {:ok, status}

    defp status(status) when is_binary(status) do
      case Enum.find(@statuses, &(Atom.to_string(&1) == status)) do
        nil -> invalid_status()
        known -> {:ok, known}
      end
    end

    defp status(_status), do: invalid_status()

    defp invalid_status,
      do:
        {:error,
         Diagnostic.new(:invalid_profile_status, "profile status is not supported",
           path: [:profile, :status]
         )}

    defp strings(values, field) when is_list(values) do
      if Enum.all?(values, &(is_binary(&1) and &1 != "" and String.valid?(&1))) do
        {:ok, values}
      else
        {:error,
         Diagnostic.new(:invalid_profile_feature, "profile references must be UTF-8 strings",
           path: [:profile, field]
         )}
      end
    end

    defp strings(_values, field),
      do:
        {:error,
         Diagnostic.new(:invalid_profile_feature, "profile references must be a list",
           path: [:profile, field]
         )}

    defp reason_for_status(status, reason) when status in [:unsupported, :deviation] do
      if is_binary(reason) and reason != "" do
        :ok
      else
        {:error,
         Diagnostic.new(:missing_profile_reason, "unsupported and deviation rows need a reason",
           path: [:profile, :reason]
         )}
      end
    end

    defp reason_for_status(_status, _reason), do: :ok
  end

  @doc "Returns the profile version."
  @spec version() :: String.t()
  def version, do: @version

  @doc "Returns the ordered profile feature rows."
  @spec features() :: [Feature.t()]
  def features do
    Enum.map(@features, fn {id, status, section, assertions, reason} ->
      Feature.new!(%{
        id: id,
        status: status,
        w3c_section: section,
        assertions: assertions,
        reason: reason,
        evidence_key: "profile:#{id}"
      })
    end)
  end

  @doc "Returns the deterministic portable capability manifest."
  @spec manifest() :: map()
  def manifest do
    base = %{
      "profile" => @version,
      "conformance_claim" => "profile",
      "features" => Enum.map(features(), &Feature.dump/1)
    }

    Map.put(base, "digest", Diagnostic.digest(base))
  end
end
