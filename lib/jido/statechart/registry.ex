defmodule Jido.Statechart.Registry do
  @moduledoc "A typed, versioned Registry of trusted application capabilities."

  alias Jido.Statechart.Diagnostic

  defmodule Entry do
    @moduledoc "A trusted Registry entry. The handler is absent from persisted manifests."

    alias Jido.Statechart.Diagnostic

    @kinds [:expression, :action, :target, :invocation]
    @fields [:kind, :alias, :permissions, :handler, :metadata]

    defstruct kind: nil, name: nil, permissions: [], handler: nil, metadata: %{}

    @type t :: %__MODULE__{}

    @spec new(map()) :: {:ok, t()} | {:error, Diagnostic.t()}
    def new(%__MODULE__{} = entry) do
      entry
      |> Map.from_struct()
      |> Map.delete(:name)
      |> Map.put(:alias, entry.name)
      |> new()
    end

    def new(attrs) when is_map(attrs) do
      with :ok <- Diagnostic.validate_fields(attrs, @fields, [:registry, :entry]),
           {:ok, kind} <- kind(Diagnostic.fetch(attrs, :kind)),
           {:ok, name} <- name(Diagnostic.fetch(attrs, :alias)),
           {:ok, permissions} <- permissions(Diagnostic.fetch(attrs, :permissions, [])),
           {:ok, handler} <- handler(Diagnostic.fetch(attrs, :handler)),
           {:ok, metadata} <- metadata(Diagnostic.fetch(attrs, :metadata, %{})) do
        {:ok,
         %__MODULE__{
           kind: kind,
           name: name,
           permissions: permissions,
           handler: handler,
           metadata: metadata
         }}
      end
    end

    def new(_attrs),
      do:
        {:error,
         Diagnostic.new(:invalid_registry_entry, "Registry entry must be a map",
           path: [:registry]
         )}

    @spec manifest(t()) :: map()
    def manifest(%__MODULE__{} = entry) do
      %{
        "kind" => Atom.to_string(entry.kind),
        "alias" => entry.name,
        "permissions" => entry.permissions,
        "metadata" => entry.metadata
      }
    end

    defp kind(kind) when kind in @kinds, do: {:ok, kind}

    defp kind(kind) when is_binary(kind) do
      case Enum.find(@kinds, &(Atom.to_string(&1) == kind)) do
        nil -> invalid_kind()
        known -> {:ok, known}
      end
    end

    defp kind(_kind), do: invalid_kind()

    defp invalid_kind,
      do:
        {:error,
         Diagnostic.new(:invalid_registry_kind, "Registry kind is not supported",
           path: [:registry, :kind]
         )}

    defp name(value) when is_binary(value) and byte_size(value) in 1..255 do
      if String.valid?(value) and Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_.:-]*$/u, value) do
        {:ok, value}
      else
        invalid_name()
      end
    end

    defp name(_value), do: invalid_name()

    defp invalid_name,
      do:
        {:error,
         Diagnostic.new(:invalid_registry_alias, "Registry alias is not legal",
           path: [:registry, :alias]
         )}

    defp permissions(values) when is_list(values) do
      if Enum.all?(values, &(is_binary(&1) and &1 != "" and String.valid?(&1))) do
        {:ok, values |> Enum.uniq() |> Enum.sort()}
      else
        invalid_permissions()
      end
    end

    defp permissions(_values), do: invalid_permissions()

    defp invalid_permissions,
      do:
        {:error,
         Diagnostic.new(:invalid_registry_permissions, "Registry permissions must be strings",
           path: [:registry, :permissions]
         )}

    defp handler(nil),
      do:
        {:error,
         Diagnostic.new(:invalid_registry_handler, "Registry handler is required",
           path: [:registry, :handler]
         )}

    defp handler(value) when is_atom(value) or is_tuple(value) or is_function(value),
      do: {:ok, value}

    defp handler(_value),
      do: {:error, Diagnostic.new(:invalid_registry_handler, "Registry handler is invalid")}

    defp metadata(value) when is_map(value) and not is_struct(value) do
      with :ok <- Diagnostic.portable(value, [:registry, :metadata]), do: {:ok, value}
    end

    defp metadata(_value),
      do:
        {:error, Diagnostic.new(:invalid_registry_metadata, "Registry metadata must be portable")}
  end

  defstruct version: nil, entries: [], index: %{}, digest: nil

  @fields [:version, :entries]

  @type t :: %__MODULE__{}

  @spec new(map()) :: {:ok, t()} | {:error, Diagnostic.t()}
  def new(attrs) when is_map(attrs) do
    with :ok <- Diagnostic.validate_fields(attrs, @fields, [:registry]),
         {:ok, version} <- Diagnostic.require_string(attrs, :version, [:registry]),
         {:ok, entries} <- entries(Diagnostic.fetch(attrs, :entries, [])),
         :ok <- unique_aliases(entries),
         :ok <- trusted_action_handlers(entries) do
      entries = Enum.sort_by(entries, &{&1.name, &1.kind})
      base = %{"version" => version, "entries" => Enum.map(entries, &Entry.manifest/1)}

      {:ok,
       %__MODULE__{
         version: version,
         entries: entries,
         index: Map.new(entries, &{{&1.kind, &1.name}, &1}),
         digest: Diagnostic.digest(base)
       }}
    end
  end

  def new(_attrs),
    do: {:error, Diagnostic.new(:invalid_registry, "Registry must be a map", path: [:registry])}

  @spec new!(map()) :: t()
  def new!(attrs), do: attrs |> new() |> Diagnostic.unwrap!()

  @doc "Returns a portable Registry manifest without handlers."
  @spec manifest(t()) :: map()
  def manifest(%__MODULE__{} = registry) do
    %{
      "version" => registry.version,
      "entries" => Enum.map(registry.entries, &Entry.manifest/1),
      "digest" => registry.digest
    }
  end

  @doc "Resolves one trusted capability without converting text to atoms."
  @spec fetch(t(), atom(), String.t()) :: {:ok, Entry.t()} | :error
  def fetch(%__MODULE__{} = registry, kind, name), do: Map.fetch(registry.index, {kind, name})

  @doc "Adds a new alias. Existing aliases cannot be replaced."
  @spec put(t(), map()) :: {:ok, t()} | {:error, Diagnostic.t()}
  def put(%__MODULE__{} = registry, attrs) do
    with {:ok, entry} <- Entry.new(attrs) do
      if Enum.any?(registry.entries, &(&1.name == entry.name)) do
        {:error,
         Diagnostic.new(:registry_replacement, "Registry aliases cannot be replaced",
           path: [:registry, :entries, entry.name]
         )}
      else
        new(%{version: registry.version, entries: [entry | registry.entries]})
      end
    end
  end

  defp entries(values) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      case Entry.new(value) do
        {:ok, entry} ->
          {:cont, {:ok, [entry | acc]}}

        {:error, diagnostic} ->
          {:halt, {:error, Diagnostic.prefix(diagnostic, [:registry, :entries, index])}}
      end
    end)
    |> then(fn
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end)
  end

  defp entries(_values),
    do: {:error, Diagnostic.new(:invalid_registry, "Registry entries must be a list")}

  defp unique_aliases(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while(MapSet.new(), fn {entry, index}, seen ->
      if MapSet.member?(seen, entry.name) do
        {:halt,
         {:error,
          Diagnostic.new(
            :duplicate_registry_alias,
            "Registry aliases must be unique across kinds",
            path: [:registry, :entries, index, :alias]
          )}}
      else
        {:cont, MapSet.put(seen, entry.name)}
      end
    end)
    |> case do
      %MapSet{} -> :ok
      error -> error
    end
  end

  defp trusted_action_handlers(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn
      {%Entry{kind: :action, handler: handler}, index}, :ok ->
        case static_action_module(handler) do
          :ok ->
            {:cont, :ok}

          {:error, diagnostic} ->
            {:halt, {:error, Diagnostic.prefix(diagnostic, [:registry, :entries, index])}}
        end

      {_entry, _index}, :ok ->
        {:cont, :ok}
    end)
  end

  defp static_action_module(module) when is_atom(module) and not is_nil(module) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         attributes <- module.module_info(:attributes),
         true <- Jido.Action in List.wrap(attributes[:behaviour]),
         true <- function_exported?(module, :run, 2),
         true <- function_exported?(module, :validate_params, 1),
         true <- function_exported?(module, :validate_output, 1),
         true <- function_exported?(module, :__jido_executable__, 0) do
      :ok
    else
      _reason -> invalid_action_handler()
    end
  rescue
    _exception -> invalid_action_handler()
  end

  defp static_action_module(_handler), do: invalid_action_handler()

  defp invalid_action_handler do
    {:error,
     Diagnostic.new(
       :invalid_registry_handler,
       "Action Registry handler must implement the static Jido.Action contract",
       path: [:handler]
     )}
  end
end
