defmodule Jido.Statechart.EventDescriptor do
  @moduledoc false
  alias Jido.Statechart.Error

  def compile(nil), do: []

  def compile(event) do
    descriptors = String.split(event, [" ", "\t", "\r", "\n"], trim: true)

    if descriptors == [] or length(descriptors) > 32 do
      fail("SCXML transitions require 1 to 32 event descriptors")
    end

    Enum.map(descriptors, fn
      "*" ->
        :any

      descriptor ->
        prefix =
          cond do
            String.ends_with?(descriptor, ".*") ->
              binary_part(descriptor, 0, byte_size(descriptor) - 2)

            String.ends_with?(descriptor, ".") ->
              binary_part(descriptor, 0, byte_size(descriptor) - 1)

            true ->
              descriptor
          end

        if prefix == "" or String.contains?(prefix, "*") or
             Enum.any?(String.split(prefix, "."), &(&1 == "")) do
          fail("Invalid SCXML event descriptor")
        end

        prefix
    end)
  end

  def matches?(:any, _event), do: true
  def matches?(prefix, event), do: event == prefix or String.starts_with?(event, prefix <> ".")

  defp fail(message),
    do:
      throw(
        {:statechart_error, %Error{code: :invalid_definition, message: message, path: [:event]}}
      )
end
