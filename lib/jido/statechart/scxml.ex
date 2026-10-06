defmodule Jido.Statechart.SCXML do
  @moduledoc """
  Compiles bounded XML into the normalized Jido SCXML Profile model.

  This API accepts bytes that the caller already owns. It does not read files,
  open URLs, resolve entities, select modules, or create atoms from XML text.
  `compile_stream/2` accepts any enumerable of binary chunks. Chunk boundaries
  do not change the chart or diagnostic.
  """

  alias Jido.Statechart.{Diagnostic, Limits}
  alias Jido.Statechart.Model.Chart
  alias Jido.Statechart.SCXML.{Handler, LexicalGuard, Lowering, Validation}

  @option_keys [:id, :limits, :source_uri]
  @parser_chunk_bytes 4096

  @doc "Compiles one UTF-8 SCXML binary."
  @spec compile(binary(), keyword()) :: {:ok, Chart.t()} | {:error, Diagnostic.t()}
  def compile(xml, opts \\ [])
  def compile(xml, opts) when is_binary(xml), do: compile_stream([xml], opts)

  def compile(_xml, _opts),
    do:
      {:error,
       Diagnostic.new(:invalid_xml_input, "SCXML input must be a binary",
         profile_feature: "restricted_xml"
       )}

  @doc "Compiles an enumerable of UTF-8 SCXML binary chunks."
  @spec compile_stream(Enumerable.t(), keyword()) ::
          {:ok, Chart.t()} | {:error, Diagnostic.t()}
  def compile_stream(chunks, opts \\ []) do
    result =
      with :ok <- options(opts),
           {:ok, limits} <- Limits.new(Keyword.get(opts, :limits, %{})),
           :ok <- source_uri(Keyword.get(opts, :source_uri)),
           :ok <- chart_id(Keyword.get(opts, :id)),
           {:ok, xml} <- LexicalGuard.collect(chunks, limits),
           {:ok, root} <- parse(xml, limits, Keyword.get(opts, :source_uri)),
           :ok <- Validation.validate(root),
           {:ok, chart} <- Lowering.lower(root, opts) do
        {:ok, chart}
      end

    normalize_result(result, opts)
  end

  @doc "Compiles one SCXML binary or raises `ArgumentError`."
  @spec compile!(binary(), keyword()) :: Chart.t() | no_return()
  def compile!(xml, opts \\ []) do
    case compile(xml, opts) do
      {:ok, chart} -> chart
      {:error, diagnostic} -> raise ArgumentError, "#{diagnostic.code}: #{diagnostic.message}"
    end
  end

  defp parse(xml, limits, source_uri) do
    state = Handler.initial(limits, source_uri)

    case Saxy.parse_stream(xml_chunks(xml), Handler, state,
           expand_entity: :keep,
           cdata_as_characters: false,
           character_data_max_length: @parser_chunk_bytes
         ) do
      {:ok, %{error: nil, root: root, stack: []}} when not is_nil(root) ->
        {:ok, root}

      {:ok, %{error: %Diagnostic{} = diagnostic}} ->
        {:error, diagnostic}

      {:halt, %{error: %Diagnostic{} = diagnostic}, _rest} ->
        {:error, diagnostic}

      {:error, %Saxy.ParseError{}} ->
        {:error,
         Diagnostic.new(:invalid_xml, "SCXML input is not well-formed XML",
           path: ["scxml", 0],
           location: %{"uri" => source_uri},
           profile_feature: "restricted_xml"
         )}

      _other ->
        {:error,
         Diagnostic.new(:invalid_xml, "SCXML parser did not complete the document",
           path: ["scxml", 0],
           location: %{"uri" => source_uri},
           profile_feature: "restricted_xml"
         )}
    end
  end

  defp xml_chunks(xml) do
    Stream.unfold(xml, fn
      "" ->
        nil

      remaining ->
        size = min(byte_size(remaining), @parser_chunk_bytes)

        {binary_part(remaining, 0, size),
         binary_part(remaining, size, byte_size(remaining) - size)}
    end)
  end

  defp options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)

      if keys == Enum.uniq(keys) and Enum.all?(keys, &(&1 in @option_keys)) do
        :ok
      else
        {:error, Diagnostic.new(:invalid_compiler_options, "SCXML compiler options are invalid")}
      end
    else
      {:error,
       Diagnostic.new(:invalid_compiler_options, "SCXML compiler options must be a keyword list")}
    end
  end

  defp options(_opts),
    do:
      {:error,
       Diagnostic.new(:invalid_compiler_options, "SCXML compiler options must be a keyword list")}

  defp source_uri(nil), do: :ok

  defp source_uri(uri) when is_binary(uri) and byte_size(uri) in 1..2048 do
    if String.valid?(uri),
      do: :ok,
      else: {:error, Diagnostic.new(:invalid_source_uri, "Source URI is invalid")}
  end

  defp source_uri(_uri),
    do: {:error, Diagnostic.new(:invalid_source_uri, "Source URI is invalid")}

  defp chart_id(nil), do: :ok
  defp chart_id(id), do: Diagnostic.validate_id(id, [:options, :id])

  defp safe_source_uri(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.get(opts, :source_uri) do
        uri when is_binary(uri) and byte_size(uri) in 1..2048 -> if(String.valid?(uri), do: uri)
        _other -> nil
      end
    end
  end

  defp safe_source_uri(_opts), do: nil

  defp normalize_result({:error, %Diagnostic{} = diagnostic}, opts) do
    {:error,
     %{
       diagnostic
       | location: diagnostic.location || %{"uri" => safe_source_uri(opts)},
         profile_feature: diagnostic.profile_feature || "scxml_element"
     }}
  end

  defp normalize_result(result, _opts), do: result
end
