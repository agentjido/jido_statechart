defmodule Jido.Statechart.SCXML.LexicalGuard do
  @moduledoc false

  alias Jido.Statechart.{Diagnostic, Limits}

  @tail_bytes 32
  @predefined ~w(amp lt gt apos quot)

  defstruct chunks: [], bytes: 0, limit: nil, scan_mode: :normal, scan_tail: ""

  @type t :: %__MODULE__{
          chunks: [binary()],
          bytes: non_neg_integer(),
          limit: pos_integer(),
          scan_mode: :normal | :comment | :cdata | :declaration,
          scan_tail: binary()
        }

  @spec collect(Enumerable.t(), Limits.t()) :: {:ok, binary()} | {:error, Diagnostic.t()}
  def collect(chunks, %Limits{} = limits) do
    initial = %__MODULE__{limit: limits.xml_bytes}

    with {:ok, state} <- reduce_chunks(chunks, initial),
         {:ok, xml} <- finish(state) do
      {:ok, xml}
    end
  end

  defp reduce_chunks(chunks, initial) do
    Enum.reduce_while(chunks, {:ok, initial}, fn chunk, {:ok, state} ->
      case feed(state, chunk) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  rescue
    Protocol.UndefinedError ->
      {:error, diagnostic(:invalid_xml_input, "SCXML input must be binary chunks")}
  end

  @spec feed(t(), term()) :: {:ok, t()} | {:error, Diagnostic.t()}
  def feed(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    bytes = state.bytes + byte_size(chunk)

    if bytes > state.limit do
      {:error,
       diagnostic(:xml_byte_limit, "SCXML input exceeds the XML byte limit",
         profile_feature: "restricted_xml",
         correction: %{"maximum_bytes" => state.limit}
       )}
    else
      data = state.scan_tail <> chunk
      base = state.bytes - byte_size(state.scan_tail)

      case incremental_scan(state.scan_mode, data, base) do
        {:ok, mode, tail} ->
          {:ok,
           %{
             state
             | chunks: [chunk | state.chunks],
               bytes: bytes,
               scan_mode: mode,
               scan_tail: tail
           }}

        {:error, _} = error ->
          error
      end
    end
  end

  def feed(%__MODULE__{}, _chunk),
    do: {:error, diagnostic(:invalid_xml_input, "SCXML input must contain binary chunks")}

  @spec finish(t()) :: {:ok, binary()} | {:error, Diagnostic.t()}
  def finish(%__MODULE__{} = state) do
    xml = state.chunks |> Enum.reverse() |> IO.iodata_to_binary()

    with :ok <- valid_utf8(xml),
         :ok <- valid_xml_characters(xml),
         {:ok, xml} <- strip_bom(xml),
         {:ok, body} <- declaration(xml),
         :ok <- scan(body, 0) do
      {:ok, xml}
    end
  end

  defp valid_utf8(xml) do
    if String.valid?(xml),
      do: :ok,
      else: {:error, diagnostic(:invalid_utf8, "SCXML input must use valid UTF-8")}
  end

  # This scanner keeps only a possible markup prefix or delimiter suffix. The
  # complete bounded input is still passed to the strict scanner and Saxy.
  defp incremental_scan(:normal, data, base), do: incremental_normal(data, 0, base)
  defp incremental_scan(:comment, data, base), do: incremental_delimited(data, 0, base, :comment)
  defp incremental_scan(:cdata, data, base), do: incremental_delimited(data, 0, base, :cdata)

  defp incremental_scan(:declaration, data, base),
    do: incremental_delimited(data, 0, base, :declaration)

  defp incremental_normal(data, position, _base) when position >= byte_size(data),
    do: {:ok, :normal, ""}

  defp incremental_normal(data, position, base) do
    case :binary.match(data, ["<", "&"], scope: {position, byte_size(data) - position}) do
      :nomatch ->
        {:ok, :normal, ""}

      {offset, 1} ->
        case :binary.at(data, offset) do
          ?< -> incremental_markup(data, offset, base)
          ?& -> incremental_reference(data, offset, base)
        end
    end
  end

  defp incremental_markup(data, offset, base) do
    remaining = binary_part(data, offset, byte_size(data) - offset)
    absolute = base + offset

    cond do
      starts_with_binary?(remaining, "<!--") ->
        incremental_delimited(data, offset + 4, base, :comment)

      proper_prefix?(remaining, "<!--") ->
        {:ok, :normal, remaining}

      starts_with_binary?(remaining, "<![CDATA[") ->
        incremental_delimited(data, offset + 9, base, :cdata)

      proper_prefix?(remaining, "<![CDATA[") ->
        {:ok, :normal, remaining}

      starts_with_binary?(remaining, "<!ENTITY") ->
        forbidden_entity()

      proper_prefix?(remaining, "<!ENTITY") ->
        {:ok, :normal, remaining}

      starts_with_binary?(remaining, "<!") ->
        forbidden_dtd()

      starts_with_binary?(remaining, "<?") ->
        incremental_instruction(data, offset, base, absolute, remaining)

      remaining == "<" ->
        {:ok, :normal, remaining}

      true ->
        incremental_normal(data, offset + 1, base)
    end
  end

  defp incremental_reference(data, offset, base) do
    remaining = byte_size(data) - offset - 1
    window_size = min(remaining, @tail_bytes)

    case :binary.match(data, ";", scope: {offset + 1, window_size}) do
      {semicolon, 1} ->
        name = binary_part(data, offset + 1, semicolon - offset - 1)

        with :ok <- allowed_reference(name) do
          incremental_normal(data, semicolon + 1, base)
        end

      :nomatch when remaining < @tail_bytes ->
        {:ok, :normal, binary_part(data, offset, remaining + 1)}

      :nomatch ->
        {:error, diagnostic(:invalid_entity_reference, "XML entity reference is invalid")}
    end
  end

  defp incremental_instruction(data, offset, base, absolute, remaining) do
    cond do
      absolute not in [0, 3] ->
        unsupported_instruction()

      proper_prefix?(remaining, "<?xml") ->
        {:ok, :normal, remaining}

      not starts_with_binary?(remaining, "<?xml") ->
        unsupported_instruction()

      byte_size(remaining) == 5 ->
        {:ok, :normal, remaining}

      :binary.at(remaining, 5) in [9, 10, 13, 32] ->
        incremental_delimited(data, offset + 6, base, :declaration)

      true ->
        unsupported_instruction()
    end
  end

  defp incremental_delimited(data, position, base, mode) do
    delimiter =
      if(mode == :declaration, do: "?>", else: if(mode == :comment, do: "-->", else: "]]>"))

    case :binary.match(data, delimiter, scope: {position, byte_size(data) - position}) do
      {offset, size} -> incremental_normal(data, offset + size, base)
      :nomatch -> {:ok, mode, suffix(data, byte_size(delimiter) - 1)}
    end
  end

  defp suffix(data, maximum) do
    size = min(byte_size(data), maximum)
    binary_part(data, byte_size(data) - size, size)
  end

  defp starts_with_binary?(binary, prefix) do
    byte_size(binary) >= byte_size(prefix) and
      binary_part(binary, 0, byte_size(prefix)) == prefix
  end

  defp proper_prefix?(binary, token) do
    byte_size(binary) < byte_size(token) and
      binary_part(token, 0, byte_size(binary)) == binary
  end

  defp forbidden_entity do
    {:error,
     diagnostic(
       :forbidden_entity_declaration,
       "XML entity declarations are not supported",
       profile_feature: "restricted_xml"
     )}
  end

  defp forbidden_dtd do
    {:error,
     diagnostic(:forbidden_dtd, "XML markup declarations are not supported",
       profile_feature: "restricted_xml"
     )}
  end

  defp unsupported_instruction do
    {:error,
     diagnostic(
       :unsupported_processing_instruction,
       "XML processing instructions are not supported",
       profile_feature: "restricted_xml"
     )}
  end

  defp valid_xml_characters(xml) do
    if Regex.match?(
         ~r/[^\x{9}\x{A}\x{D}\x{20}-\x{D7FF}\x{E000}-\x{FFFD}\x{10000}-\x{10FFFF}]/u,
         xml
       ) do
      {:error,
       diagnostic(:invalid_xml_character, "SCXML input contains an invalid XML character")}
    else
      :ok
    end
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: {:ok, rest}
  defp strip_bom(xml), do: {:ok, xml}

  defp declaration("<?xml" <> rest = xml) do
    case rest do
      <<space, _::binary>> when space in [9, 10, 13, 32] ->
        with {:ok, declaration, body} <- terminated(rest, "?>", :invalid_xml_declaration),
             :ok <- encoding(declaration) do
          {:ok, body}
        end

      _ ->
        {:ok, xml}
    end
  end

  defp declaration(xml), do: {:ok, xml}

  defp encoding(declaration) do
    case Regex.run(~r/\bencoding\s*=\s*(['"])([^'"]+)\1/iu, declaration, capture: :all_but_first) do
      nil ->
        :ok

      [_quote, encoding] ->
        if String.upcase(encoding) == "UTF-8" do
          :ok
        else
          {:error,
           diagnostic(:unsupported_encoding, "The Jido SCXML Profile accepts only UTF-8 XML",
             profile_feature: "restricted_xml",
             correction: %{"supported_encoding" => "UTF-8"}
           )}
        end
    end
  end

  defp scan(xml, position) when position >= byte_size(xml), do: :ok

  defp scan(xml, position) do
    size = byte_size(xml) - position

    case :binary.match(xml, ["<", "&"], scope: {position, size}) do
      :nomatch ->
        :ok

      {offset, 1} ->
        case :binary.at(xml, offset) do
          ?< -> markup(xml, offset)
          ?& -> reference(xml, offset)
        end
    end
  end

  defp markup(xml, offset) do
    cond do
      starts_with?(xml, offset, "<!--") ->
        with {:ok, comment, next} <- terminated_at(xml, offset + 4, "-->", :invalid_xml_comment),
             :ok <- valid_comment(comment) do
          scan(xml, next)
        end

      starts_with?(xml, offset, "<![CDATA[") ->
        with {:ok, _data, next} <- terminated_at(xml, offset + 9, "]]>", :invalid_cdata) do
          scan(xml, next)
        end

      starts_with_ci?(xml, offset, "<!ENTITY") ->
        {:error,
         diagnostic(
           :forbidden_entity_declaration,
           "XML entity declarations are not supported",
           profile_feature: "restricted_xml"
         )}

      starts_with_ci?(xml, offset, "<!DOCTYPE") ->
        {:error,
         diagnostic(:forbidden_dtd, "XML document type declarations are not supported",
           profile_feature: "restricted_xml"
         )}

      starts_with?(xml, offset, "<?") ->
        {:error,
         diagnostic(
           :unsupported_processing_instruction,
           "XML processing instructions are not supported",
           profile_feature: "restricted_xml"
         )}

      starts_with?(xml, offset, "<!") ->
        {:error,
         diagnostic(:forbidden_dtd, "XML markup declarations are not supported",
           profile_feature: "restricted_xml"
         )}

      true ->
        scan(xml, offset + 1)
    end
  end

  defp reference(xml, offset) do
    remaining = byte_size(xml) - offset - 1
    window_size = min(remaining, @tail_bytes)

    case :binary.match(xml, ";", scope: {offset + 1, window_size}) do
      :nomatch ->
        {:error, diagnostic(:invalid_entity_reference, "XML entity reference is invalid")}

      {semicolon, 1} ->
        name = binary_part(xml, offset + 1, semicolon - offset - 1)

        with :ok <- allowed_reference(name) do
          scan(xml, semicolon + 1)
        end
    end
  end

  defp allowed_reference(name) when name in @predefined, do: :ok

  defp allowed_reference("#x" <> digits), do: numeric_reference(digits, 16)
  defp allowed_reference("#X" <> digits), do: numeric_reference(digits, 16)
  defp allowed_reference("#" <> digits), do: numeric_reference(digits, 10)

  defp allowed_reference(_name) do
    {:error,
     diagnostic(:unsupported_entity_reference, "Declared XML entity references are not supported",
       profile_feature: "restricted_xml"
     )}
  end

  defp numeric_reference(digits, base) do
    syntax = if base == 16, do: ~r/\A[0-9A-Fa-f]+\z/, else: ~r/\A[0-9]+\z/

    with true <- byte_size(digits) in 1..7 and Regex.match?(syntax, digits),
         {value, ""} <- Integer.parse(digits, base),
         true <- xml_character?(value) do
      :ok
    else
      _ -> {:error, diagnostic(:invalid_entity_reference, "XML character reference is invalid")}
    end
  end

  defp xml_character?(value) do
    value in [9, 10, 13] or value in 0x20..0xD7FF or value in 0xE000..0xFFFD or
      value in 0x10000..0x10FFFF
  end

  defp starts_with?(xml, offset, token) do
    available = byte_size(xml) - offset
    available >= byte_size(token) and binary_part(xml, offset, byte_size(token)) == token
  end

  defp starts_with_ci?(xml, offset, token) do
    available = byte_size(xml) - offset

    available >= byte_size(token) and
      xml |> binary_part(offset, byte_size(token)) |> String.upcase() == String.upcase(token)
  end

  defp terminated(rest, delimiter, code) do
    case :binary.match(rest, delimiter) do
      {offset, size} ->
        body = binary_part(rest, 0, offset)
        tail = binary_part(rest, offset + size, byte_size(rest) - offset - size)
        {:ok, body, tail}

      :nomatch ->
        {:error, diagnostic(code, "XML declaration is not terminated")}
    end
  end

  defp terminated_at(xml, start, delimiter, code) do
    case :binary.match(xml, delimiter, scope: {start, byte_size(xml) - start}) do
      {offset, size} -> {:ok, binary_part(xml, start, offset - start), offset + size}
      :nomatch -> {:error, diagnostic(code, "XML markup is not terminated")}
    end
  end

  defp valid_comment(comment) do
    if String.contains?(comment, "--") or String.ends_with?(comment, "-") do
      {:error, diagnostic(:invalid_xml_comment, "XML comment is invalid")}
    else
      :ok
    end
  end

  defp diagnostic(code, message, opts \\ []) do
    Diagnostic.new(code, message, Keyword.put_new(opts, :profile_feature, "restricted_xml"))
  end
end
