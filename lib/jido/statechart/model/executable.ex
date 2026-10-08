defmodule Jido.Statechart.Model.Executable do
  @moduledoc "A normalized executable-content command."

  alias Jido.Statechart.Diagnostic
  alias Jido.Statechart.Model.Source

  @kinds [:raise, :if, :foreach, :assign, :log, :send, :cancel, :action]
  @fields [:kind, :ordinal, :data, :children, :source]

  defstruct kind: nil, ordinal: nil, data: %{}, children: [], source: nil

  @type t :: %__MODULE__{
          kind: atom(),
          ordinal: non_neg_integer(),
          data: map(),
          children: [t()],
          source: Source.t() | nil
        }

  @spec new(map()) :: {:ok, t()} | {:error, Diagnostic.t()}
  def new(attrs) when is_map(attrs) do
    with :ok <- Diagnostic.validate_fields(attrs, @fields, [:executable]),
         {:ok, kind} <- kind(Diagnostic.fetch(attrs, :kind)),
         {:ok, ordinal} <- ordinal(Diagnostic.fetch(attrs, :ordinal)),
         {:ok, data} <- data(Diagnostic.fetch(attrs, :data, %{})),
         {:ok, children} <- children(Diagnostic.fetch(attrs, :children, [])),
         {:ok, source} <- source(Diagnostic.fetch(attrs, :source)) do
      {:ok,
       %__MODULE__{
         kind: kind,
         ordinal: ordinal,
         data: data,
         children: children,
         source: source
       }}
    end
  end

  def new(_attrs),
    do:
      {:error,
       Diagnostic.new(:invalid_executable, "executable content must be a map",
         path: [:executable]
       )}

  @spec new!(map()) :: t()
  def new!(attrs), do: attrs |> new() |> Diagnostic.unwrap!()

  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = executable) do
    %{
      "kind" => Atom.to_string(executable.kind),
      "ordinal" => executable.ordinal,
      "data" => executable.data,
      "children" => Enum.map(executable.children, &dump/1),
      "source" => if(executable.source, do: Source.dump(executable.source))
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
       Diagnostic.new(:invalid_executable_kind, "executable kind is not supported",
         path: [:executable, :kind]
       )}

  defp ordinal(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp ordinal(_value),
    do:
      {:error,
       Diagnostic.new(:invalid_ordinal, "executable ordinal must be nonnegative",
         path: [:executable, :ordinal]
       )}

  defp data(value) when is_map(value) and not is_struct(value) do
    with :ok <- Diagnostic.portable(value, [:executable, :data]), do: {:ok, value}
  end

  defp data(_value),
    do:
      {:error,
       Diagnostic.new(:invalid_executable_data, "executable data must be a portable map",
         path: [:executable, :data]
       )}

  defp children(values) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      case new(value) do
        {:ok, executable} ->
          {:cont, {:ok, [executable | acc]}}

        {:error, diagnostic} ->
          {:halt, {:error, Diagnostic.prefix(diagnostic, [:children, index])}}
      end
    end)
    |> then(fn
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end)
  end

  defp children(_values),
    do: {:error, Diagnostic.new(:invalid_executable, "children must be a list")}

  defp source(nil), do: {:ok, nil}
  defp source(%Source{} = source), do: Source.new(source)
  defp source(value), do: Source.new(value)
end
