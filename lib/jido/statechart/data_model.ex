defmodule Jido.Statechart.DataModel do
  @moduledoc "The bounded contract implemented by Statechart data models."

  alias Jido.Statechart.{Diagnostic, Limits}

  @protected_system_variables ~w(_event _sessionid _name _ioprocessors _x)

  @type environment :: map()
  @type options :: keyword()
  @type result(value) :: {:ok, value} | {:error, Diagnostic.t()}

  @callback capabilities() :: map()
  @callback initialize(map(), environment(), options()) :: result(map())
  @callback condition(String.t(), environment(), options()) :: result(boolean())
  @callback value(String.t(), environment(), options()) :: result(term())
  @callback assign(String.t(), term(), map(), options()) :: result(map())
  @callback iterate(String.t(), environment(), options()) :: result([{term(), term()}])
  @callback protected?(String.t()) :: boolean()
  @callback content(map(), environment(), options()) :: result(term())
  @callback construct(map(), environment(), options()) :: result(term())

  @doc "Returns the fixed SCXML system variables that authored content cannot assign."
  @spec protected_system_variables() :: [String.t()]
  def protected_system_variables, do: @protected_system_variables

  @doc "Resolves one closed profile data-model name without dynamic module selection."
  @spec resolve(String.t() | module()) :: {:ok, module()} | {:error, Diagnostic.t()}
  def resolve("null"), do: {:ok, Jido.Statechart.DataModel.Null}
  def resolve("jido"), do: {:ok, Jido.Statechart.DataModel.Jido}
  def resolve(Jido.Statechart.DataModel.Null), do: {:ok, Jido.Statechart.DataModel.Null}
  def resolve(Jido.Statechart.DataModel.Jido), do: {:ok, Jido.Statechart.DataModel.Jido}

  def resolve(_name) do
    {:error,
     Diagnostic.new(:invalid_data_model, "Data model is not in the Statechart profile",
       path: [:data_model]
     )}
  end

  @doc false
  @spec protected_location?(String.t()) :: boolean()
  def protected_location?(location) when is_binary(location) do
    if String.valid?(location) do
      do_protected_location?(location)
    else
      false
    end
  end

  def protected_location?(_location), do: false

  defp do_protected_location?(location) do
    case String.split(location, ".", parts: 2) do
      [root | _rest] -> root in @protected_system_variables
      _other -> false
    end
  end

  @doc false
  @spec validate_value(term(), options(), [term()]) :: :ok | {:error, Diagnostic.t()}
  def validate_value(value, options, path \\ [:data])

  def validate_value(value, options, path) when is_list(options) do
    if Keyword.keyword?(options) do
      with {:ok, limits} <- limits(options),
           :ok <- string_keys(value, path),
           :ok <- Diagnostic.portable(value, path),
           :ok <- within_data_limit(value, limits, path) do
        :ok
      end
    else
      invalid_options()
    end
  end

  def validate_value(_value, _options, _path), do: invalid_options()

  @doc false
  @spec literal_content(map(), options()) :: result(term())
  def literal_content(spec, options) when is_map(spec) do
    with {:ok, _limits} <- limits(options), do: literal_content_value(spec, options)
  end

  def literal_content(_spec, options) do
    with {:ok, _limits} <- limits(options) do
      {:error, Diagnostic.new(:invalid_content, "Content must be a map", path: [:content])}
    end
  end

  defp literal_content_value(spec, options) do
    case Map.get(spec, "items", []) do
      items when is_list(items) ->
        value = literal_value(items)

        with :ok <- validate_value(value, options, [:content]), do: {:ok, value}

      _other ->
        {:error,
         Diagnostic.new(:invalid_content, "Content items must be a list", path: [:content])}
    end
  end

  @doc "Returns a freshly validated Limits contract from data-model options."
  @spec limits(options()) :: result(Limits.t())
  def limits(options) when is_list(options) do
    if Keyword.keyword?(options) do
      case Keyword.get(options, :limits, Limits.default()) do
        %Limits{} = limits -> Limits.new(Map.from_struct(limits))
        _other -> {:error, Diagnostic.new(:invalid_limits, "Validated limits are required")}
      end
    else
      invalid_options()
    end
  end

  def limits(_options), do: invalid_options()

  defp invalid_options,
    do: {:error, Diagnostic.new(:invalid_limits, "Data-model options must be a keyword list")}

  defp literal_value(items) do
    if Enum.all?(items, &text_item?/1) do
      Enum.map_join(items, &Map.fetch!(&1, "value"))
    else
      %{"items" => items}
    end
  end

  defp text_item?(%{"kind" => kind, "value" => value})
       when kind in ["text", "cdata"] and is_binary(value),
       do: true

  defp text_item?(_item), do: false

  defp string_keys(value, path) when is_struct(value) do
    {:error,
     Diagnostic.new(:structured_data_forbidden, "Data values cannot contain structs", path: path)}
  end

  defp string_keys(value, path) when is_map(value) and not is_struct(value) do
    value
    |> Enum.reduce_while(:ok, fn
      {key, item}, :ok when is_binary(key) ->
        case string_keys(item, path ++ [key]) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end

      {key, _item}, :ok ->
        {:halt,
         {:error,
          Diagnostic.new(:invalid_data_key, "Data map keys must be strings", path: path ++ [key])}}
    end)
  end

  defp string_keys(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {item, index}, :ok ->
      case string_keys(item, path ++ [index]) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp string_keys(value, path) when is_tuple(value),
    do: value |> Tuple.to_list() |> string_keys(path)

  defp string_keys(_value, _path), do: :ok

  defp within_data_limit(value, limits, path) do
    maximum = limits.data_bytes

    bytes = value |> :erlang.term_to_binary([:deterministic]) |> byte_size()

    if bytes <= maximum do
      :ok
    else
      {:error,
       Diagnostic.new(:data_limit_exceeded, "Data exceeds the configured byte limit",
         path: path,
         correction: %{"maximum_bytes" => maximum}
       )}
    end
  end
end
