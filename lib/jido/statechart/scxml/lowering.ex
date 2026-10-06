defmodule Jido.Statechart.SCXML.Lowering do
  @moduledoc false
  import Jido.Statechart.SCXML.Validation, only: [ensure!: 3]
  alias Jido.Statechart.Limits

  @scxml "http://www.w3.org/2005/07/scxml"
  @jido "urn:jido:statechart:1"

  def to_data!(root, opts) do
    ensure!(root.name == {@scxml, "scxml"}, :invalid_xml, "The root must be SCXML scxml")
    attrs!(root, ["version", "initial", "name", "datamodel"])

    ensure!(
      get(root, "version") == "1.0",
      :unsupported_xml,
      "Only SCXML version 1.0 is supported"
    )

    ensure!(
      get(root, "datamodel", "jido") == "jido",
      :unsupported_xml,
      "Only the Jido registry data model is supported"
    )

    children!(root, ["state", "final"])
    ensure!(root.children != [], :invalid_xml, "SCXML requires a child state")

    limits =
      case Limits.new(Keyword.get(opts, :limits, %{})) do
        {:ok, limits} -> limits
        {:error, error} -> throw({:statechart_error, error})
      end

    counts = count_nodes(root, %{states: 0, transitions: 0})

    ensure!(
      counts.states <= limits.states and counts.transitions <= limits.transitions,
      :limit_exceeded,
      "SCXML exceeds the core state or transition limit"
    )

    %{
      id: Keyword.get(opts, :id, get(root, "name", "scxml")),
      version: Keyword.get(opts, :version, "1"),
      initial: target!(get(root, "initial", get(hd(root.children), "id"))),
      limits: limits,
      states: Enum.flat_map(root.children, &state!(&1, nil))
    }
  end

  defp state!(node, parent) do
    attrs!(node, if(local(node) == "final", do: ["id"], else: ["id", "initial"]))
    id = identity!(get(node, "id"))
    final? = local(node) == "final"

    children!(
      node,
      if(final?,
        do: ["onentry", "onexit"],
        else: ["state", "final", "initial", "onentry", "onexit", "transition"]
      )
    )

    child_states = Enum.filter(node.children, &(local(&1) in ["state", "final"]))
    initials = Enum.filter(node.children, &(local(&1) == "initial"))
    ensure!(length(initials) <= 1, :invalid_xml, "A state can have one initial element")

    ensure!(
      initials == [] or get(node, "initial") == nil,
      :invalid_xml,
      "Initial attribute and element cannot be combined"
    )

    compound? = child_states != []

    ensure!(
      compound? or (initials == [] and get(node, "initial") == nil),
      :invalid_xml,
      "Only compound states can have an initial target"
    )

    initial =
      cond do
        initials != [] -> initial!(hd(initials))
        compound? -> target!(get(node, "initial", get(hd(child_states), "id")))
        true -> nil
      end

    descendants = descendant_ids(child_states)

    transitions =
      node.children
      |> Enum.filter(&(local(&1) == "transition"))
      |> Enum.map(&transition!(&1, compound?, descendants))

    state = %{
      id: id,
      parent: parent,
      type:
        cond do
          final? -> :final
          compound? -> :compound
          true -> :atomic
        end,
      initial: initial,
      entry: handlers!(node, "onentry"),
      exit: handlers!(node, "onexit"),
      transitions: transitions
    }

    [state | Enum.flat_map(child_states, &state!(&1, id))]
  end

  defp transition!(node, compound?, descendants) do
    attrs!(node, ["event", "target", "cond", "type"])

    ensure!(
      Enum.any?(["event", "target", "cond"], &(get(node, &1) != nil)),
      :invalid_xml,
      "A transition requires event, target, or cond"
    )

    target = optional_target!(get(node, "target"))

    guard =
      case get(node, "cond") do
        nil -> nil
        id -> identity!(id)
      end

    kind = get(node, "type", "external")
    ensure!(kind in ["external", "internal"], :unsupported_xml, "Unknown SCXML transition type")
    # SCXML internal transitions retain the source only for compound-to-descendant targets.
    kind =
      if kind == "internal" and compound? and target in descendants,
        do: :internal,
        else: :external

    %{
      event: get(node, "event"),
      event_mode: :scxml,
      target: target,
      guard: guard,
      kind: kind,
      actions: actions!(node)
    }
  end

  defp initial!(node) do
    attrs!(node, [])
    children!(node, ["transition"])
    ensure!(length(node.children) == 1, :invalid_xml, "Initial requires one transition")
    transition = hd(node.children)
    attrs!(transition, ["target"])
    empty!(transition)
    target!(get(transition, "target"))
  end

  defp handlers!(node, name) do
    node.children
    |> Enum.filter(&(local(&1) == name))
    |> Enum.flat_map(fn handler ->
      attrs!(handler, [])
      actions!(handler)
    end)
  end

  defp actions!(node), do: Enum.map(node.children, &action!/1)

  defp action!(%{name: {@scxml, "raise"}} = node) do
    attrs!(node, ["event", {@jido, "data"}])
    empty!(node)
    event = get(node, "event")

    ensure!(
      is_binary(event) and event != "" and !Regex.match?(~r/[ \t\r\n]/, event),
      :invalid_xml,
      "Raise requires one event name"
    )

    %{raise: event, data: json!(Map.get(node.attrs, {@jido, "data"}))}
  end

  defp action!(%{name: {@jido, "action"}} = node) do
    attrs!(node, ["id", "params"])
    empty!(node)
    %{id: identity!(get(node, "id")), params: json!(get(node, "params"))}
  end

  defp action!(%{name: {@jido, "effect"}} = node) do
    attrs!(node, ["id", "data"])
    empty!(node)
    %{effect: identity!(get(node, "id")), data: json!(get(node, "data"))}
  end

  defp action!(_), do: ensure!(false, :unsupported_xml, "Unsupported executable content")

  defp json!(nil), do: %{}

  defp json!(value) do
    case Jason.decode(value) do
      {:ok, map} when is_map(map) -> map
      _ -> ensure!(false, :invalid_xml, "Action payload must be a JSON object")
    end
  end

  defp attrs!(node, allowed) do
    allowed =
      Enum.map(allowed, fn
        name when is_binary(name) -> {nil, name}
        name -> name
      end)

    ensure!(
      Enum.all?(Map.keys(node.attrs), &(&1 in allowed)),
      :unsupported_xml,
      "Unsupported attribute on " <> local(node)
    )
  end

  defp children!(node, allowed),
    do:
      ensure!(
        Enum.all?(node.children, &(&1.name in Enum.map(allowed, fn name -> {@scxml, name} end))),
        :unsupported_xml,
        "Unsupported child of " <> local(node)
      )

  defp empty!(node),
    do: ensure!(node.children == [], :unsupported_xml, "Element must be empty: " <> local(node))

  defp get(node, key, default \\ nil), do: Map.get(node.attrs, {nil, key}, default)
  defp local(node), do: elem(node.name, 1)
  defp optional_target!(nil), do: nil
  defp optional_target!(value), do: target!(value)
  defp target!(value), do: identity!(value)

  defp identity!(value) do
    ensure!(
      is_binary(value) and Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_.:-]*\z/, value),
      :unsupported_xml,
      "IDs and conditions must use registry ID syntax; expressions are not supported"
    )

    value
  end

  defp descendant_ids(nodes),
    do:
      Enum.flat_map(nodes, fn node ->
        [
          get(node, "id")
          | descendant_ids(Enum.filter(node.children, &(local(&1) in ["state", "final"])))
        ]
      end)

  defp count_nodes(%{name: {@scxml, "initial"}}, counts), do: counts

  defp count_nodes(node, counts) do
    counts =
      case node.name do
        {@scxml, type} when type in ["state", "final"] -> Map.update!(counts, :states, &(&1 + 1))
        {@scxml, "transition"} -> Map.update!(counts, :transitions, &(&1 + 1))
        _ -> counts
      end

    Enum.reduce(node.children, counts, &count_nodes/2)
  end
end
