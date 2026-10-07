defmodule Jido.Statechart.SCXML.Lowering do
  @moduledoc false

  alias Jido.Statechart.{Diagnostic, Profile}
  alias Jido.Statechart.Model.{Chart, Executable, Source, State, Transition}

  @scxml "http://www.w3.org/2005/07/scxml"
  @jido "urn:jido:statechart:1"
  @state_elements ~w(state parallel final history)
  @executable_elements ~w(raise if foreach assign log send cancel)

  @spec lower(map(), keyword()) :: {:ok, Chart.t()} | {:error, Diagnostic.t()}
  def lower(root, opts) do
    entries = state_entries(root)

    with {:ok, entries} <- identify_states(entries),
         :ok <- unique_state_ids(entries),
         :ok <- unique_document_ids(root, entries),
         index = Map.new(entries, &{path_key(&1.node), &1.id}),
         {:ok, transition_entries} <- transition_entries(entries),
         :ok <- targets_exist(transition_entries, entries),
         :ok <- legal_target_sets(transition_entries, entries),
         :ok <- initial_targets_valid(root, entries),
         {:ok, states} <- lower_states(entries, transition_entries, index),
         {:ok, transitions} <- lower_transitions(transition_entries),
         {:ok, metadata} <- metadata(root, entries, index),
         {:ok, chart} <-
           Chart.new(%{
             id: chart_id(root, opts),
             name: optional_attribute(root, "name"),
             profile_version: Profile.version(),
             datamodel: optional_attribute(root, "datamodel") || "null",
             binding: optional_attribute(root, "binding") || "early",
             root_state_ids: root_ids(entries),
             states: states,
             transitions: transitions,
             metadata: metadata,
             source: Source.new!(root.source)
           }) do
      {:ok, chart}
    end
  end

  defp state_entries(root) do
    root
    |> child_elements()
    |> Enum.filter(&(local(&1) in @state_elements))
    |> Enum.flat_map(&walk_state(&1, nil))
    |> Enum.with_index()
    |> Enum.map(fn {entry, ordinal} -> Map.put(entry, :ordinal, ordinal) end)
  end

  defp walk_state(node, parent_path) do
    entry = %{node: node, parent_path: parent_path}

    children =
      node
      |> child_elements()
      |> Enum.filter(&(local(&1) in @state_elements))
      |> Enum.flat_map(&walk_state(&1, path_key(node)))

    [entry | children]
  end

  defp identify_states(entries) do
    {:ok,
     Enum.map(entries, fn entry ->
       case optional_attribute(entry.node, "id") do
         nil ->
           Map.merge(entry, %{
             id:
               Chart.generated_id(
                 "state",
                 path_numbers(entry.node.source.path),
                 entry.ordinal
               ),
             generated: true
           })

         id ->
           Map.merge(entry, %{id: id, generated: false})
       end
     end)}
  end

  defp unique_state_ids(entries) do
    entries
    |> Enum.reduce_while(MapSet.new(), fn entry, seen ->
      if MapSet.member?(seen, entry.id) do
        {:halt, error(entry.node, :duplicate_id, "State identifier is duplicated")}
      else
        {:cont, MapSet.put(seen, entry.id)}
      end
    end)
    |> case do
      %MapSet{} -> :ok
      error -> error
    end
  end

  defp unique_document_ids(root, entries) do
    seen =
      entries
      |> Enum.filter(& &1.generated)
      |> MapSet.new(& &1.id)

    root
    |> descendant_elements()
    |> Enum.filter(fn node ->
      match?(
        {@scxml, local} when local in ~w(state parallel final history data send invoke),
        node.name
      )
    end)
    |> Enum.reduce_while(seen, fn node, ids ->
      case optional_attribute(node, "id") do
        nil ->
          {:cont, ids}

        id ->
          if MapSet.member?(ids, id) do
            {:halt, error(node, :duplicate_id, "XML identifier is duplicated")}
          else
            {:cont, MapSet.put(ids, id)}
          end
      end
    end)
    |> case do
      %MapSet{} -> :ok
      error -> error
    end
  end

  defp transition_entries(entries) do
    by_path = Map.new(entries, &{path_key(&1.node), &1})

    entries
    |> Enum.filter(&is_nil(&1.parent_path))
    |> Enum.flat_map(&walk_transitions(&1.node, &1.id, by_path))
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, ordinal}, {:ok, acc} ->
      targets = tokens(optional_attribute(entry.node, "target"))

      if length(targets) == length(Enum.uniq(targets)) do
        value =
          Map.merge(entry, %{
            ordinal: ordinal,
            id:
              Chart.generated_id(
                "transition",
                path_numbers(entry.node.source.path),
                ordinal
              ),
            targets: targets
          })

        {:cont, {:ok, [value | acc]}}
      else
        {:halt, error(entry.node, :illegal_target_set, "Transition target set has a duplicate")}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp walk_transitions(node, source_id, by_path) do
    Enum.flat_map(child_elements(node), fn child ->
      cond do
        local(child) == "transition" ->
          [%{node: child, source_id: source_id}]

        local(child) in @state_elements ->
          entry = Map.fetch!(by_path, path_key(child))
          walk_transitions(child, entry.id, by_path)

        true ->
          []
      end
    end)
  end

  defp targets_exist(transitions, entries) do
    ids = MapSet.new(entries, & &1.id)

    Enum.reduce_while(transitions, :ok, fn transition, :ok ->
      case Enum.find(transition.targets, &(not MapSet.member?(ids, &1))) do
        nil ->
          {:cont, :ok}

        _target ->
          {:halt, error(transition.node, :unknown_state, "Transition target does not exist")}
      end
    end)
  end

  defp legal_target_sets(transitions, entries) do
    by_id = Map.new(entries, &{&1.id, &1})
    parent_by_id = Map.new(entries, &{&1.id, parent_id(&1, entries)})

    Enum.reduce_while(transitions, :ok, fn transition, :ok ->
      case legal_targets?(transition.targets, by_id, parent_by_id) and
             legal_history_targets?(transition, by_id, parent_by_id) do
        true ->
          {:cont, :ok}

        false ->
          source = Map.fetch!(by_id, transition.source_id)

          node =
            if state_kind(source.node) in [:history_shallow, :history_deep],
              do: source.node,
              else: transition.node

          {:halt,
           error(
             node,
             :illegal_target_set,
             "Transition targets cannot form a legal configuration"
           )}
      end
    end)
  end

  defp legal_history_targets?(transition, by_id, parents) do
    case Map.fetch!(by_id, transition.source_id) do
      %{node: node, parent_path: parent_path} when elem(node.name, 1) == "history" ->
        parent =
          Enum.find_value(by_id, fn {id, entry} ->
            if path_key(entry.node) == parent_path, do: id
          end)

        valid_targets? =
          Enum.all?(transition.targets, fn target ->
            state_kind(Map.fetch!(by_id, target).node) not in [:history_shallow, :history_deep]
          end)

        valid_targets? and
          case state_kind(node) do
            :history_shallow -> Enum.all?(transition.targets, &(Map.get(parents, &1) == parent))
            :history_deep -> Enum.all?(transition.targets, &(parent in ancestors(&1, parents)))
          end

      _entry ->
        true
    end
  end

  defp legal_targets?([], _by_id, _parents), do: true
  defp legal_targets?([_one], _by_id, _parents), do: true

  defp legal_targets?(targets, by_id, parents) do
    no_ancestor_pair? =
      Enum.all?(targets, fn target ->
        Enum.all?(targets -- [target], fn other -> target not in ancestors(other, parents) end)
      end)

    lcca = lowest_common_ancestor(targets, parents)

    no_ancestor_pair? and is_binary(lcca) and state_kind(by_id[lcca].node) == :parallel and
      targets
      |> Enum.map(&region_below(&1, lcca, parents))
      |> then(&(nil not in &1 and length(&1) == length(Enum.uniq(&1))))
  end

  defp lowest_common_ancestor([first | rest], parents) do
    candidates = ancestors(first, parents)

    Enum.find(candidates, fn candidate ->
      Enum.all?(rest, &(candidate in ancestors(&1, parents)))
    end)
  end

  defp ancestors(id, parents) do
    case Map.get(parents, id) do
      nil -> []
      parent -> [parent | ancestors(parent, parents)]
    end
  end

  defp region_below(target, ancestor, parents) do
    case Map.get(parents, target) do
      ^ancestor -> target
      nil -> nil
      parent -> region_below(parent, ancestor, parents)
    end
  end

  defp lower_states(entries, transitions, index) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      node = entry.node
      children = direct_state_entries(node, entries)

      transition_ids =
        for transition <- transitions, transition.source_id == entry.id, do: transition.id

      with {:ok, initial} <- initial_targets(node, children),
           {:ok, on_entry} <- handlers(node, "onentry"),
           {:ok, on_exit} <- handlers(node, "onexit"),
           {:ok, data} <- data(node),
           {:ok, done_data} <- done_data(node),
           {:ok, state} <-
             State.new(%{
               id: entry.id,
               ordinal: entry.ordinal,
               kind: state_kind(node),
               parent: Map.get(index, entry.parent_path),
               children: Enum.map(children, & &1.id),
               initial: initial,
               transition_ids: transition_ids,
               on_entry: on_entry,
               on_exit: on_exit,
               data: data,
               done_data: done_data,
               source: Source.new!(node.source),
               generated: entry.generated
             }) do
        {:cont, {:ok, [state | acc]}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp lower_transitions(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      with {:ok, executable} <- executables(entry.node),
           {:ok, transition} <-
             Transition.new(%{
               id: entry.id,
               ordinal: entry.ordinal,
               source_id: entry.source_id,
               target_ids: entry.targets,
               events: tokens(optional_attribute(entry.node, "event")),
               condition: optional_attribute(entry.node, "cond"),
               type: transition_type(entry.node),
               executable: executable,
               source: Source.new!(entry.node.source),
               generated: true
             }) do
        {:cont, {:ok, [transition | acc]}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp handlers(node, handler_name) do
    node
    |> child_elements()
    |> Enum.filter(&(local(&1) == handler_name))
    |> Enum.reduce_while({:ok, []}, fn handler, {:ok, acc} ->
      case executables(handler) do
        {:ok, values} -> {:cont, {:ok, acc ++ values}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp executables(node) do
    node
    |> child_elements()
    |> Enum.filter(&executable?/1)
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {child, ordinal}, {:ok, acc} ->
      case executable(child, ordinal) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp executable(node, ordinal) do
    kind = executable_kind(node)

    child_result =
      if local(node) in ["if", "foreach"], do: executables(node), else: {:ok, []}

    with {:ok, children} <- child_result do
      Executable.new(%{
        kind: kind,
        ordinal: ordinal,
        data: executable_data(node),
        children: children,
        source: Source.new!(node.source)
      })
    end
  end

  defp executable_data(node) do
    params =
      for child <- child_elements(node), local(child) == "param", do: attributes_map(child)

    base = attributes_map(node) |> put_if("params", if(params == [], do: nil, else: params))

    case Enum.find(child_elements(node), &(local(&1) == "content")) do
      nil ->
        case local(node) do
          "if" -> Map.put(base, "branches", branch_partitions(node))
          "assign" -> put_if(base, "content", inline_value(node))
          _other -> base
        end

      content ->
        Map.put(base, "content", content_value(content))
    end
  end

  defp branch_partitions(node) do
    initial = %{
      "kind" => "if",
      "condition" => optional_attribute(node, "cond"),
      "start" => 0,
      "count" => 0
    }

    {branches, current, _index} =
      Enum.reduce(child_elements(node), {[], initial, 0}, fn child, {branches, current, index} ->
        case local(child) do
          marker when marker in ["elseif", "else"] ->
            next = %{
              "kind" => marker,
              "condition" => optional_attribute(child, "cond"),
              "start" => index,
              "count" => 0
            }

            {[current | branches], next, index}

          _other ->
            if executable?(child) do
              {branches, Map.update!(current, "count", &(&1 + 1)), index + 1}
            else
              {branches, current, index}
            end
        end
      end)

    Enum.reverse([current | branches])
  end

  defp executable_kind(%{name: {@jido, "action"}}), do: :action
  defp executable_kind(node), do: String.to_existing_atom(local(node))

  defp executable?(%{name: {@jido, "action"}}), do: true
  defp executable?(%{name: {@scxml, local}}), do: local in @executable_elements
  defp executable?(_node), do: false

  defp data(node) do
    entries =
      node
      |> child_elements()
      |> Enum.filter(&(local(&1) == "datamodel"))
      |> Enum.flat_map(&child_elements/1)
      |> Enum.filter(&(local(&1) == "data"))

    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, fn {data, ordinal}, {:ok, acc} ->
      id = optional_attribute(data, "id")

      if Map.has_key?(acc, id) do
        {:halt, error(data, :duplicate_data_id, "Data identifier is duplicated")}
      else
        value =
          %{"ordinal" => ordinal}
          |> put_if("expr", optional_attribute(data, "expr"))
          |> put_if("content", content_value(data))

        {:cont, {:ok, Map.put(acc, id, value)}}
      end
    end)
  end

  defp done_data(node) do
    case Enum.find(child_elements(node), &(local(&1) == "donedata")) do
      nil -> {:ok, nil}
      done -> {:ok, content_container(done)}
    end
  end

  defp content_container(node) do
    params =
      for param <- child_elements(node), local(param) == "param" do
        attributes_map(param)
      end

    content =
      case Enum.find(child_elements(node), &(local(&1) == "content")) do
        nil -> nil
        child -> content_value(child)
      end

    %{} |> put_if("params", if(params == [], do: nil, else: params)) |> put_if("content", content)
  end

  defp content_value(node) do
    %{"items" => content_items(node.content)}
    |> put_if("expression", optional_attribute(node, "expr"))
  end

  defp inline_value(node) do
    if Enum.any?(node.content, fn
         {:element, _child} -> true
         {kind, text} when kind in [:text, :cdata] -> String.trim(text) != ""
       end) do
      %{"items" => content_items(node.content)}
    end
  end

  defp embedded(node) do
    %{
      "name" => %{"namespace" => elem(node.name, 0), "local" => elem(node.name, 1)},
      "attributes" =>
        Enum.map(node.attributes, fn attribute ->
          %{
            "name" => %{
              "namespace" => elem(attribute.name, 0),
              "local" => elem(attribute.name, 1)
            },
            "value" => attribute.value
          }
        end),
      "content" => content_items(node.content)
    }
  end

  defp content_items(content) do
    Enum.map(content, fn
      {:text, text} -> %{"kind" => "text", "value" => text}
      {:cdata, text} -> %{"kind" => "cdata", "value" => text}
      {:element, child} -> %{"kind" => "element", "value" => embedded(child)}
    end)
  end

  defp metadata(root, entries, index) do
    with {:ok, root_data} <- data(root),
         {:ok, initial_content} <- initial_transition_content(entries, index) do
      {:ok,
       %{
         "root_initial" => root_initial(root, entries),
         "root_data" => root_data,
         "initial_transition_content" => initial_content,
         "invocations" => invocations(entries),
         "profile_manifest_digest" => Profile.manifest()["digest"]
       }}
    end
  end

  defp invocations(entries) do
    Map.new(entries, fn entry ->
      values =
        for child <- child_elements(entry.node), local(child) == "invoke", do: profile_node(child)

      {entry.id, values}
    end)
    |> Enum.reject(fn {_id, values} -> values == [] end)
    |> Map.new()
  end

  defp initial_transition_content(entries, _index) do
    Enum.reduce_while(entries, {:ok, %{}}, fn entry, {:ok, acc} ->
      initial = Enum.find(child_elements(entry.node), &(local(&1) == "initial"))

      case initial && Enum.find(child_elements(initial), &(local(&1) == "transition")) do
        nil ->
          {:cont, {:ok, acc}}

        transition ->
          case executables(transition) do
            {:ok, []} ->
              {:cont, {:ok, acc}}

            {:ok, values} ->
              {:cont, {:ok, Map.put(acc, entry.id, Enum.map(values, &Executable.dump/1))}}

            {:error, _} = error ->
              {:halt, error}
          end
      end
    end)
  end

  defp initial_targets(node, children) do
    if local(node) == "parallel" do
      {:ok, []}
    else
      do_initial_targets(node, children)
    end
  end

  defp do_initial_targets(node, children) do
    target =
      optional_attribute(node, "initial") ||
        explicit_initial(node) ||
        default_initial(children)

    targets = tokens(target)
    {:ok, targets}
  end

  defp explicit_initial(node) do
    with initial when not is_nil(initial) <-
           Enum.find(child_elements(node), &(local(&1) == "initial")),
         transition when not is_nil(transition) <-
           Enum.find(child_elements(initial), &(local(&1) == "transition")) do
      optional_attribute(transition, "target")
    else
      _ -> nil
    end
  end

  defp default_initial(children) do
    case Enum.find(children, &(state_kind(&1.node) not in [:history_shallow, :history_deep])) do
      nil -> nil
      child -> child.id
    end
  end

  defp root_initial(root, entries) do
    optional_attribute(root, "initial")
    |> case do
      nil -> entries |> Enum.filter(&is_nil(&1.parent_path)) |> default_initial()
      value -> value
    end
    |> tokens()
  end

  defp initial_targets_valid(root, entries) do
    by_id = Map.new(entries, &{&1.id, &1})
    parents = Map.new(entries, &{&1.id, parent_id(&1, entries)})

    with :ok <- root_initial_valid(root, entries, by_id, parents) do
      Enum.reduce_while(entries, :ok, fn entry, :ok ->
        children = direct_state_entries(entry.node, entries)
        {:ok, targets} = initial_targets(entry.node, children)

        valid? =
          length(targets) == length(Enum.uniq(targets)) and
            Enum.all?(targets, &Map.has_key?(by_id, &1)) and
            Enum.all?(targets, &(entry.id in ancestors(&1, parents))) and
            legal_targets?(targets, by_id, parents)

        if valid?,
          do: {:cont, :ok},
          else:
            {:halt,
             error(
               entry.node,
               :invalid_initial,
               "Initial targets must be a legal descendant state specification"
             )}
      end)
    end
  end

  defp root_initial_valid(root, entries, by_id, parents) do
    targets = root_initial(root, entries)

    roots =
      targets
      |> Enum.map(&top_level_ancestor(&1, parents))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    valid? =
      targets != [] and length(targets) == length(Enum.uniq(targets)) and
        Enum.all?(targets, &Map.has_key?(by_id, &1)) and length(roots) == 1 and
        legal_targets?(targets, by_id, parents)

    if valid?,
      do: :ok,
      else:
        error(root, :invalid_initial, "Root initial targets must form one legal configuration")
  end

  defp top_level_ancestor(id, parents) do
    case Map.get(parents, id) do
      nil -> if(Map.has_key?(parents, id), do: id)
      parent -> top_level_ancestor(parent, parents)
    end
  end

  defp root_ids(entries), do: for(entry <- entries, is_nil(entry.parent_path), do: entry.id)

  defp chart_id(root, opts) do
    Keyword.get(opts, :id) || valid_name(optional_attribute(root, "name")) ||
      Chart.generated_id("chart", [0], 0)
  end

  defp valid_name(nil), do: nil

  defp valid_name(name) do
    case Diagnostic.validate_id(name, [:chart, :id]) do
      :ok -> name
      _ -> nil
    end
  end

  defp state_kind(node) do
    case local(node) do
      "parallel" ->
        :parallel

      "final" ->
        :final

      "history" ->
        if(optional_attribute(node, "type") == "deep", do: :history_deep, else: :history_shallow)

      "state" ->
        if(Enum.any?(child_elements(node), &(local(&1) in ~w(state parallel final))),
          do: :compound,
          else: :atomic
        )
    end
  end

  defp transition_type(node) do
    case optional_attribute(node, "type") do
      "internal" -> :internal
      _ -> :external
    end
  end

  defp direct_state_entries(node, entries) do
    parent_path = path_key(node)
    Enum.filter(entries, &(&1.parent_path == parent_path))
  end

  defp parent_id(entry, entries) do
    case Enum.find(entries, &(path_key(&1.node) == entry.parent_path)) do
      nil -> nil
      parent -> parent.id
    end
  end

  defp attributes_map(node) do
    Map.new(node.attributes, fn attribute ->
      key =
        case attribute.name do
          {nil, local} -> local
          {uri, local} -> "{#{uri}}#{local}"
        end

      {key, attribute.value}
    end)
  end

  defp optional_attribute(node, name) do
    case Enum.find(node.attributes, &(&1.name == {nil, name})) do
      nil -> nil
      attribute -> attribute.value
    end
  end

  defp child_elements(node), do: for({:element, child} <- node.content, do: child)

  defp descendant_elements(node) do
    Enum.flat_map(child_elements(node), fn child -> [child | descendant_elements(child)] end)
  end

  defp profile_node(node) do
    %{
      "name" => local(node),
      "namespace" => elem(node.name, 0),
      "attributes" => attributes_map(node),
      "content" =>
        Enum.map(node.content, fn
          {:text, text} -> %{"text" => text}
          {:cdata, text} -> %{"cdata" => text}
          {:element, child} -> %{"element" => profile_node(child)}
        end)
    }
  end

  defp local(node), do: elem(node.name, 1)
  defp path_key(node), do: :erlang.term_to_binary(node.source.path, [:deterministic])
  defp path_numbers(path), do: Enum.filter(path, &is_integer/1)

  defp tokens(nil), do: []
  defp tokens(value), do: String.split(value, ~r/[\x20\x09\x0D\x0A]+/u, trim: true)

  defp put_if(map, _key, nil), do: map
  defp put_if(map, _key, %{} = value) when map_size(value) == 0, do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp error(node, code, message) do
    {:error,
     Diagnostic.new(code, message,
       path: node.source.path,
       location: %{"uri" => node.source.uri},
       profile_feature: profile_feature(node)
     )}
  end

  defp profile_feature(node) do
    case local(node) do
      "state" ->
        if(state_kind(node) == :compound, do: "state_compound", else: "state_atomic")

      "parallel" ->
        "state_parallel"

      "final" ->
        "state_final"

      "history" ->
        Atom.to_string(state_kind(node))

      "transition" ->
        "transition_#{transition_type(node)}"

      "invoke" ->
        if(optional_attribute(node, "type") == "jido",
          do: "invoke_jido_element",
          else: "invoke_scxml_element"
        )

      local ->
        "#{local}_element"
    end
  end
end
