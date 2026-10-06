defmodule Jido.Statechart.SCXML do
  @moduledoc """
  Compiles a restricted SCXML 1.0 document into the core Definition.

  XML is parsed once. The interpreter does not read XML. Guards and actions
  refer to trusted registry IDs; the adapter does not evaluate expressions.
  See the SCXML guide for the supported elements and semantic restrictions.

  Saxy is an optional dependency. Add `{:saxy, "~> 1.6"}` to the consumer.
  This API accepts UTF-8 XML bytes. The caller owns file and resource access.

  Options: `:id` and `:version` set the chart identity and behavior version;
  `:limits` lowers core limits; `:xml_limits` lowers parser limits. XML limits
  are `:bytes`, `:depth`, `:elements`, `:attributes`, `:attribute_bytes`,
  `:name_bytes`, and `:text_bytes`. Unknown or duplicate options are errors.
  """
  import Jido.Statechart.SCXML.Validation, only: [ensure!: 3]
  alias Jido.Statechart.{Compiler, Definition, Error}
  alias Jido.Statechart.SCXML.{Handler, Lowering, Security}

  @limits %{
    bytes: 1_048_576,
    depth: 64,
    elements: 16_384,
    attributes: 16,
    attribute_bytes: 4096,
    name_bytes: 256,
    text_bytes: 65_536
  }

  @doc "Compiles XML bytes. Returns a typed error for unsupported or invalid input."
  @spec compile(term(), keyword()) :: {:ok, Definition.t()} | {:error, Error.t()}
  def compile(xml, opts \\ []) do
    ensure!(Keyword.keyword?(opts), :invalid_xml, "SCXML options must be a keyword list")
    keys = Keyword.keys(opts)

    ensure!(
      keys -- [:id, :version, :limits, :xml_limits] == [] and keys == Enum.uniq(keys),
      :invalid_xml,
      "Unknown or duplicate SCXML option"
    )

    limits = xml_limits!(Keyword.get(opts, :xml_limits, %{}))
    xml = Security.validate!(xml, limits)

    ensure!(
      Code.ensure_loaded?(Saxy),
      :parser_unavailable,
      "SCXML requires the optional Saxy dependency"
    )

    state = %{limits: limits, stack: [], root: nil, elements: 0, text_bytes: 0}

    case apply(Saxy, :parse_string, [
           xml,
           Handler,
           state,
           [expand_entity: {Security, :reject_entity!, []}, cdata_as_characters: false]
         ]) do
      {:ok, %{root: root, stack: []}} when root != nil ->
        root |> Lowering.to_data!(opts) |> Compiler.compile()

      _ ->
        Error.result(:invalid_xml, "Malformed XML document")
    end
  rescue
    _ -> Error.result(:invalid_xml, "Malformed XML document")
  catch
    {:statechart_error, error} -> {:error, error}
  end

  @doc "Compiles XML or raises its typed error."
  @spec compile!(term(), keyword()) :: Definition.t() | no_return()
  def compile!(xml, opts \\ []) do
    case compile(xml, opts) do
      {:ok, definition} -> definition
      {:error, error} -> raise error
    end
  end

  @doc "Returns the hard XML limits. A caller can only lower them."
  @spec limits() :: map()
  def limits, do: @limits

  defp xml_limits!(overrides) do
    ensure!(
      is_map(overrides) and not is_struct(overrides),
      :invalid_limit,
      "XML limits must be a map"
    )

    ensure!(map_size(overrides) <= map_size(@limits), :invalid_limit, "Too many XML limits")

    {limits, _seen} =
      Enum.reduce(overrides, {@limits, []}, fn {key, value}, {limits, seen} ->
        field =
          Enum.find(Map.keys(@limits), fn field ->
            key == field or key == Atom.to_string(field)
          end)

        ensure!(
          field != nil and field not in seen and is_integer(value) and value > 0 and
            value <= @limits[field],
          :invalid_limit,
          "Invalid, duplicate, or raised XML limit"
        )

        {Map.put(limits, field, value), [field | seen]}
      end)

    limits
  end
end
