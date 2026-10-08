defmodule Jido.Statechart.Session do
  @moduledoc """
  Portable state for one statechart session.

  The session binds the chart, profile, Registry manifest, limits contract, and
  runtime protocol. Runtime process references and proof secrets do not belong
  in this value.
  """

  alias Jido.Statechart.{Diagnostic, Limits, Profile, Registry}

  @schema_version 3
  @runtime_protocol_version 3
  @data_model_version "1"
  @limits_version "2"
  @generated_id_prefix "__jido_scxml_generated_"
  @statuses [:new, :active, :completed, :cleaning, :stopped]
  @version_fields [
    :schema_version,
    :runtime_protocol_version,
    :profile_version,
    :data_model_version,
    :registry_version,
    :limits_version
  ]
  @fields @version_fields ++
            [
              :id,
              :incarnation,
              :chart_fingerprint,
              :registry_digest,
              :limits_digest,
              :invocation_ancestry,
              :invocation_depth,
              :invocation_remaining_descendants,
              :invocation_descendants_used,
              :status,
              :revision,
              :revision_fence,
              :generated_id_counter,
              :operation_counter,
              :operation_high_water,
              :received_operation_ids,
              :initialized_data_state_ids,
              :configuration,
              :history,
              :data,
              :internal_queue,
              :operations,
              :operation_tombstones,
              :completion_data,
              :trace
            ]

  defmodule Operation do
    @moduledoc "One durable external-operation record."

    alias Jido.Statechart.Diagnostic

    @kinds [:send, :timer, :invoke, :cancel, :child_start, :child_stop]
    @states [
      :not_started,
      :result_unknown,
      :confirmed_complete,
      :retryable_failure,
      :permanent_failure,
      :cancel_requested,
      :canceled
    ]
    @retention_classes [:active, :terminal, :audit]

    @identity_version 1
    @fields [
      :id,
      :identity_version,
      :session_incarnation,
      :kind,
      :target,
      :key,
      :payload_digest,
      :due_at,
      :generation,
      :state,
      :attempt_count,
      :next_attempt_at,
      :created_revision,
      :result_revision,
      :result,
      :retention_class,
      :correlation
    ]

    defstruct id: nil,
              identity_version: @identity_version,
              session_incarnation: nil,
              kind: nil,
              target: nil,
              key: nil,
              payload_digest: nil,
              due_at: nil,
              generation: 0,
              state: :not_started,
              attempt_count: 0,
              next_attempt_at: nil,
              created_revision: 0,
              result_revision: nil,
              result: nil,
              retention_class: :active,
              correlation: %{}

    @type t :: %__MODULE__{}

    @spec new(map()) :: {:ok, t()} | {:error, Diagnostic.t()}
    def new(%__MODULE__{} = operation), do: operation |> Map.from_struct() |> new()

    def new(attrs) when is_map(attrs), do: parse(attrs, false)

    def new(_attrs),
      do:
        {:error,
         Diagnostic.new(:invalid_operation, "operation must be a map", path: [:operation])}

    @doc "Loads a persisted operation with an explicit identity version."
    @spec load(map()) :: {:ok, t()} | {:error, Diagnostic.t()}
    def load(attrs) when is_map(attrs), do: parse(attrs, true)

    def load(_attrs),
      do:
        {:error,
         Diagnostic.new(:invalid_operation, "stored operation must be a map", path: [:operation])}

    @doc "Derives the immutable operation ID from all delivery identity fields."
    @spec identity(map()) :: {:ok, String.t()} | {:error, Diagnostic.t()}
    def identity(attrs) when is_map(attrs) do
      with :ok <- Diagnostic.validate_fields(attrs, @fields, [:operation]),
           {:ok, identity_version} <-
             identity_version(Diagnostic.fetch(attrs, :identity_version, 1)),
           {:ok, session_incarnation} <- required_id(attrs, :session_incarnation),
           {:ok, kind} <- enum(Diagnostic.fetch(attrs, :kind), @kinds, :invalid_operation_kind),
           {:ok, target} <- Diagnostic.require_string(attrs, :target, [:operation]),
           {:ok, _key} <- Diagnostic.optional_string(attrs, :key, [:operation]),
           {:ok, payload_digest} <- digest(Diagnostic.fetch(attrs, :payload_digest)),
           {:ok, due_at} <- timestamp(Diagnostic.fetch(attrs, :due_at), :due_at),
           :ok <- valid_due_at(kind, due_at),
           {:ok, generation} <- nonnegative(Diagnostic.fetch(attrs, :generation, 0), :generation) do
        identity = %{
          "identity_version" => identity_version,
          "session_incarnation" => session_incarnation,
          "kind" => Atom.to_string(kind),
          "target" => target,
          "payload_digest" => payload_digest,
          "due_at" => due_at,
          "generation" => generation
        }

        {:ok, "op_v#{identity_version}_#{Diagnostic.digest(identity)}"}
      end
    end

    def identity(_attrs),
      do: {:error, Diagnostic.new(:invalid_operation, "operation identity must be a map")}

    defp parse(attrs, strict?) do
      with :ok <- Diagnostic.validate_fields(attrs, @fields, [:operation]),
           :ok <- required_identity_version(attrs, strict?),
           {:ok, identity_version} <-
             identity_version(Diagnostic.fetch(attrs, :identity_version, @identity_version)),
           {:ok, session_incarnation} <- required_id(attrs, :session_incarnation),
           {:ok, kind} <- enum(Diagnostic.fetch(attrs, :kind), @kinds, :invalid_operation_kind),
           {:ok, target} <- Diagnostic.require_string(attrs, :target, [:operation]),
           {:ok, key} <- Diagnostic.optional_string(attrs, :key, [:operation]),
           {:ok, payload_digest} <- digest(Diagnostic.fetch(attrs, :payload_digest)),
           {:ok, due_at} <- Diagnostic.optional_string(attrs, :due_at, [:operation]),
           {:ok, generation} <- nonnegative(Diagnostic.fetch(attrs, :generation, 0), :generation),
           {:ok, derived_id} <- identity(attrs),
           :ok <- validate_supplied_id(Diagnostic.fetch(attrs, :id), derived_id),
           {:ok, state} <-
             enum(
               Diagnostic.fetch(attrs, :state, :not_started),
               @states,
               :invalid_operation_state
             ),
           {:ok, attempt_count} <-
             nonnegative(Diagnostic.fetch(attrs, :attempt_count, 0), :attempt_count),
           {:ok, next_attempt_at} <-
             timestamp(Diagnostic.fetch(attrs, :next_attempt_at), :next_attempt_at),
           {:ok, created_revision} <-
             nonnegative(Diagnostic.fetch(attrs, :created_revision, 0), :created_revision),
           {:ok, result_revision} <-
             optional_nonnegative(Diagnostic.fetch(attrs, :result_revision), :result_revision),
           {:ok, result} <- portable(Diagnostic.fetch(attrs, :result), :result),
           {:ok, retention_class} <-
             enum(
               Diagnostic.fetch(attrs, :retention_class, :active),
               @retention_classes,
               :invalid_retention_class
             ),
           {:ok, correlation} <-
             portable_map(Diagnostic.fetch(attrs, :correlation, %{}), :correlation),
           :ok <- payload_matches_correlation(payload_digest, correlation),
           :ok <-
             valid_combination(
               state,
               attempt_count,
               next_attempt_at,
               created_revision,
               result_revision,
               result,
               retention_class
             ) do
        {:ok,
         %__MODULE__{
           id: derived_id,
           identity_version: identity_version,
           session_incarnation: session_incarnation,
           kind: kind,
           target: target,
           key: key,
           payload_digest: payload_digest,
           due_at: due_at,
           generation: generation,
           state: state,
           attempt_count: attempt_count,
           next_attempt_at: next_attempt_at,
           created_revision: created_revision,
           result_revision: result_revision,
           result: result,
           retention_class: retention_class,
           correlation: correlation
         }}
      end
    end

    @spec new!(map()) :: t()
    def new!(attrs), do: attrs |> new() |> Diagnostic.unwrap!()

    @spec dump(t()) :: map()
    def dump(%__MODULE__{} = operation) do
      base = %{
        "id" => operation.id,
        "identity_version" => operation.identity_version,
        "session_incarnation" => operation.session_incarnation,
        "kind" => Atom.to_string(operation.kind),
        "target" => operation.target,
        "payload_digest" => operation.payload_digest,
        "due_at" => operation.due_at,
        "generation" => operation.generation,
        "state" => Atom.to_string(operation.state),
        "attempt_count" => operation.attempt_count,
        "created_revision" => operation.created_revision,
        "result_revision" => operation.result_revision,
        "result" => operation.result,
        "retention_class" => Atom.to_string(operation.retention_class),
        "correlation" => operation.correlation
      }

      base
      |> maybe_put("key", operation.key)
      |> maybe_put("next_attempt_at", operation.next_attempt_at)
    end

    @spec terminal?(t()) :: boolean()
    def terminal?(%__MODULE__{state: state}),
      do: state in [:confirmed_complete, :permanent_failure, :canceled]

    @spec outcome_digest(t()) :: String.t()
    def outcome_digest(%__MODULE__{} = operation),
      do: Diagnostic.digest(%{"state" => operation.state, "result" => operation.result})

    defp required_id(attrs, field) do
      with {:ok, id} <- Diagnostic.require_string(attrs, field, [:operation]),
           :ok <- Diagnostic.validate_id(id, [:operation, field]),
           do: {:ok, id}
    end

    defp identity_version(@identity_version), do: {:ok, @identity_version}

    defp identity_version(_value),
      do:
        {:error,
         Diagnostic.new(
           :invalid_operation_identity_version,
           "operation identity version is invalid",
           path: [:operation, :identity_version]
         )}

    defp required_identity_version(attrs, true) do
      if Map.has_key?(attrs, :identity_version) or Map.has_key?(attrs, "identity_version"),
        do: :ok,
        else:
          {:error,
           Diagnostic.new(
             :missing_operation_identity_version,
             "stored operation identity version is required",
             path: [:operation, :identity_version]
           )}
    end

    defp required_identity_version(_attrs, false), do: :ok

    defp validate_supplied_id(nil, _derived), do: :ok
    defp validate_supplied_id(id, id), do: :ok

    defp validate_supplied_id(_id, _derived),
      do:
        {:error,
         Diagnostic.new(
           :operation_identity_mismatch,
           "operation ID does not match its identity fields",
           path: [:operation, :id]
         )}

    defp enum(value, values, code) when is_atom(value) do
      if value in values, do: {:ok, value}, else: invalid_enum(code)
    end

    defp enum(value, values, code) when is_binary(value) do
      case Enum.find(values, &(Atom.to_string(&1) == value)) do
        nil -> invalid_enum(code)
        known -> {:ok, known}
      end
    end

    defp enum(_value, _values, code), do: invalid_enum(code)

    defp invalid_enum(code),
      do: {:error, Diagnostic.new(code, "operation value is not supported", path: [:operation])}

    defp digest(value) when is_binary(value) and byte_size(value) == 64 do
      if Regex.match?(~r/^[0-9a-f]{64}$/u, value),
        do: {:ok, value},
        else: invalid_digest()
    end

    defp digest(_value), do: invalid_digest()

    defp invalid_digest,
      do:
        {:error,
         Diagnostic.new(:invalid_digest, "payload digest must be lowercase SHA-256 text",
           path: [:operation, :payload_digest]
         )}

    defp nonnegative(value, _field) when is_integer(value) and value >= 0, do: {:ok, value}

    defp nonnegative(_value, field),
      do:
        {:error,
         Diagnostic.new(:invalid_operation_counter, "operation counter must be nonnegative",
           path: [:operation, field]
         )}

    defp optional_nonnegative(nil, _field), do: {:ok, nil}
    defp optional_nonnegative(value, field), do: nonnegative(value, field)

    defp timestamp(nil, _field), do: {:ok, nil}

    defp timestamp(value, field) when is_binary(value) do
      case DateTime.from_iso8601(value) do
        {:ok, _datetime, 0} -> {:ok, value}
        _other -> invalid_timestamp(field)
      end
    end

    defp timestamp(_value, field), do: invalid_timestamp(field)

    defp invalid_timestamp(field) do
      {:error,
       Diagnostic.new(
         :invalid_operation_timestamp,
         "operation timestamp must be UTC ISO 8601 text",
         path: [:operation, field]
       )}
    end

    defp valid_due_at(:timer, due_at) when is_binary(due_at), do: :ok

    defp valid_due_at(kind, nil)
         when kind in [:send, :invoke, :cancel, :child_start, :child_stop],
         do: :ok

    defp valid_due_at(_kind, _due_at) do
      {:error,
       Diagnostic.new(
         :invalid_operation_due_at,
         "Operation due time does not match its kind",
         path: [:operation, :due_at]
       )}
    end

    defp payload_matches_correlation(payload_digest, correlation) do
      if Diagnostic.digest(correlation) == payload_digest do
        :ok
      else
        {:error,
         Diagnostic.new(
           :operation_payload_digest_mismatch,
           "Operation payload digest does not match its correlation",
           path: [:operation, :payload_digest]
         )}
      end
    end

    defp maybe_put(map, _key, nil), do: map
    defp maybe_put(map, key, value), do: Map.put(map, key, value)

    defp portable(value, field) do
      with :ok <- Diagnostic.portable(value, [:operation, field]), do: {:ok, value}
    end

    defp portable_map(value, field) when is_map(value) and not is_struct(value),
      do: portable(value, field)

    defp portable_map(_value, field),
      do:
        {:error,
         Diagnostic.new(:non_portable_value, "operation field must be a portable map",
           path: [:operation, field]
         )}

    defp valid_combination(
           :not_started,
           0,
           nil,
           _created_revision,
           nil,
           nil,
           :active
         ),
         do: :ok

    defp valid_combination(
           state,
           attempts,
           nil,
           _created_revision,
           nil,
           nil,
           :active
         )
         when state in [:result_unknown, :cancel_requested] and attempts >= 1,
         do: :ok

    defp valid_combination(
           :cancel_requested,
           attempts,
           nil,
           created_revision,
           result_revision,
           result,
           :active
         )
         when attempts >= 1 and is_integer(result_revision) and
                result_revision >= created_revision and not is_nil(result),
         do: :ok

    defp valid_combination(
           :result_unknown,
           attempts,
           next_attempt_at,
           created_revision,
           result_revision,
           result,
           :active
         )
         when attempts >= 1 and (is_nil(next_attempt_at) or is_binary(next_attempt_at)) and
                is_integer(result_revision) and
                result_revision >= created_revision and not is_nil(result),
         do: :ok

    defp valid_combination(
           :retryable_failure,
           attempts,
           next_attempt_at,
           created_revision,
           result_revision,
           result,
           :active
         )
         when attempts >= 1 and (is_nil(next_attempt_at) or is_binary(next_attempt_at)) and
                is_integer(result_revision) and
                result_revision >= created_revision and
                not is_nil(result),
         do: :ok

    defp valid_combination(
           state,
           attempts,
           nil,
           created_revision,
           result_revision,
           result,
           retention_class
         )
         when state in [:confirmed_complete, :permanent_failure, :canceled] and attempts >= 1 and
                is_integer(result_revision) and result_revision >= created_revision and
                not is_nil(result) and retention_class in [:terminal, :audit],
         do: :ok

    defp valid_combination(
           :canceled,
           0,
           nil,
           created_revision,
           result_revision,
           result,
           retention_class
         )
         when is_integer(result_revision) and result_revision >= created_revision and
                not is_nil(result) and retention_class in [:terminal, :audit],
         do: :ok

    defp valid_combination(
           _state,
           _attempts,
           _next_attempt_at,
           _created_revision,
           _result_revision,
           _result,
           _retention_class
         ) do
      {:error,
       Diagnostic.new(
         :invalid_operation_combination,
         "operation fields describe an impossible state",
         path: [:operation]
       )}
    end
  end

  defmodule Tombstone do
    @moduledoc "A retained fence for a collected terminal operation."

    alias Jido.Statechart.Diagnostic
    alias Jido.Statechart.Session.Operation

    @fields [
      :id,
      :identity_version,
      :session_incarnation,
      :kind,
      :target,
      :key,
      :payload_digest,
      :due_at,
      :generation,
      :state,
      :outcome_digest,
      :result_revision,
      :retention_class
    ]

    defstruct id: nil,
              identity_version: 1,
              session_incarnation: nil,
              kind: nil,
              target: nil,
              key: nil,
              payload_digest: nil,
              due_at: nil,
              generation: 0,
              state: nil,
              outcome_digest: nil,
              result_revision: 0,
              retention_class: :terminal

    @type t :: %__MODULE__{}

    @spec from_operation(Operation.t()) :: t()
    def from_operation(%Operation{} = operation) do
      %__MODULE__{
        id: operation.id,
        identity_version: operation.identity_version,
        session_incarnation: operation.session_incarnation,
        kind: operation.kind,
        target: operation.target,
        key: operation.key,
        payload_digest: operation.payload_digest,
        due_at: operation.due_at,
        generation: operation.generation,
        state: operation.state,
        outcome_digest: Operation.outcome_digest(operation),
        result_revision: operation.result_revision || operation.created_revision,
        retention_class: operation.retention_class
      }
    end

    @spec new(map()) :: {:ok, t()} | {:error, Diagnostic.t()}
    def new(attrs) when is_map(attrs) do
      with :ok <- Diagnostic.validate_fields(attrs, @fields, [:tombstone]),
           {:ok, identity_attrs} <- identity_attrs(attrs),
           {:ok, derived_id} <- Operation.identity(identity_attrs),
           true <- Diagnostic.fetch(attrs, :id) == derived_id,
           generation = identity_attrs.generation,
           key = Diagnostic.fetch(attrs, :key),
           state = Diagnostic.fetch(attrs, :state),
           digest = Diagnostic.fetch(attrs, :outcome_digest),
           revision = Diagnostic.fetch(attrs, :result_revision),
           {:ok, known_state} <- terminal_state(state),
           true <- is_binary(digest) and Regex.match?(~r/^[0-9a-f]{64}$/u, digest),
           true <- is_integer(revision) and revision >= 0,
           {:ok, retention_class} <- retention_class(Diagnostic.fetch(attrs, :retention_class)) do
        {:ok,
         %__MODULE__{
           id: derived_id,
           identity_version: identity_attrs.identity_version,
           session_incarnation: identity_attrs.session_incarnation,
           kind: identity_attrs.kind,
           target: identity_attrs.target,
           key: key,
           payload_digest: identity_attrs.payload_digest,
           due_at: identity_attrs.due_at,
           generation: generation,
           state: known_state,
           outcome_digest: digest,
           result_revision: revision,
           retention_class: retention_class
         }}
      else
        {:error, _} = error -> error
        _ -> {:error, Diagnostic.new(:invalid_tombstone, "operation tombstone is invalid")}
      end
    end

    def new(_attrs),
      do: {:error, Diagnostic.new(:invalid_tombstone, "operation tombstone must be a map")}

    @spec dump(t()) :: map()
    def dump(%__MODULE__{} = tombstone) do
      base = %{
        "id" => tombstone.id,
        "identity_version" => tombstone.identity_version,
        "session_incarnation" => tombstone.session_incarnation,
        "kind" => Atom.to_string(tombstone.kind),
        "target" => tombstone.target,
        "payload_digest" => tombstone.payload_digest,
        "due_at" => tombstone.due_at,
        "generation" => tombstone.generation,
        "state" => Atom.to_string(tombstone.state),
        "outcome_digest" => tombstone.outcome_digest,
        "result_revision" => tombstone.result_revision,
        "retention_class" => Atom.to_string(tombstone.retention_class)
      }

      if is_nil(tombstone.key), do: base, else: Map.put(base, "key", tombstone.key)
    end

    defp identity_attrs(attrs) do
      identity_attrs = %{
        identity_version: Diagnostic.fetch(attrs, :identity_version),
        session_incarnation: Diagnostic.fetch(attrs, :session_incarnation),
        kind: Diagnostic.fetch(attrs, :kind),
        target: Diagnostic.fetch(attrs, :target),
        payload_digest: Diagnostic.fetch(attrs, :payload_digest),
        due_at: Diagnostic.fetch(attrs, :due_at),
        generation: Diagnostic.fetch(attrs, :generation)
      }

      with {:ok, _id} <- Operation.identity(identity_attrs),
           {:ok, kind} <- operation_kind(identity_attrs.kind) do
        {:ok,
         %{
           identity_version: identity_attrs.identity_version,
           session_incarnation: identity_attrs.session_incarnation,
           kind: kind,
           target: identity_attrs.target,
           payload_digest: identity_attrs.payload_digest,
           due_at: identity_attrs.due_at,
           generation: identity_attrs.generation
         }}
      end
    end

    defp operation_kind(value)
         when value in [:send, :timer, :invoke, :cancel, :child_start, :child_stop],
         do: {:ok, value}

    defp operation_kind(value) when is_binary(value) do
      case value do
        "send" -> {:ok, :send}
        "timer" -> {:ok, :timer}
        "invoke" -> {:ok, :invoke}
        "cancel" -> {:ok, :cancel}
        "child_start" -> {:ok, :child_start}
        "child_stop" -> {:ok, :child_stop}
        _other -> {:error, Diagnostic.new(:invalid_tombstone, "operation kind is invalid")}
      end
    end

    defp operation_kind(_value),
      do: {:error, Diagnostic.new(:invalid_tombstone, "operation kind is invalid")}

    defp retention_class(value) when value in [:terminal, :audit], do: {:ok, value}

    defp retention_class(value) when is_binary(value) do
      case value do
        "terminal" -> {:ok, :terminal}
        "audit" -> {:ok, :audit}
        _ -> {:error, Diagnostic.new(:invalid_tombstone, "tombstone retention is invalid")}
      end
    end

    defp retention_class(_value),
      do: {:error, Diagnostic.new(:invalid_tombstone, "tombstone retention is invalid")}

    defp terminal_state(value) when value in [:confirmed_complete, :permanent_failure, :canceled],
      do: {:ok, value}

    defp terminal_state(value) when is_binary(value) do
      case Enum.find(
             [:confirmed_complete, :permanent_failure, :canceled],
             &(Atom.to_string(&1) == value)
           ) do
        nil -> {:error, Diagnostic.new(:invalid_tombstone, "tombstone state is invalid")}
        state -> {:ok, state}
      end
    end

    defp terminal_state(_value),
      do: {:error, Diagnostic.new(:invalid_tombstone, "tombstone state is invalid")}
  end

  defstruct schema_version: @schema_version,
            runtime_protocol_version: @runtime_protocol_version,
            profile_version: Profile.version(),
            data_model_version: @data_model_version,
            registry_version: nil,
            limits_version: @limits_version,
            id: nil,
            incarnation: nil,
            chart_fingerprint: nil,
            registry_digest: nil,
            limits_digest: nil,
            invocation_ancestry: [],
            invocation_depth: 0,
            invocation_remaining_descendants: nil,
            invocation_descendants_used: 0,
            status: :new,
            revision: 0,
            revision_fence: 0,
            generated_id_counter: 0,
            operation_counter: 0,
            operation_high_water: %{},
            received_operation_ids: [],
            initialized_data_state_ids: [],
            configuration: [],
            history: %{},
            data: %{},
            internal_queue: [],
            operations: %{},
            operation_tombstones: %{},
            completion_data: nil,
            trace: []

  @type t :: %__MODULE__{}

  @doc "Returns the execution-contract versions stored with every session."
  @spec contract_versions() :: map()
  def contract_versions do
    %{
      schema_version: @schema_version,
      runtime_protocol_version: @runtime_protocol_version,
      profile_version: Profile.version(),
      data_model_version: @data_model_version,
      limits_version: @limits_version
    }
  end

  @doc "Builds and validates a portable session."
  @spec new(map()) :: {:ok, t()} | {:error, Diagnostic.t()}
  def new(%__MODULE__{} = session), do: session |> Map.from_struct() |> parse(false)
  def new(attrs) when is_map(attrs), do: parse(attrs, false)

  def new(_attrs),
    do: {:error, Diagnostic.new(:invalid_session, "session must be a map", path: [:session])}

  @doc "Loads a stored session and requires every execution-contract version."
  @spec load(map()) :: {:ok, t()} | {:error, Diagnostic.t()}
  def load(attrs) when is_map(attrs), do: parse(attrs, true)

  def load(_attrs),
    do:
      {:error, Diagnostic.new(:invalid_session, "stored session must be a map", path: [:session])}

  defp parse(attrs, strict?) do
    with :ok <- Diagnostic.validate_fields(attrs, @fields, [:session]),
         :ok <- required_versions(attrs, strict?),
         {:ok, id} <- required_id(attrs, :id),
         {:ok, incarnation} <- required_id(attrs, :incarnation),
         {:ok, chart_fingerprint} <- digest(attrs, :chart_fingerprint),
         {:ok, registry_digest} <- digest(attrs, :registry_digest),
         {:ok, limits_digest} <- digest(attrs, :limits_digest),
         :ok <- required_stored_field(attrs, :invocation_ancestry, strict?),
         {:ok, invocation_ancestry} <-
           invocation_ancestry(
             Diagnostic.fetch(attrs, :invocation_ancestry, [chart_fingerprint]),
             chart_fingerprint
           ),
         :ok <- required_stored_field(attrs, :invocation_depth, strict?),
         {:ok, invocation_depth} <-
           invocation_depth(
             Diagnostic.fetch(attrs, :invocation_depth, length(invocation_ancestry) - 1),
             invocation_ancestry
           ),
         :ok <- required_stored_field(attrs, :invocation_remaining_descendants, strict?),
         {:ok, invocation_remaining_descendants} <-
           invocation_remaining_descendants(
             Diagnostic.fetch(attrs, :invocation_remaining_descendants)
           ),
         :ok <- required_stored_field(attrs, :invocation_descendants_used, strict?),
         {:ok, invocation_descendants_used} <-
           nonnegative(attrs, :invocation_descendants_used, 0),
         {:ok, status} <- status(Diagnostic.fetch(attrs, :status, :new)),
         {:ok, revision} <- nonnegative(attrs, :revision, 0),
         {:ok, revision_fence} <- nonnegative(attrs, :revision_fence, 0),
         :ok <- required_counter(attrs, :generated_id_counter, strict?),
         {:ok, generated_id_counter} <- nonnegative(attrs, :generated_id_counter, 0),
         :ok <- required_counter(attrs, :operation_counter, strict?),
         {:ok, operation_counter} <- nonnegative(attrs, :operation_counter, 0),
         :ok <- required_stored_field(attrs, :operation_high_water, strict?),
         {:ok, operation_high_water} <-
           operation_high_water(Diagnostic.fetch(attrs, :operation_high_water, %{})),
         :ok <- required_stored_field(attrs, :received_operation_ids, strict?),
         {:ok, received_operation_ids} <-
           ids(Diagnostic.fetch(attrs, :received_operation_ids, []), :received_operation_ids),
         :ok <- unique_ids(received_operation_ids, :received_operation_ids),
         :ok <- required_ids(attrs, :initialized_data_state_ids, strict?),
         {:ok, initialized_data_state_ids} <-
           ids(
             Diagnostic.fetch(attrs, :initialized_data_state_ids, []),
             :initialized_data_state_ids
           ),
         :ok <- unique_ids(initialized_data_state_ids, :initialized_data_state_ids),
         {:ok, configuration} <- ids(Diagnostic.fetch(attrs, :configuration, []), :configuration),
         {:ok, history} <- history(Diagnostic.fetch(attrs, :history, %{})),
         {:ok, data} <- portable_map(Diagnostic.fetch(attrs, :data, %{}), :data),
         {:ok, internal_queue} <-
           portable_list(Diagnostic.fetch(attrs, :internal_queue, []), :internal_queue),
         {:ok, operations} <- operations(Diagnostic.fetch(attrs, :operations, %{}), strict?),
         {:ok, tombstones} <- tombstones(Diagnostic.fetch(attrs, :operation_tombstones, %{})),
         :ok <- disjoint_operations(operations, tombstones),
         :ok <- operation_incarnations(operations, tombstones, incarnation),
         :ok <- validate_operation_high_water(operation_high_water, operations, tombstones),
         :ok <- validate_received_operations(received_operation_ids, operations),
         :ok <-
           ledger_fences(
             revision,
             revision_fence,
             operation_counter,
             operation_high_water,
             operations,
             tombstones
           ),
         {:ok, completion_data} <-
           portable(Diagnostic.fetch(attrs, :completion_data), :completion_data),
         {:ok, trace} <- portable_list(Diagnostic.fetch(attrs, :trace, []), :trace),
         {:ok, versions} <- versions(attrs) do
      {:ok,
       struct!(
         __MODULE__,
         Map.merge(versions, %{
           id: id,
           incarnation: incarnation,
           chart_fingerprint: chart_fingerprint,
           registry_digest: registry_digest,
           limits_digest: limits_digest,
           invocation_ancestry: invocation_ancestry,
           invocation_depth: invocation_depth,
           invocation_remaining_descendants: invocation_remaining_descendants,
           invocation_descendants_used: invocation_descendants_used,
           status: status,
           revision: revision,
           revision_fence: revision_fence,
           generated_id_counter: generated_id_counter,
           operation_counter: operation_counter,
           operation_high_water: operation_high_water,
           received_operation_ids: received_operation_ids,
           initialized_data_state_ids: initialized_data_state_ids,
           configuration: configuration,
           history: history,
           data: data,
           internal_queue: internal_queue,
           operations: operations,
           operation_tombstones: tombstones,
           completion_data: completion_data,
           trace: trace
         })
       )}
    end
  end

  @spec new!(map()) :: t()
  def new!(attrs), do: attrs |> new() |> Diagnostic.unwrap!()

  @doc "Returns the reserved prefix for processor-generated SCXML identifiers."
  @spec generated_id_prefix() :: String.t()
  def generated_id_prefix, do: @generated_id_prefix

  @doc "Builds one session-unique SCXML send ID, separate from transport operation IDs."
  @spec generated_send_id(String.t(), String.t(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, Diagnostic.t()}
  def generated_send_id(session_id, incarnation, counter) do
    with :ok <- Diagnostic.validate_id(session_id, [:session, :id]),
         :ok <- Diagnostic.validate_id(incarnation, [:session, :incarnation]),
         true <- is_integer(counter) and counter >= 0 do
      identity = %{
        "kind" => "send",
        "session_id" => session_id,
        "incarnation" => incarnation
      }

      {:ok, "#{@generated_id_prefix}send_#{Diagnostic.digest(identity)}_#{counter}"}
    else
      false ->
        {:error,
         Diagnostic.new(:invalid_session_counter, "session counter is invalid",
           path: [:session, :generated_id_counter]
         )}

      {:error, _diagnostic} = error ->
        error
    end
  end

  @doc "Checks the Registry, limits, and profile contracts for execution or restore."
  @spec validate_contract(t(), Registry.t(), Limits.t()) :: :ok | {:error, Diagnostic.t()}
  def validate_contract(%__MODULE__{} = session, %Registry{} = registry, %Limits{} = limits) do
    with {:ok, limits} <- Limits.new(Map.from_struct(limits)) do
      validate_contract_values(session, registry, limits)
    end
  end

  @doc "Validates all committed session resource limits."
  @spec validate_limits(t(), Limits.t()) :: :ok | {:error, Diagnostic.t()}
  def validate_limits(%__MODULE__{} = session, %Limits{} = limits) do
    pending = Enum.reject(Map.values(session.operations), &Operation.terminal?/1)

    terminal =
      Enum.count(session.operations, fn {_id, operation} -> Operation.terminal?(operation) end)

    with :ok <-
           maximum(
             session.invocation_depth,
             limits.invocation_depth,
             :invocation_depth_exceeded,
             "Invocation depth limit was reached"
           ),
         :ok <-
           maximum(
             session.invocation_remaining_descendants || limits.total_descendants,
             limits.total_descendants,
             :invocation_descendant_limit_exceeded,
             "Invocation descendant budget exceeds its limit"
           ),
         :ok <-
           maximum(
             session.invocation_descendants_used,
             session.invocation_remaining_descendants || limits.total_descendants,
             :invocation_descendant_limit_exceeded,
             "Invocation descendant budget was exhausted"
           ),
         :ok <-
           maximum(
             length(session.internal_queue),
             limits.internal_queue_events,
             :internal_queue_limit_exceeded,
             "Internal event queue limit was reached"
           ),
         :ok <-
           maximum(
             length(session.trace),
             limits.trace_entries,
             :trace_limit_exceeded,
             "Trace entry limit was reached"
           ),
         :ok <-
           maximum(
             count_kinds(pending, [:send, :cancel]),
             limits.pending_sends,
             :pending_send_limit_exceeded,
             "Pending send limit was reached"
           ),
         :ok <-
           maximum(
             count_kinds(pending, [:timer]),
             limits.pending_timers,
             :pending_timer_limit_exceeded,
             "Pending timer limit was reached"
           ),
         :ok <-
           maximum(
             count_kinds(pending, [:invoke, :child_start, :child_stop]),
             limits.pending_invocations,
             :pending_invocation_limit_exceeded,
             "Pending invocation limit was reached"
           ),
         :ok <-
           maximum(
             terminal + map_size(session.operation_tombstones),
             limits.terminal_records,
             :terminal_record_limit_exceeded,
             "Terminal operation record limit was reached"
           ),
         :ok <-
           maximum(
             length(session.received_operation_ids),
             limits.pending_sends + limits.pending_timers,
             :receiver_receipt_limit_exceeded,
             "Receiver receipt limit was reached"
           ),
         :ok <-
           maximum(
             map_size(session.operation_high_water),
             limits.pending_sends + limits.pending_timers + limits.terminal_records,
             :operation_high_water_limit_exceeded,
             "Operation generation high-water limit was reached"
           ),
         :ok <- session_size(session, limits.session_bytes) do
      :ok
    end
  end

  defp count_kinds(operations, kinds), do: Enum.count(operations, &(&1.kind in kinds))

  defp maximum(actual, maximum, _code, _message) when actual <= maximum, do: :ok

  defp maximum(actual, maximum, code, message) do
    {:error,
     Diagnostic.new(code, message, correction: %{"actual" => actual, "maximum" => maximum})}
  end

  defp session_size(session, maximum) do
    bytes = session |> dump() |> :erlang.term_to_binary([:deterministic]) |> byte_size()

    if bytes <= maximum do
      :ok
    else
      {:error,
       Diagnostic.new(:session_size_limit_exceeded, "Session exceeds the configured byte limit",
         path: [:session],
         correction: %{"actual_bytes" => bytes, "maximum_bytes" => maximum}
       )}
    end
  end

  defp validate_contract_values(session, registry, limits) do
    cond do
      session.profile_version != Profile.version() ->
        {:error,
         Diagnostic.new(:profile_version_mismatch, "session profile version does not match")}

      session.runtime_protocol_version != @runtime_protocol_version ->
        {:error,
         Diagnostic.new(
           :runtime_protocol_version_mismatch,
           "session runtime protocol is not supported"
         )}

      session.data_model_version != @data_model_version ->
        {:error,
         Diagnostic.new(
           :data_model_version_mismatch,
           "session data-model version is not supported"
         )}

      session.registry_version != registry.version ->
        {:error,
         Diagnostic.new(:registry_version_mismatch, "session Registry version does not match")}

      session.registry_digest != registry.digest ->
        {:error,
         Diagnostic.new(:registry_digest_mismatch, "session Registry digest does not match")}

      session.limits_digest != Limits.digest(limits) ->
        {:error, Diagnostic.new(:limits_digest_mismatch, "session limits digest does not match")}

      session.limits_version != @limits_version ->
        {:error,
         Diagnostic.new(:limits_version_mismatch, "session limits version is not supported")}

      true ->
        :ok
    end
  end

  @doc "Applies one correlated operation result with generation and terminal fences."
  @spec apply_operation_result(
          t(),
          String.t(),
          non_neg_integer(),
          atom(),
          term(),
          non_neg_integer()
        ) ::
          {:ok, t(), :applied | :duplicate | :stale} | {:error, Diagnostic.t()}
  def apply_operation_result(session, id, generation, state, result, result_revision)
      when is_integer(generation) and is_integer(result_revision) and result_revision >= 0 do
    with :ok <- Diagnostic.portable(result, [:operation, :result]),
         {:ok, state} <- result_state(state) do
      case Map.fetch(session.operations, id) do
        {:ok, operation} ->
          apply_to_operation(session, operation, generation, state, result, result_revision)

        :error ->
          apply_to_tombstone(session, id, generation, state, result)
      end
    end
  end

  def apply_operation_result(_session, _id, _generation, _state, _result, _revision),
    do: {:error, Diagnostic.new(:invalid_operation_result, "operation result is invalid")}

  @doc "Bounds terminal operations and tombstones while preserving active work."
  @spec collect_terminal(t(), non_neg_integer()) :: t()
  def collect_terminal(%__MODULE__{} = session, keep)
      when is_integer(keep) and keep >= 0 do
    active_operations =
      Map.reject(session.operations, fn {_id, operation} -> Operation.terminal?(operation) end)

    terminal_records =
      Enum.map(session.operations, fn {_id, operation} ->
        if Operation.terminal?(operation), do: Tombstone.from_operation(operation)
      end)
      |> Enum.reject(&is_nil/1)
      |> Kernel.++(Map.values(session.operation_tombstones))
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(
        fn tombstone ->
          priority = if tombstone.retention_class == :audit, do: 1, else: 0
          {priority, tombstone.result_revision, tombstone.id}
        end,
        :desc
      )
      |> Enum.take(keep)
      |> Map.new(&{&1.id, &1})

    high_water =
      (Map.values(session.operations) ++ Map.values(session.operation_tombstones))
      |> Enum.reduce(session.operation_high_water, fn record, acc ->
        if is_binary(record.key) do
          Map.update(acc, record.key, record.generation, &max(&1, record.generation))
        else
          acc
        end
      end)

    received_ids =
      Enum.filter(session.received_operation_ids, &Map.has_key?(active_operations, &1))

    %{
      session
      | operations: active_operations,
        operation_tombstones: terminal_records,
        operation_high_water: high_water,
        received_operation_ids: received_ids
    }
  end

  @doc "Returns the portable stored form of a session."
  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = session) do
    session
    |> Map.from_struct()
    |> Map.new(fn
      {:operations, operations} ->
        {"operations",
         Map.new(operations, fn {id, operation} -> {id, Operation.dump(operation)} end)}

      {:operation_tombstones, tombstones} ->
        {"operation_tombstones",
         Map.new(tombstones, fn {id, value} -> {id, Tombstone.dump(value)} end)}

      {key, value} ->
        {Atom.to_string(key),
         if(is_atom(value) and value not in [nil, true, false],
           do: Atom.to_string(value),
           else: value
         )}
    end)
  end

  defp apply_to_operation(session, operation, generation, state, result, revision) do
    cond do
      generation < operation.generation ->
        {:ok, session, :stale}

      generation > operation.generation ->
        operation_error(:operation_generation_mismatch, "operation generation does not match")

      Operation.terminal?(operation) ->
        compare_terminal(session, Operation.outcome_digest(operation), state, result)

      not is_nil(operation.result_revision) and revision <= operation.result_revision ->
        {:ok, session, :stale}

      not legal_result_transition?(operation.state, state) ->
        operation_error(:invalid_operation_transition, "operation result transition is invalid")

      true ->
        retention_class =
          if state in [:confirmed_complete, :permanent_failure, :canceled] do
            if operation.retention_class == :audit, do: :audit, else: :terminal
          else
            :active
          end

        updated = %{
          operation
          | state: state,
            result: result,
            result_revision: revision,
            attempt_count: max(operation.attempt_count, 1),
            next_attempt_at: next_attempt_at(state, result),
            retention_class: retention_class
        }

        {:ok,
         %{
           session
           | operations: Map.put(session.operations, operation.id, updated),
             revision_fence: max(session.revision_fence, revision)
         }, :applied}
    end
  end

  defp apply_to_tombstone(session, id, generation, state, result) do
    case Map.fetch(session.operation_tombstones, id) do
      {:ok, tombstone} when generation < tombstone.generation ->
        {:ok, session, :stale}

      {:ok, tombstone} when generation == tombstone.generation ->
        compare_terminal(session, tombstone.outcome_digest, state, result)

      {:ok, _tombstone} ->
        operation_error(
          :operation_generation_mismatch,
          "collected operation generation does not match"
        )

      :error ->
        operation_error(:unknown_operation, "operation result has no matching operation")
    end
  end

  defp compare_terminal(session, existing_digest, state, result) do
    incoming_digest = Diagnostic.digest(%{"state" => state, "result" => result})

    if existing_digest == incoming_digest do
      {:ok, session, :duplicate}
    else
      operation_error(
        :operation_result_conflict,
        "operation already has a different terminal result"
      )
    end
  end

  defp result_state(state)
       when state in [
              :confirmed_complete,
              :result_unknown,
              :retryable_failure,
              :permanent_failure,
              :canceled
            ],
       do: {:ok, state}

  defp result_state(state) when is_binary(state) do
    case Enum.find(
           [
             :confirmed_complete,
             :result_unknown,
             :retryable_failure,
             :permanent_failure,
             :canceled
           ],
           &(Atom.to_string(&1) == state)
         ) do
      nil -> operation_error(:invalid_operation_result, "operation result state is invalid")
      known -> {:ok, known}
    end
  end

  defp result_state(_state),
    do: operation_error(:invalid_operation_result, "operation result state is invalid")

  defp next_attempt_at(:retryable_failure, result) when is_map(result),
    do: Map.get(result, "next_attempt_at") || Map.get(result, :next_attempt_at)

  defp next_attempt_at(:result_unknown, result) when is_map(result),
    do: Map.get(result, "next_attempt_at") || Map.get(result, :next_attempt_at)

  defp next_attempt_at(_state, _result), do: nil

  defp legal_result_transition?(from, :canceled), do: from == :cancel_requested

  defp legal_result_transition?(from, _to),
    do: from in [:not_started, :result_unknown, :retryable_failure, :cancel_requested]

  defp operation_error(code, message), do: {:error, Diagnostic.new(code, message)}

  defp required_id(attrs, field) do
    with {:ok, id} <- Diagnostic.require_string(attrs, field, [:session]),
         :ok <- Diagnostic.validate_id(id, [:session, field]),
         do: {:ok, id}
  end

  defp digest(attrs, field) do
    value = Diagnostic.fetch(attrs, field)

    if is_binary(value) and Regex.match?(~r/^[0-9a-f]{64}$/u, value) do
      {:ok, value}
    else
      {:error,
       Diagnostic.new(:invalid_digest, "session digest must be lowercase SHA-256 text",
         path: [:session, field]
       )}
    end
  end

  defp status(value) when value in @statuses, do: {:ok, value}

  defp status(value) when is_binary(value) do
    case Enum.find(@statuses, &(Atom.to_string(&1) == value)) do
      nil -> {:error, Diagnostic.new(:invalid_session_status, "session status is invalid")}
      known -> {:ok, known}
    end
  end

  defp status(_value),
    do: {:error, Diagnostic.new(:invalid_session_status, "session status is invalid")}

  defp nonnegative(attrs, field, default) do
    value = Diagnostic.fetch(attrs, field, default)

    if is_integer(value) and value >= 0,
      do: {:ok, value},
      else:
        {:error,
         Diagnostic.new(:invalid_session_counter, "session counter is invalid",
           path: [:session, field]
         )}
  end

  defp required_counter(attrs, field, true) do
    if Diagnostic.fetch(attrs, field, :missing) == :missing do
      {:error,
       Diagnostic.new(:missing_session_counter, "stored session counter is missing",
         path: [:session, field]
       )}
    else
      :ok
    end
  end

  defp required_counter(_attrs, _field, false), do: :ok

  defp required_ids(attrs, field, true) do
    if Diagnostic.fetch(attrs, field, :missing) == :missing do
      {:error,
       Diagnostic.new(:missing_session_field, "stored session field is missing",
         path: [:session, field]
       )}
    else
      :ok
    end
  end

  defp required_ids(_attrs, _field, false), do: :ok

  defp ids(values, field) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      case Diagnostic.validate_id(value, [:session, field, index]) do
        :ok -> {:cont, {:ok, [value | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, result} -> {:ok, Enum.reverse(result)}
      error -> error
    end)
  end

  defp ids(_values, field),
    do:
      {:error,
       Diagnostic.new(:invalid_session_ids, "session identifiers must be a list",
         path: [:session, field]
       )}

  defp unique_ids(ids, field) do
    if length(ids) == length(Enum.uniq(ids)) do
      :ok
    else
      {:error,
       Diagnostic.new(:duplicate_session_id, "session identifier list has a duplicate",
         path: [:session, field]
       )}
    end
  end

  defp invocation_ancestry(values, chart_fingerprint) when is_list(values) and values != [] do
    valid? =
      Enum.all?(values, fn value ->
        is_binary(value) and Regex.match?(~r/^[0-9a-f]{64}$/u, value)
      end)

    if valid? and Enum.uniq(values) == values and List.last(values) == chart_fingerprint do
      {:ok, values}
    else
      invalid_invocation_context(:invocation_ancestry)
    end
  end

  defp invocation_ancestry(_values, _chart_fingerprint),
    do: invalid_invocation_context(:invocation_ancestry)

  defp invocation_depth(value, ancestry)
       when is_integer(value) and value >= 0 and value == length(ancestry) - 1,
       do: {:ok, value}

  defp invocation_depth(_value, _ancestry),
    do: invalid_invocation_context(:invocation_depth)

  defp invocation_remaining_descendants(nil), do: {:ok, nil}

  defp invocation_remaining_descendants(value) when is_integer(value) and value >= 0,
    do: {:ok, value}

  defp invocation_remaining_descendants(_value),
    do: invalid_invocation_context(:invocation_remaining_descendants)

  defp invalid_invocation_context(field) do
    {:error,
     Diagnostic.new(:invalid_invocation_context, "Session invocation context is invalid",
       path: [:session, field]
     )}
  end

  defp history(value) when is_map(value) and not is_struct(value) do
    value
    |> Enum.reduce_while({:ok, %{}}, fn {key, ids_value}, {:ok, acc} ->
      with :ok <- Diagnostic.validate_id(key, [:session, :history, :key]),
           {:ok, ids_value} <- ids(ids_value, :history) do
        {:cont, {:ok, Map.put(acc, key, ids_value)}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp history(_value),
    do: {:error, Diagnostic.new(:invalid_history, "session history must be a map")}

  defp portable(value, field) do
    with :ok <- Diagnostic.portable(value, [:session, field]), do: {:ok, value}
  end

  defp portable_map(value, field) when is_map(value) and not is_struct(value),
    do: portable(value, field)

  defp portable_map(_value, field),
    do:
      {:error,
       Diagnostic.new(:non_portable_value, "session field must be a map", path: [:session, field])}

  defp portable_list(value, field) when is_list(value), do: portable(value, field)

  defp portable_list(_value, field),
    do:
      {:error,
       Diagnostic.new(:non_portable_value, "session field must be a list",
         path: [:session, field]
       )}

  defp operations(value, strict?) when is_map(value) and not is_struct(value) do
    parser = if strict?, do: &Operation.load/1, else: &Operation.new/1
    keyed_values(value, parser, :operations)
  end

  defp operations(_value, _strict?),
    do: {:error, Diagnostic.new(:invalid_operations, "operations must be a map")}

  defp tombstones(value) when is_map(value) and not is_struct(value),
    do: keyed_values(value, &Tombstone.new/1, :operation_tombstones)

  defp tombstones(_value),
    do: {:error, Diagnostic.new(:invalid_tombstones, "operation tombstones must be a map")}

  defp keyed_values(values, parser, field) do
    Enum.reduce_while(values, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case parser.(value) do
        {:ok, %{id: ^key} = parsed} ->
          {:cont, {:ok, Map.put(acc, key, parsed)}}

        {:ok, _parsed} ->
          {:halt,
           {:error,
            Diagnostic.new(:operation_key_mismatch, "operation map key does not match its ID",
              path: [:session, field, key]
            )}}

        {:error, diagnostic} ->
          {:halt, {:error, Diagnostic.prefix(diagnostic, [:session, field, key])}}
      end
    end)
  end

  defp disjoint_operations(operations, tombstones) do
    case Map.keys(operations) |> Enum.find(&Map.has_key?(tombstones, &1)) do
      nil ->
        :ok

      id ->
        {:error,
         Diagnostic.new(
           :operation_fence_conflict,
           "operation exists as an active record and tombstone",
           path: [:session, :operations, id]
         )}
    end
  end

  defp operation_incarnations(operations, tombstones, incarnation) do
    case Enum.find(Map.values(operations) ++ Map.values(tombstones), fn value ->
           value.session_incarnation != incarnation
         end) do
      nil ->
        :ok

      value ->
        {:error,
         Diagnostic.new(
           :operation_incarnation_mismatch,
           "operation belongs to another session incarnation",
           path: [:session, :operations, value.id]
         )}
    end
  end

  defp operation_high_water(value) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, generation}, {:ok, acc} ->
      if is_binary(key) and key != "" and String.valid?(key) and is_integer(generation) and
           generation >= 0 do
        {:cont, {:ok, Map.put(acc, key, generation)}}
      else
        {:halt,
         {:error,
          Diagnostic.new(
            :invalid_operation_high_water,
            "Operation generation high-water map is invalid",
            path: [:session, :operation_high_water]
          )}}
      end
    end)
  end

  defp operation_high_water(_value) do
    {:error,
     Diagnostic.new(
       :invalid_operation_high_water,
       "Operation generation high-water map is invalid",
       path: [:session, :operation_high_water]
     )}
  end

  defp validate_operation_high_water(high_water, operations, tombstones) do
    records = Map.values(operations) ++ Map.values(tombstones)

    case Enum.find(records, fn record ->
           is_binary(record.key) and Map.get(high_water, record.key, -1) < record.generation
         end) do
      nil ->
        :ok

      record ->
        {:error,
         Diagnostic.new(
           :invalid_operation_high_water,
           "Operation generation exceeds its keyed high-water mark",
           path: [:session, :operation_high_water, record.key]
         )}
    end
  end

  defp validate_received_operations(received_ids, operations) do
    case Enum.find(received_ids, fn id ->
           case Map.get(operations, id) do
             %Operation{kind: kind, target: target} ->
               kind not in [:send, :timer] or target not in ["self", "#_self"]

             _other ->
               true
           end
         end) do
      nil ->
        :ok

      id ->
        {:error,
         Diagnostic.new(
           :invalid_receiver_receipt,
           "Receiver receipt has no matching self-delivery operation",
           path: [:session, :received_operation_ids, id]
         )}
    end
  end

  defp ledger_fences(
         revision,
         revision_fence,
         operation_counter,
         operation_high_water,
         operations,
         tombstones
       ) do
    cond do
      revision_fence < revision ->
        {:error,
         Diagnostic.new(
           :invalid_revision_fence,
           "Session revision fence must include the current revision",
           path: [:session, :revision_fence]
         )}

      operation =
          Enum.find(Map.values(operations), fn operation ->
            operation.generation >= operation_counter or
              operation.created_revision > revision_fence or
                (is_integer(operation.result_revision) and
                   operation.result_revision > revision_fence)
          end) ->
        {:error,
         Diagnostic.new(
           :invalid_operation_fence,
           "Operation generation or revision exceeds its session fence",
           path: [:session, :operations, operation.id]
         )}

      tombstone =
          Enum.find(Map.values(tombstones), fn tombstone ->
            tombstone.generation >= operation_counter or
                tombstone.result_revision > revision_fence
          end) ->
        {:error,
         Diagnostic.new(
           :invalid_operation_fence,
           "Operation tombstone exceeds its session fence",
           path: [:session, :operation_tombstones, tombstone.id]
         )}

      Enum.any?(operation_high_water, fn {_key, generation} -> generation >= operation_counter end) ->
        {:error,
         Diagnostic.new(
           :invalid_operation_fence,
           "Operation high-water generation exceeds its session fence",
           path: [:session, :operation_high_water]
         )}

      true ->
        :ok
    end
  end

  defp required_versions(_attrs, false), do: :ok

  defp required_versions(attrs, true) do
    case Enum.find(@version_fields, fn field ->
           not (Map.has_key?(attrs, field) or Map.has_key?(attrs, Atom.to_string(field)))
         end) do
      nil ->
        case Diagnostic.fetch(attrs, :registry_version) do
          value when is_binary(value) and value != "" ->
            :ok

          _value ->
            {:error,
             Diagnostic.new(:invalid_session_version, "stored Registry version is required",
               path: [:session, :registry_version]
             )}
        end

      field ->
        {:error,
         Diagnostic.new(:missing_session_version, "stored session contract version is required",
           path: [:session, field]
         )}
    end
  end

  defp required_stored_field(_attrs, _field, false), do: :ok

  defp required_stored_field(attrs, field, true) do
    if Map.has_key?(attrs, field) or Map.has_key?(attrs, Atom.to_string(field)) do
      :ok
    else
      {:error,
       Diagnostic.new(:missing_stored_field, "Stored session field is required",
         path: [:session, field]
       )}
    end
  end

  defp versions(attrs) do
    values = %{
      schema_version: Diagnostic.fetch(attrs, :schema_version, @schema_version),
      runtime_protocol_version:
        Diagnostic.fetch(attrs, :runtime_protocol_version, @runtime_protocol_version),
      profile_version: Diagnostic.fetch(attrs, :profile_version, Profile.version()),
      data_model_version: Diagnostic.fetch(attrs, :data_model_version, @data_model_version),
      registry_version: Diagnostic.fetch(attrs, :registry_version),
      limits_version: Diagnostic.fetch(attrs, :limits_version, @limits_version)
    }

    cond do
      values.schema_version != @schema_version ->
        invalid_version(:schema_version)

      values.runtime_protocol_version != @runtime_protocol_version ->
        invalid_version(:runtime_protocol_version)

      values.profile_version != Profile.version() ->
        invalid_version(:profile_version)

      values.data_model_version != @data_model_version ->
        invalid_version(:data_model_version)

      values.limits_version != @limits_version ->
        invalid_version(:limits_version)

      not Enum.all?(
        [values.profile_version, values.data_model_version, values.limits_version],
        &(is_binary(&1) and &1 != "" and String.valid?(&1))
      ) ->
        invalid_version(:contract_version)

      not is_nil(values.registry_version) and
          not (is_binary(values.registry_version) and values.registry_version != "" and
                   String.valid?(values.registry_version)) ->
        invalid_version(:registry_version)

      true ->
        {:ok, values}
    end
  end

  defp invalid_version(field),
    do:
      {:error,
       Diagnostic.new(:invalid_session_version, "session contract version is invalid",
         path: [:session, field]
       )}
end
