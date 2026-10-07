defmodule Jido.Statechart.Expression do
  @moduledoc "Resolves trusted Registry expression identifiers through bounded Jido.Expr values."

  alias Jido.Expr
  alias Jido.Expr.Error, as: ExprError
  alias Jido.Statechart.{DataModel, Diagnostic, Location, Registry}
  alias Jido.Statechart.Registry.Entry

  defmodule Reference do
    @moduledoc "An inert Statechart reference that can be embedded in a Jido.Expr value."

    alias Jido.Statechart.Location

    @enforce_keys [:kind]
    defstruct kind: nil, path: [], state_id: nil

    @type t :: %__MODULE__{
            kind: :data | :system | :binding | :in,
            path: [String.t()],
            state_id: String.t() | nil
          }

    @doc "Builds a reference to a string-keyed data location."
    @spec data(String.t()) :: t()
    def data(location), do: location_reference(:data, location)

    @doc "Builds a reference to a protected system location."
    @spec system(String.t()) :: t()
    def system(location), do: location_reference(:system, location)

    @doc "Builds a reference to one scoped foreach binding."
    @spec binding(String.t()) :: t()
    def binding(location), do: location_reference(:binding, location)

    @doc "Builds the SCXML In(state_id) predicate."
    @spec in_state(String.t()) :: t()
    def in_state(state_id) when is_binary(state_id) and byte_size(state_id) in 1..255 do
      if String.valid?(state_id) and Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_.-]*$/u, state_id),
        do: %__MODULE__{kind: :in, state_id: state_id},
        else: raise(ArgumentError, "invalid Statechart state identifier")
    end

    def in_state(_state_id), do: raise(ArgumentError, "invalid Statechart state identifier")

    defp location_reference(kind, location) do
      case Location.parse(location) do
        {:ok, path} -> %__MODULE__{kind: kind, path: path}
        {:error, _diagnostic} -> raise ArgumentError, "invalid Statechart expression reference"
      end
    end
  end

  @limit_reasons [:max_depth, :max_nodes, :max_binary_bytes, :max_integer_bits]

  @doc "Evaluates one registered expression ID against bounded portable state."
  @spec evaluate(String.t(), map(), keyword()) :: {:ok, term()} | {:error, Diagnostic.t()}
  def evaluate(identifier, environment, options)
      when is_binary(identifier) and is_map(environment) and is_list(options) do
    if Keyword.keyword?(options) do
      with {:ok, registry} <- registry(options),
           {:ok, limits} <- limits(options),
           {:ok, entry} <- registered(registry, identifier),
           :ok <- permission(entry, "evaluate"),
           {:ok, expression} <- expression_value(entry),
           {:ok, value} <- evaluate_value(expression, entry, environment, limits),
           :ok <- DataModel.validate_value(value, [limits: limits], [:expression, identifier]) do
        {:ok, value}
      end
    else
      {:error, Diagnostic.new(:invalid_expression_call, "Expression options are invalid")}
    end
  end

  def evaluate(_identifier, _environment, _options) do
    {:error,
     Diagnostic.new(:invalid_expression_id, "Expression identifier must be a string",
       path: [:expression]
     )}
  end

  defp registry(options) do
    case Keyword.get(options, :registry) do
      %Registry{} = registry -> {:ok, registry}
      _other -> {:error, Diagnostic.new(:invalid_registry, "A trusted Registry is required")}
    end
  end

  defp limits(options) do
    DataModel.limits(options)
  end

  defp registered(registry, identifier) do
    case Registry.fetch(registry, :expression, identifier) do
      {:ok, entry} ->
        {:ok, entry}

      :error ->
        {:error,
         Diagnostic.new(:expression_not_registered, "Expression identifier is not registered",
           path: [:expression, identifier]
         )}
    end
  end

  defp permission(%Entry{permissions: permissions}, required) do
    if required in permissions do
      :ok
    else
      {:error,
       Diagnostic.new(:expression_permission_denied, "Expression permission is not declared",
         path: [:expression],
         correction: %{"required_permission" => required}
       )}
    end
  end

  defp expression_value(%Entry{handler: {:expression, value}}), do: {:ok, value}
  defp expression_value(_entry), do: invalid_handler()

  defp invalid_handler do
    {:error,
     Diagnostic.new(:invalid_expression_handler, "Registered expression handler is invalid",
       path: [:expression]
     )}
  end

  defp evaluate_value(expression, entry, environment, limits) do
    result =
      if limits.data_bytes == 0 do
        {:error, %ExprError{reason: :max_binary_bytes}}
      else
        resolver = fn reference -> resolve(reference, entry, environment) end

        Expr.evaluate(expression,
          resolve: resolver,
          max_nodes: limits.expression_steps,
          max_binary_bytes: limits.data_bytes
        )
      end

    case result do
      {:ok, value} ->
        {:ok, value}

      {:error, %Diagnostic{} = diagnostic} ->
        {:error, diagnostic}

      {:error, %ExprError{reason: reason} = error} when reason in @limit_reasons ->
        {:error,
         Diagnostic.new(:expression_limit_exceeded, "Expression exceeded a configured limit",
           path: [:expression | error.path],
           correction: %{"limit" => Atom.to_string(reason)}
         )}

      {:error, %ExprError{reason: reason}} when reason in [:unsupported_value, :unknown_struct] ->
        {:error,
         Diagnostic.new(:non_portable_value, "Expression produced a non-portable value",
           path: [:expression]
         )}

      {:error, _error} ->
        {:error,
         Diagnostic.new(:expression_failed, "Registered expression evaluation failed",
           path: [:expression]
         )}
    end
  end

  defp resolve(%Reference{kind: :data, path: path}, entry, environment) do
    with :ok <- permission(entry, "read:data") do
      environment |> Map.get(:data, %{}) |> Location.fetch(path)
    end
  end

  defp resolve(%Reference{kind: :system, path: path}, entry, environment) do
    with :ok <- permission(entry, "read:system") do
      environment |> Map.get(:system, %{}) |> Location.fetch(path)
    end
  end

  defp resolve(%Reference{kind: :binding, path: path}, entry, environment) do
    with :ok <- permission(entry, "read:bindings") do
      environment |> Map.get(:bindings, %{}) |> Location.fetch(path)
    end
  end

  defp resolve(%Reference{kind: :in, state_id: state_id}, entry, environment) do
    with :ok <- permission(entry, "read:configuration") do
      {:ok, state_id in Map.get(environment, :active_state_ids, [])}
    end
  end

  defp resolve(_reference, _entry, _environment) do
    {:error,
     Diagnostic.new(:invalid_expression_reference, "Expression reference is not supported",
       path: [:expression]
     )}
  end
end
