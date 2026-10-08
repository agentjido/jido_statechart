defmodule Jido.Statechart.Model.Source do
  @moduledoc "Source identity and location for one normalized SCXML value."

  alias Jido.Statechart.Diagnostic

  @fields [:uri, :path, :line, :column, :byte_offset]

  defstruct uri: nil, path: [], line: nil, column: nil, byte_offset: nil

  @type t :: %__MODULE__{
          uri: String.t() | nil,
          path: [String.t() | non_neg_integer()],
          line: pos_integer() | nil,
          column: pos_integer() | nil,
          byte_offset: non_neg_integer() | nil
        }

  @spec new(map()) :: {:ok, t()} | {:error, Diagnostic.t()}
  def new(attrs) when is_map(attrs) do
    with :ok <- Diagnostic.validate_fields(attrs, @fields, [:source]) do
      source = %__MODULE__{
        uri: Diagnostic.fetch(attrs, :uri),
        path: Diagnostic.fetch(attrs, :path, []),
        line: Diagnostic.fetch(attrs, :line),
        column: Diagnostic.fetch(attrs, :column),
        byte_offset: Diagnostic.fetch(attrs, :byte_offset)
      }

      with :ok <- optional_utf8(source.uri, [:source, :uri]),
           :ok <- source_path(source.path),
           :ok <- optional_integer(source.line, 1, [:source, :line]),
           :ok <- optional_integer(source.column, 1, [:source, :column]),
           :ok <- optional_integer(source.byte_offset, 0, [:source, :byte_offset]) do
        {:ok, source}
      end
    end
  end

  def new(_attrs),
    do: {:error, Diagnostic.new(:invalid_source, "source must be a map", path: [:source])}

  @spec new!(map()) :: t()
  def new!(attrs), do: attrs |> new() |> Diagnostic.unwrap!()

  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = source) do
    %{
      "uri" => source.uri,
      "path" => source.path,
      "line" => source.line,
      "column" => source.column,
      "byte_offset" => source.byte_offset
    }
  end

  defp optional_utf8(nil, _path), do: :ok

  defp optional_utf8(value, path) when is_binary(value) do
    if value != "" and String.valid?(value),
      do: :ok,
      else: {:error, Diagnostic.new(:invalid_source, "source URI is invalid", path: path)}
  end

  defp optional_utf8(_value, path),
    do: {:error, Diagnostic.new(:invalid_source, "source URI is invalid", path: path)}

  defp source_path(path) when is_list(path) do
    if Enum.all?(path, fn
         item when is_binary(item) -> item != "" and String.valid?(item)
         item when is_integer(item) -> item >= 0
         _ -> false
       end) do
      :ok
    else
      {:error,
       Diagnostic.new(:invalid_source, "source path contains an invalid segment",
         path: [:source, :path]
       )}
    end
  end

  defp source_path(_path),
    do:
      {:error,
       Diagnostic.new(:invalid_source, "source path must be a list", path: [:source, :path])}

  defp optional_integer(nil, _min, _path), do: :ok
  defp optional_integer(value, min, _path) when is_integer(value) and value >= min, do: :ok

  defp optional_integer(_value, _min, path),
    do: {:error, Diagnostic.new(:invalid_source, "source position is invalid", path: path)}
end
