defmodule Jido.Statechart.Model.State do
  @moduledoc "A state in a normalized chart."

  alias Jido.Statechart.Diagnostic
  alias Jido.Statechart.Model.{Executable, Source}

  @kinds [:atomic, :compound, :parallel, :final, :history_shallow, :history_deep]
  @fields [
    :id,
    :ordinal,
    :kind,
    :parent,
    :children,
    :initial,
    :transition_ids,
    :on_entry,
    :on_exit,
    :data,
    :done_data,
    :source,
    :generated
  ]

  defstruct id: nil,
            ordinal: nil,
            kind: nil,
            parent: nil,
            children: [],
            initial: [],
            transition_ids: [],
            on_entry: [],
            on_exit: [],
            data: %{},
            done_data: nil,
            source: nil,
            generated: false

  @type t :: %__MODULE__{}

  @spec new(map()) :: {:ok, t()} | {:error, Diagnostic.t()}
  def new(attrs) when is_map(attrs) do
    with :ok <- Diagnostic.validate_fields(attrs, @fields, [:state]),
         {:ok, id} <- required_id(attrs),
         {:ok, ordinal} <- ordinal(Diagnostic.fetch(attrs, :ordinal)),
         {:ok, kind} <- kind(Diagnostic.fetch(attrs, :kind)),
         {:ok, parent} <- optional_id(Diagnostic.fetch(attrs, :parent), [:state, :parent]),
         {:ok, children} <- ids(Diagnostic.fetch(attrs, :children, []), [:state, :children]),
         {:ok, initial} <- ids(Diagnostic.fetch(attrs, :initial, []), [:state, :initial]),
         {:ok, transition_ids} <-
           ids(Diagnostic.fetch(attrs, :transition_ids, []), [:state, :transition_ids]),
         {:ok, on_entry} <- executables(Diagnostic.fetch(attrs, :on_entry, []), :on_entry),
         {:ok, on_exit} <- executables(Diagnostic.fetch(attrs, :on_exit, []), :on_exit),
         {:ok, data} <- portable_map(Diagnostic.fetch(attrs, :data, %{}), [:state, :data]),
         {:ok, done_data} <-
           portable_value(Diagnostic.fetch(attrs, :done_data), [:state, :done_data]),
         {:ok, source} <- source(Diagnostic.fetch(attrs, :source)),
         {:ok, generated} <- boolean(Diagnostic.fetch(attrs, :generated, false), :generated) do
      state = %__MODULE__{
        id: id,
        ordinal: ordinal,
        kind: kind,
        parent: parent,
        children: children,
        initial: initial,
        transition_ids: transition_ids,
        on_entry: on_entry,
        on_exit: on_exit,
        data: data,
        done_data: done_data,
        source: source,
        generated: generated
      }

      with :ok <- shape(state), do: {:ok, state}
    end
  end

  def new(_attrs),
    do: {:error, Diagnostic.new(:invalid_state, "state must be a map", path: [:state])}

  @spec new!(map()) :: t()
  def new!(attrs), do: attrs |> new() |> Diagnostic.unwrap!()

  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = state) do
    %{
      "id" => state.id,
      "ordinal" => state.ordinal,
      "kind" => Atom.to_string(state.kind),
      "parent" => state.parent,
      "children" => state.children,
      "initial" => state.initial,
      "transition_ids" => state.transition_ids,
      "on_entry" => Enum.map(state.on_entry, &Executable.dump/1),
      "on_exit" => Enum.map(state.on_exit, &Executable.dump/1),
      "data" => state.data,
      "done_data" => state.done_data,
      "source" => if(state.source, do: Source.dump(state.source)),
      "generated" => state.generated
    }
  end

  defp required_id(attrs) do
    with {:ok, id} <- Diagnostic.require_string(attrs, :id, [:state]),
         :ok <- Diagnostic.validate_id(id, [:state, :id]),
         do: {:ok, id}
  end

  defp optional_id(nil, _path), do: {:ok, nil}

  defp optional_id(id, path) do
    with :ok <- Diagnostic.validate_id(id, path), do: {:ok, id}
  end

  defp ids(values, path) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, {[], MapSet.new()}}, fn {value, index}, {:ok, {acc, seen}} ->
      case Diagnostic.validate_id(value, path ++ [index]) do
        :ok ->
          if MapSet.member?(seen, value) do
            {:halt,
             {:error,
              Diagnostic.new(:duplicate_id_reference, "identifier list contains a duplicate",
                path: path ++ [index]
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

  defp ids(_values, path),
    do: {:error, Diagnostic.new(:invalid_id_list, "identifier value must be a list", path: path)}

  defp ordinal(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp ordinal(_value),
    do:
      {:error,
       Diagnostic.new(:invalid_ordinal, "state ordinal must be nonnegative",
         path: [:state, :ordinal]
       )}

  defp kind(kind) when kind in @kinds, do: {:ok, kind}

  defp kind(kind) when is_binary(kind) do
    case Enum.find(@kinds, &(Atom.to_string(&1) == kind)) do
      nil -> invalid_kind()
      known -> {:ok, known}
    end
  end

  defp kind(_kind), do: invalid_kind()

  defp invalid_kind do
    {:error,
     Diagnostic.new(:invalid_state_kind, "state kind is not supported", path: [:state, :kind])}
  end

  defp executables(values, field) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      case Executable.new(value) do
        {:ok, executable} ->
          {:cont, {:ok, [executable | acc]}}

        {:error, diagnostic} ->
          {:halt, {:error, Diagnostic.prefix(diagnostic, [:state, field, index])}}
      end
    end)
    |> then(fn
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end)
  end

  defp executables(_values, field),
    do:
      {:error,
       Diagnostic.new(:invalid_executable, "executable content must be a list",
         path: [:state, field]
       )}

  defp portable_map(value, path) when is_map(value) and not is_struct(value) do
    with :ok <- Diagnostic.portable(value, path), do: {:ok, value}
  end

  defp portable_map(_value, path),
    do: {:error, Diagnostic.new(:non_portable_value, "data must be a portable map", path: path)}

  defp portable_value(value, path) do
    with :ok <- Diagnostic.portable(value, path), do: {:ok, value}
  end

  defp source(nil), do: {:ok, nil}
  defp source(value), do: Source.new(value)

  defp boolean(value, _field) when is_boolean(value), do: {:ok, value}

  defp boolean(_value, field),
    do:
      {:error,
       Diagnostic.new(:invalid_boolean, "#{field} must be a boolean", path: [:state, field])}

  defp shape(%__MODULE__{kind: kind, children: children})
       when kind in [:atomic, :final, :history_shallow, :history_deep] and children != [] do
    {:error,
     Diagnostic.new(:invalid_state_shape, "leaf states cannot have children",
       path: [:state, :children]
     )}
  end

  defp shape(%__MODULE__{kind: :parallel, initial: initial}) when initial != [] do
    {:error,
     Diagnostic.new(:invalid_state_shape, "parallel states cannot declare initial targets",
       path: [:state, :initial]
     )}
  end

  defp shape(%__MODULE__{kind: kind, initial: initial})
       when kind in [:atomic, :final, :history_shallow, :history_deep] and initial != [] do
    {:error,
     Diagnostic.new(:invalid_state_shape, "leaf states cannot declare initial targets",
       path: [:state, :initial]
     )}
  end

  defp shape(_state), do: :ok
end
