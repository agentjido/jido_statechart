defmodule Jido.Statechart.SCXML.Security do
  @moduledoc false
  import Jido.Statechart.SCXML.Validation, only: [ensure!: 3]

  def validate!(xml, limits) do
    ensure!(is_binary(xml), :invalid_xml, "SCXML input must be XML bytes")
    ensure!(byte_size(xml) <= limits.bytes, :limit_exceeded, "XML byte limit exceeded")
    characters!(xml)

    xml =
      case xml do
        <<239, 187, 191, rest::binary>> -> rest
        _ -> xml
      end

    scan!(xml, true)
    xml
  end

  def characters!(text) do
    ensure!(String.valid?(text), :invalid_xml, "XML must use valid UTF-8")

    ensure!(
      !Regex.match?(
        ~r/[^\x{9}\x{A}\x{D}\x{20}-\x{D7FF}\x{E000}-\x{FFFD}\x{10000}-\x{10FFFF}]/u,
        text
      ),
      :invalid_xml,
      "Invalid XML character"
    )
  end

  def reject_entity!(_name),
    do: ensure!(false, :unsupported_xml, "Declared and external XML entities are not supported")

  # Saxy skips declarations and PIs. This linear scan rejects them first.
  # It also bounds numeric references before the parser converts them.
  defp scan!(xml, prolog?) do
    case :binary.match(xml, ["<", "&"]) do
      :nomatch ->
        :ok

      {offset, 1} ->
        rest = binary_part(xml, offset, byte_size(xml) - offset)
        token!(rest, prolog? and offset == 0)
    end
  end

  defp token!("<!--" <> rest, _) do
    {comment, tail} = terminated!(rest, "-->")

    ensure!(
      !String.contains?(comment, "--") and !String.ends_with?(comment, "-"),
      :invalid_xml,
      "Invalid XML comment"
    )

    scan!(tail, false)
  end

  defp token!("<?xml" <> <<space, rest::binary>>, true) when space in [9, 10, 13, 32] do
    {_, tail} = terminated!(rest, "?>")
    scan!(tail, false)
  end

  defp token!("<!" <> _, _), do: unsupported!()
  defp token!("<?" <> _, _), do: unsupported!()

  defp token!("&#" <> rest, _) do
    window = binary_part(rest, 0, min(byte_size(rest), 9))

    {offset, 1} =
      case :binary.match(window, ";") do
        :nomatch -> ensure!(false, :invalid_xml, "Invalid or overlong XML character reference")
        match -> match
      end

    reference = binary_part(rest, 0, offset)

    {digits, base, syntax} =
      case reference do
        "x" <> digits -> {digits, 16, ~r/\A[0-9A-Fa-f]+\z/}
        digits -> {digits, 10, ~r/\A[0-9]+\z/}
      end

    ensure!(
      byte_size(digits) in 1..7 and Regex.match?(syntax, digits),
      :invalid_xml,
      "Invalid XML character reference"
    )

    {value, ""} = Integer.parse(digits, base)
    ensure!(xml_character?(value), :invalid_xml, "Invalid XML character reference")
    scan!(binary_part(rest, offset + 1, byte_size(rest) - offset - 1), false)
  end

  defp token!(<<_, rest::binary>>, _), do: scan!(rest, false)

  defp terminated!(rest, delimiter) do
    case :binary.match(rest, delimiter) do
      {offset, size} ->
        {binary_part(rest, 0, offset),
         binary_part(rest, offset + size, byte_size(rest) - offset - size)}

      :nomatch ->
        ensure!(false, :invalid_xml, "Unterminated XML markup")
    end
  end

  defp unsupported!,
    do:
      ensure!(
        false,
        :unsupported_xml,
        "DTD, CDATA, and processing instructions are not supported"
      )

  defp xml_character?(value),
    do:
      value in [9, 10, 13] or value in 0x20..0xD7FF or value in 0xE000..0xFFFD or
        value in 0x10000..0x10FFFF
end
