defmodule Jido.Statechart.Profile do
  @moduledoc "The machine-readable Jido SCXML 1.0 Profile."

  alias Jido.Statechart.Diagnostic

  @version "jido-scxml-1.0/profile-2"

  @assertions %{
    scxml_element: ["355", "576"],
    scxml_initial_default: ["355", "576", "413"],
    state_compound: ["364"],
    initial_element: ["364", "412"],
    state_final: ["372", "570", "415", "416", "417"],
    state_parallel: ["570", "417"],
    onentry_element: ["375", "376", "405", "406", "411", "158", "159"],
    onexit_element: ["377", "378", "404", "405", "407", "158", "159"],
    history_shallow: ["387", "579", "580", "388"],
    history_deep: ["387", "579", "580", "388"],
    event_descriptor_matching: ["396", "399"],
    transition_external: ["504", "506", "533"],
    transition_internal: ["505", "506", "533"],
    transition_targetless: ["503"],
    transition_multi_target: [],
    transition_eventless: ["419"],
    internal_event_queue: [
      "401",
      "402",
      "421",
      "144",
      "318",
      "319",
      "330",
      "331",
      "332",
      "333",
      "335",
      "336",
      "337",
      "338",
      "339",
      "342"
    ],
    optimal_transition_set: ["403"],
    executable_content_order: ["158"],
    executable_content_abort_on_error: ["159"],
    run_to_completion: [
      "404",
      "405",
      "406",
      "407",
      "409",
      "411",
      "412",
      "413",
      "415",
      "416",
      "417",
      "419",
      "421",
      "422",
      "423"
    ],
    state_atomic: ["409"],
    invoke_scxml_element: [
      "422",
      "215",
      "216",
      "220",
      "223",
      "224",
      "225",
      "226",
      "228",
      "229",
      "230",
      "232",
      "233",
      "234",
      "235",
      "236",
      "237",
      "239",
      "240",
      "241",
      "242",
      "243",
      "244",
      "245",
      "247",
      "250",
      "252",
      "253",
      "530",
      "554"
    ],
    post_commit_child_lifecycle: ["422", "226", "237", "250", "252"],
    invoke_idlocation_assignment: ["223"],
    invoke_generated_id_form: ["224"],
    invoke_generated_id_uniqueness: ["225"],
    invoke_data_model_injection: ["240", "243", "244", "245"],
    invoke_input_metadata: ["241"],
    commit_then_dispatch: ["423", "185", "186", "187", "521"],
    raise_element: ["144", "158", "159"],
    if_element: ["147", "148", "149", "158", "159"],
    elseif_element: ["147"],
    else_element: ["148", "149"],
    foreach_element: [
      "150",
      "151",
      "152",
      "153",
      "155",
      "156",
      "525",
      "158",
      "159",
      "457",
      "459",
      "460"
    ],
    assign_element: ["158", "159", "286", "287", "487"],
    log_element: ["158", "159"],
    send_element: [
      "158",
      "159",
      "172",
      "173",
      "174",
      "175",
      "176",
      "178",
      "179",
      "183",
      "185",
      "186",
      "187",
      "194",
      "198",
      "199",
      "200",
      "201",
      "205",
      "521",
      "553"
    ],
    cancel_element: ["158", "159", "207", "208", "210"],
    datamodel_element: ["276", "277", "279", "280", "550", "551", "552"],
    data_element: ["276", "277", "279", "280", "550", "551", "552"],
    binding_early: ["279"],
    binding_late: ["280", "307"],
    external_data_source: ["552"],
    donedata_element: ["294"],
    content_element: ["527", "528", "529", "179", "205", "239", "242", "530"],
    param_element: ["298", "343", "488", "176", "178", "240", "241", "243", "244", "245"],
    script_element: ["301", "302", "303", "304", "456"],
    jido_datamodel: ["307", "309", "310", "311", "312", "313", "314", "344"],
    in_predicate: ["310", "436"],
    system_variables: [
      "318",
      "319",
      "321",
      "322",
      "323",
      "324",
      "325",
      "326",
      "329",
      "330",
      "331",
      "332",
      "333",
      "335",
      "336",
      "337",
      "338",
      "339",
      "342",
      "346"
    ],
    event_system_field_shape: ["330"],
    event_system_type: ["331"],
    event_system_send_id: ["332", "333"],
    event_system_origin: ["335"],
    event_system_origin_type: ["336", "337"],
    event_system_invoke_id: ["338", "339"],
    event_system_name: ["342"],
    basic_http_event_io: [
      "201",
      "509",
      "510",
      "513",
      "518",
      "519",
      "520",
      "522",
      "531",
      "532",
      "534",
      "567",
      "577"
    ],
    remote_invocation: [],
    external_content_source: ["216", "239", "242"],
    invoke_autoforward: ["229", "230"],
    finalize_element: ["233", "234"],
    null_datamodel: ["436"],
    ecmascript_datamodel: [
      "278",
      "444",
      "445",
      "448",
      "449",
      "451",
      "452",
      "453",
      "456",
      "446",
      "557",
      "558",
      "560",
      "578",
      "561",
      "562",
      "569",
      "457",
      "459",
      "460"
    ],
    dom_binding: ["557", "561"],
    scxml_event_io_processor: [
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
  }

  @features [
    {:scxml_element, :supported, "3.2", nil, nil},
    {:state_atomic, :supported, "3.3", nil, nil},
    {:state_compound, :supported, "3.3", nil, nil},
    {:state_parallel, :supported, "3.4", nil, nil},
    {:state_final, :supported, "3.7", nil, nil},
    {:scxml_initial_default, :supported, "3.2", nil, nil},
    {:initial_element, :supported, "3.6", nil, nil},
    {:history_shallow, :supported, "3.10", nil, nil},
    {:history_deep, :supported, "3.10", nil, nil},
    {:transition_external, :supported, "3.5", nil, nil},
    {:transition_internal, :supported, "3.5", nil, nil},
    {:transition_targetless, :supported, "3.5", nil, nil},
    {:transition_multi_target, :supported, "3.5", nil, nil},
    {:transition_eventless, :supported, "3.5", nil, nil},
    {:event_descriptor_matching, :supported, "3.12", nil, nil},
    {:onentry_element, :supported, "3.8", nil, nil},
    {:onexit_element, :supported, "3.9", nil, nil},
    {:datamodel_element, :supported, "5.2", nil, nil},
    {:data_element, :supported, "5.3", nil, nil},
    {:donedata_element, :supported, "5.5", nil, nil},
    {:param_element, :supported, "5.7", nil, nil},
    {:content_element, :supported, "5.6", nil, nil},
    {:raise_element, :supported, "4.2", nil, nil},
    {:if_element, :supported, "4.3", nil, nil},
    {:elseif_element, :supported, "4.3", nil, nil},
    {:else_element, :supported, "4.3", nil, nil},
    {:foreach_element, :supported, "4.6", nil, nil},
    {:assign_element, :supported, "5.4", nil, nil},
    {:log_element, :supported, "4.7", nil, nil},
    {:send_element, :supported, "6.2", nil, nil},
    {:cancel_element, :supported, "6.3", nil, nil},
    {:executable_content_order, :supported, "4.9", nil, nil},
    {:executable_content_abort_on_error, :supported, "4.9", nil, nil},
    {:invoke_scxml_element, :supported, "6.4", nil, nil},
    {:invoke_idlocation_assignment, :supported, "6.4", nil, nil},
    {:invoke_generated_id_form, :deviation, "6.4", nil,
     "Generated invoke identifiers are deterministic hashed session-scoped identifiers, not stateid.platformid identifiers."},
    {:invoke_generated_id_uniqueness, :supported, "6.4", nil, nil},
    {:invoke_data_model_injection, :unsupported, "6.4", nil,
     "Invoke input is not injected or filtered against the child SCXML top-level data model."},
    {:invoke_input_metadata, :deviation, "6.4", nil,
     "Param and namelist input is preserved in ordered portable metadata instead of SCXML data-model injection."},
    {:invoke_jido_element, :deviation, nil, nil,
     "A typed Jido extension invokes an allowlisted local Agent capability."},
    {:finalize_element, :supported, "6.5", nil, nil},
    {:invoke_autoforward, :supported, "6.4", nil, nil},
    {:binding_early, :supported, "3.2", nil, nil},
    {:binding_late, :supported, "3.2", nil, nil},
    {:internal_event_queue, :supported, "5.10", nil, nil},
    {:run_to_completion, :supported, "3.13", nil, nil},
    {:optimal_transition_set, :supported, "3.13", nil, nil},
    {:null_datamodel, :supported, "B.1", nil, nil},
    {:jido_datamodel, :deviation, "5.9", nil,
     "A restricted Jido data model replaces source evaluation."},
    {:in_predicate, :supported, "5.9.1", nil, nil},
    {:system_variables, :supported, "5.10", nil, nil},
    {:event_system_field_shape, :deviation, "5.10", nil,
     "The Jido event map uses class, send_id, origin_type, and invoke_id instead of the SCXML type, sendid, origintype, and invokeid field names."},
    {:event_system_type, :deviation, "5.10", nil,
     "The SCXML event type value is stored in the normalized Jido class field."},
    {:event_system_send_id, :deviation, "5.10", nil,
     "The SCXML sendid value is stored in the normalized Jido send_id field; asynchronous delivery errors use operation correlation."},
    {:event_system_origin, :supported, "5.10", nil, nil},
    {:event_system_origin_type, :deviation, "5.10", nil,
     "The SCXML origintype value is stored in the normalized Jido origin_type field."},
    {:event_system_invoke_id, :deviation, "5.10", nil,
     "The SCXML invokeid value is stored in the normalized Jido invoke_id field."},
    {:event_system_name, :supported, "5.10", nil, nil},
    {:jido_action_extension, :deviation, nil, nil,
     "An allowlisted effect-free Jido Action can provide executable content."},
    {:script_element, :unsupported, "5.8", nil, "The profile does not evaluate source code."},
    {:external_data_source, :unsupported, "5.3", nil,
     "The secure profile does not fetch external data resources."},
    {:external_content_source, :unsupported, "6.4", nil,
     "The secure profile does not fetch external content resources."},
    {:ecmascript_datamodel, :unsupported, "B.2", nil,
     "The first profile does not embed ECMAScript."},
    {:xpath_datamodel, :unsupported, "B.3", nil, "The first profile does not embed XPath."},
    {:basic_http_event_io, :unsupported, "C.2", nil,
     "The first profile supports local Jido targets only."},
    {:scxml_event_io_processor, :unsupported, "C.1", nil,
     "The first profile does not implement the SCXML Event I/O Processor."},
    {:remote_invocation, :unsupported, "6.4", nil,
     "The first profile invokes local allowlisted capabilities only."},
    {:bounded_macrostep, :deviation, "D", nil,
     "A configured limit can stop run-to-completion work."},
    {:restricted_xml, :deviation, "E", nil,
     "DTD, entity, external resource, and unsupported encoding input is rejected."},
    {:commit_then_dispatch, :deviation, "6.2", nil,
     "External work starts after the Jido Agent commit."},
    {:post_commit_child_lifecycle, :deviation, "6.4", nil,
     "Local child start and stop operations use later control Turns."},
    {:dom_binding, :not_applicable, "B.2", nil,
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
    Enum.map(@features, fn {id, status, section, _assertions, reason} ->
      Feature.new!(%{
        id: id,
        status: status,
        w3c_section: section,
        assertions: Map.get(@assertions, id, []),
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
