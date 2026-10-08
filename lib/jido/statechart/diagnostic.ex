defmodule Jido.Statechart.Diagnostic do
  @moduledoc """
  A stable, portable diagnostic for authoring and runtime contract failures.

  A diagnostic contains a package-owned code. Untrusted input stays in bounded
  string values and never becomes an atom or module name.
  """

  @severities [:error, :warning, :info]

  @enforce_keys [:code, :message]
  defstruct code: nil,
            severity: :error,
            message: nil,
            path: [],
            location: nil,
            profile_feature: nil,
            correction: %{}

  @type t :: %__MODULE__{
          code: atom(),
          severity: :error | :warning | :info,
          message: String.t(),
          path: [term()],
          location: map() | nil,
          profile_feature: String.t() | nil,
          correction: map()
        }

  @doc "Builds a package diagnostic."
  @spec new(atom(), String.t(), keyword() | map()) :: t()
  def new(code, message, opts \\ []) when is_atom(code) and is_binary(message) do
    opts = Map.new(opts)
    severity = Map.get(opts, :severity, :error)

    %__MODULE__{
      code: code,
      severity: if(severity in @severities, do: severity, else: :error),
      message: message,
      path: Map.get(opts, :path, []),
      location: Map.get(opts, :location),
      profile_feature: Map.get(opts, :profile_feature),
      correction: Map.get(opts, :correction, %{})
    }
  end

  @doc false
  @spec prefix(t(), [term()]) :: t()
  def prefix(%__MODULE__{} = diagnostic, prefix) when is_list(prefix) do
    %{diagnostic | path: prefix ++ diagnostic.path}
  end

  @doc false
  @spec unwrap!({:ok, term()} | {:error, t()}) :: term() | no_return()
  def unwrap!({:ok, value}), do: value

  def unwrap!({:error, %__MODULE__{} = diagnostic}) do
    raise ArgumentError, "#{diagnostic.code}: #{diagnostic.message}"
  end

  @doc false
  @spec fetch(map(), atom(), term()) :: term()
  def fetch(attrs, key, default \\ nil) when is_map(attrs) and is_atom(key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(key), default)
    end
  end

  @doc false
  @spec validate_fields(map(), [atom()], [term()]) :: :ok | {:error, t()}
  def validate_fields(attrs, fields, path) when is_map(attrs) and is_list(fields) do
    allowed =
      fields
      |> Enum.flat_map(&[&1, Atom.to_string(&1)])
      |> then(&MapSet.new([:__struct__ | &1]))

    case Enum.find(Map.keys(attrs), &(not MapSet.member?(allowed, &1))) do
      nil ->
        case Enum.find(fields, fn field ->
               Map.has_key?(attrs, field) and Map.has_key?(attrs, Atom.to_string(field))
             end) do
          nil ->
            :ok

          field ->
            {:error,
             new(:duplicate_field, "field is present in atom and string form",
               path: path ++ [field]
             )}
        end

      key ->
        {:error, new(:unknown_field, "value contains an unknown field", path: path ++ [key])}
    end
  end

  @doc false
  @spec require_string(term(), atom(), [term()]) :: {:ok, String.t()} | {:error, t()}
  def require_string(attrs, key, path \\ []) do
    value = fetch(attrs, key)

    if is_binary(value) and value != "" and String.valid?(value) do
      {:ok, value}
    else
      {:error,
       new(:invalid_string, "#{key} must be a nonempty UTF-8 string", path: path ++ [key])}
    end
  end

  @doc false
  @spec optional_string(term(), atom(), [term()]) :: {:ok, String.t() | nil} | {:error, t()}
  def optional_string(attrs, key, path \\ []) do
    case fetch(attrs, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) and value != "" ->
        if String.valid?(value),
          do: {:ok, value},
          else: {:error, new(:invalid_string, "#{key} must be UTF-8", path: path ++ [key])}

      _ ->
        {:error,
         new(:invalid_string, "#{key} must be nil or a nonempty UTF-8 string",
           path: path ++ [key]
         )}
    end
  end

  @doc false
  @spec validate_id(term(), [term()]) :: :ok | {:error, t()}
  def validate_id(value, path) when is_binary(value) and byte_size(value) in 1..255 do
    if String.valid?(value) and Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_.-]*$/u, value) do
      :ok
    else
      {:error, new(:invalid_id, "identifier is not legal", path: path)}
    end
  end

  def validate_id(_value, path),
    do: {:error, new(:invalid_id, "identifier must be 1 to 255 bytes", path: path)}

  @doc false
  @spec portable(term(), [term()]) :: :ok | {:error, t()}
  def portable(value, path \\ []) do
    case Jido.PortableTerm.validate(value, path) do
      :ok ->
        valid_utf8(value, path)

      {:error, invalid_path} ->
        {:error,
         new(:non_portable_value, "value is not portable", path: normalize_path(invalid_path))}
    end
  end

  @doc false
  @spec digest(term()) :: String.t()
  def digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp valid_utf8(value, path) when is_binary(value) do
    if String.valid?(value),
      do: :ok,
      else: {:error, new(:non_portable_value, "string is not UTF-8", path: path)}
  end

  defp valid_utf8(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {item, index}, :ok ->
      case valid_utf8(item, path ++ [index]) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp valid_utf8(value, path) when is_tuple(value),
    do: valid_utf8(Tuple.to_list(value), path)

  defp valid_utf8(value, path) when is_map(value) do
    value
    |> Map.to_list()
    |> Enum.reduce_while(:ok, fn {key, item}, :ok ->
      with :ok <- valid_utf8(key, path ++ [:key]),
           :ok <- valid_utf8(item, path ++ [key]) do
        {:cont, :ok}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp valid_utf8(_value, _path), do: :ok

  defp normalize_path(path) when is_list(path), do: path
  defp normalize_path(path), do: [path]
end
