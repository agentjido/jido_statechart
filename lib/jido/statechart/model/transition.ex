defmodule Jido.Statechart.Model.Transition do
  @moduledoc "A transition in a normalized chart."

  alias Jido.Statechart.Diagnostic
  alias Jido.Statechart.Model.{Executable, Source}

  @types [:external, :internal]
  @fields [
    :id,
    :ordinal,
    :source_id,
    :target_ids,
    :events,
    :condition,
    :type,
    :executable,
    :source,
    :generated
  ]

  defstruct id: nil,
            ordinal: nil,
            source_id: nil,
            target_ids: [],
            events: [],
            condition: nil,
            type: :external,
            executable: [],
            source: nil,
            generated: false

  @type t :: %__MODULE__{}

  @spec new(map()) :: {:ok, t()} | {:error, Diagnostic.t()}
  def new(attrs) when is_map(attrs) do
    with :ok <- Diagnostic.validate_fields(attrs, @fields, [:transition]),
         {:ok, id} <- id(attrs),
         {:ok, ordinal} <- ordinal(Diagnostic.fetch(attrs, :ordinal)),
         {:ok, source_id} <- required_id(attrs, :source_id),
         {:ok, target_ids} <- ids(Diagnostic.fetch(attrs, :target_ids, []), :target_ids),
         {:ok, events} <- strings(Diagnostic.fetch(attrs, :events, []), :events),
         {:ok, condition} <- Diagnostic.optional_string(attrs, :condition, [:transition]),
         {:ok, type} <- transition_type(Diagnostic.fetch(attrs, :type, :external)),
         {:ok, executable} <- executables(Diagnostic.fetch(attrs, :executable, [])),
         {:ok, source} <- source(Diagnostic.fetch(attrs, :source)),
         {:ok, generated} <- boolean(Diagnostic.fetch(attrs, :generated, false)) do
      {:ok,
       %__MODULE__{
         id: id,
         ordinal: ordinal,
         source_id: source_id,
         target_ids: target_ids,
         events: events,
         condition: condition,
         type: type,
         executable: executable,
         source: source,
         generated: generated
       }}
    end
  end

  def new(_attrs),
    do:
      {:error,
       Diagnostic.new(:invalid_transition, "transition must be a map", path: [:transition])}

  @spec new!(map()) :: t()
  def new!(attrs), do: attrs |> new() |> Diagnostic.unwrap!()

  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = transition) do
    %{
      "id" => transition.id,
      "ordinal" => transition.ordinal,
      "source_id" => transition.source_id,
      "target_ids" => transition.target_ids,
      "events" => transition.events,
      "condition" => transition.condition,
      "type" => Atom.to_string(transition.type),
      "executable" => Enum.map(transition.executable, &Executable.dump/1),
      "source" => if(transition.source, do: Source.dump(transition.source)),
      "generated" => transition.generated
    }
  end

  defp id(attrs) do
    with {:ok, id} <- Diagnostic.require_string(attrs, :id, [:transition]),
         :ok <- Diagnostic.validate_id(id, [:transition, :id]),
         do: {:ok, id}
  end

  defp required_id(attrs, field) do
    with {:ok, id} <- Diagnostic.require_string(attrs, field, [:transition]),
         :ok <- Diagnostic.validate_id(id, [:transition, field]),
         do: {:ok, id}
  end

  defp ordinal(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp ordinal(_value),
    do:
      {:error,
       Diagnostic.new(:invalid_ordinal, "transition ordinal must be nonnegative",
         path: [:transition, :ordinal]
       )}

  defp ids(values, field) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, {[], MapSet.new()}}, fn {value, index}, {:ok, {acc, seen}} ->
      case Diagnostic.validate_id(value, [:transition, field, index]) do
        :ok ->
          if MapSet.member?(seen, value) do
            {:halt,
             {:error,
              Diagnostic.new(:duplicate_id_reference, "transition targets contain a duplicate",
                path: [:transition, field, index]
              )}}
          else
            {:cont, {:ok, {[value | acc], MapSet.put(seen, value)}}}
          end

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> then(fn
      {:ok, {ids, _seen}} -> {:ok, Enum.reverse(ids)}
      error -> error
    end)
  end

  defp ids(_values, field),
    do:
      {:error,
       Diagnostic.new(:invalid_id_list, "transition targets must be a list",
         path: [:transition, field]
       )}

  defp strings(values, field) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      if is_binary(value) and value != "" and String.valid?(value) do
        {:cont, {:ok, [value | acc]}}
      else
        {:halt,
         {:error,
          Diagnostic.new(:invalid_event_descriptor, "event descriptor is invalid",
            path: [:transition, field, index]
          )}}
      end
    end)
    |> then(fn
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end)
  end

  defp strings(_values, field),
    do:
      {:error,
       Diagnostic.new(:invalid_event_descriptor, "event descriptors must be a list",
         path: [:transition, field]
       )}

  defp transition_type(type) when type in @types, do: {:ok, type}

  defp transition_type(type) when is_binary(type) do
    case Enum.find(@types, &(Atom.to_string(&1) == type)) do
      nil -> invalid_type()
      known -> {:ok, known}
    end
  end

  defp transition_type(_type), do: invalid_type()

  defp invalid_type,
    do:
      {:error,
       Diagnostic.new(:invalid_transition_type, "transition type is not supported",
         path: [:transition, :type]
       )}

  defp executables(values) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      case Executable.new(value) do
        {:ok, executable} ->
          {:cont, {:ok, [executable | acc]}}

        {:error, diagnostic} ->
          {:halt, {:error, Diagnostic.prefix(diagnostic, [:transition, :executable, index])}}
      end
    end)
    |> then(fn
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end)
  end

  defp executables(_values),
    do:
      {:error,
       Diagnostic.new(:invalid_executable, "transition executable content must be a list",
         path: [:transition, :executable]
       )}

  defp source(nil), do: {:ok, nil}
  defp source(value), do: Source.new(value)

  defp boolean(value) when is_boolean(value), do: {:ok, value}

  defp boolean(_value),
    do:
      {:error,
       Diagnostic.new(:invalid_boolean, "generated must be a boolean",
         path: [:transition, :generated]
       )}
end
