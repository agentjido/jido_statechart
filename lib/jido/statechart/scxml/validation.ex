defmodule Jido.Statechart.SCXML.Validation do
  @moduledoc false

  alias Jido.Statechart.{Diagnostic, Location, Session}

  @scxml "http://www.w3.org/2005/07/scxml"
  @jido "urn:jido:statechart:1"

  @elements ~w(scxml state parallel final initial history transition onentry onexit datamodel data donedata param content raise if elseif else foreach assign log send cancel invoke finalize script)
  @executable_elements ~w(raise if foreach assign log send cancel script)

  @attributes %{
    "scxml" => ~w(version initial name datamodel binding),
    "state" => ~w(id initial),
    "parallel" => ~w(id),
    "final" => ~w(id),
    "initial" => [],
    "history" => ~w(id type),
    "transition" => ~w(event cond target type),
    "onentry" => [],
    "onexit" => [],
    "datamodel" => [],
    "data" => ~w(id src expr),
    "donedata" => [],
    "param" => ~w(name expr location),
    "content" => ~w(expr src),
    "raise" => ~w(event),
    "if" => ~w(cond),
    "elseif" => ~w(cond),
    "else" => [],
    "foreach" => ~w(array item index),
    "assign" => ~w(location expr),
    "log" => ~w(label expr),
    "send" =>
      ~w(event eventexpr target targetexpr type typeexpr id idlocation delay delayexpr namelist),
    "cancel" => ~w(sendid sendidexpr),
    "invoke" => ~w(type typeexpr src srcexpr id idlocation namelist autoforward),
    "finalize" => [],
    "script" => ~w(src)
  }

  @parents %{
    "state" => ~w(scxml state parallel),
    "parallel" => ~w(scxml state parallel),
    "final" => ~w(scxml state),
    "initial" => ~w(state),
    "history" => ~w(state parallel),
    "transition" => ~w(state parallel initial history),
    "onentry" => ~w(state parallel final),
    "onexit" => ~w(state parallel final),
    "datamodel" => ~w(scxml state parallel),
    "data" => ~w(datamodel),
    "donedata" => ~w(final),
    "param" => ~w(send invoke donedata),
    "content" => ~w(send invoke donedata),
    "raise" => ~w(onentry onexit transition if foreach finalize),
    "if" => ~w(onentry onexit transition if foreach finalize),
    "elseif" => ~w(if),
    "else" => ~w(if),
    "foreach" => ~w(onentry onexit transition if foreach finalize),
    "assign" => ~w(onentry onexit transition if foreach finalize),
    "log" => ~w(onentry onexit transition if foreach finalize),
    "send" => ~w(onentry onexit transition if foreach finalize),
    "cancel" => ~w(onentry onexit transition if foreach finalize),
    "invoke" => ~w(state parallel),
    "finalize" => ~w(invoke),
    "script" => ~w(scxml state parallel onentry onexit transition if foreach finalize)
  }

  @spec validate(map()) :: :ok | {:error, Diagnostic.t()}
  def validate(%{name: {@scxml, "scxml"}} = root) do
    with :ok <- attributes(root),
         :ok <- required_value(root, "version"),
         :ok <- value(root, "version", ["1.0"], :unsupported_scxml_version),
         :ok <- optional_value(root, "datamodel", ["null", "jido"], :unsupported_datamodel),
         :ok <- optional_value(root, "binding", ["early", "late"], :unsupported_binding),
         :ok <- nonempty_if_present(root, "name"),
         :ok <- idrefs_if_present(root, "initial"),
         :ok <- maximum_children(root, "datamodel", 1),
         :ok <- validate_children(root, "scxml"),
         :ok <- null_action_content(root),
         :ok <- root_states(root) do
      :ok
    end
  end

  def validate(root) do
    error(root, :invalid_scxml_root, "Root element must be scxml in the SCXML namespace",
      profile_feature: "scxml_element"
    )
  end

  defp validate_children(node, parent) do
    node.content
    |> Enum.reduce_while(:ok, fn
      {kind, text}, :ok when kind in [:text, :cdata] ->
        if text_allowed?(parent) or String.trim(text) == "" do
          {:cont, :ok}
        else
          {:halt, error(node, :unexpected_xml_text, "Element does not allow text content")}
        end

      {:element, child}, :ok ->
        case validate_child(child, parent) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
    end)
  end

  defp validate_child(child, parent) when parent in ["content", "data", "assign"] do
    validate_embedded(child)
  end

  defp validate_child(%{name: {@scxml, local}} = child, parent) when local in @elements do
    cond do
      local == "script" ->
        error(child, :unsupported_script, "The Jido SCXML Profile does not execute script",
          profile_feature: "script_element"
        )

      parent not in Map.get(@parents, local, []) ->
        error(child, :invalid_element_placement, "SCXML element is not valid in this location",
          profile_feature: profile_feature(child)
        )

      true ->
        with :ok <- attributes(child),
             :ok <- element_values(child, local),
             :ok <- validate_children(child, local),
             :ok <- element_structure(child, local) do
          :ok
        end
    end
  end

  defp validate_child(%{name: {@scxml, _local}} = child, _parent) do
    error(child, :unknown_profile_element, "SCXML element is not in the Jido profile",
      profile_feature: "unknown_element"
    )
  end

  defp validate_child(%{name: {@jido, "action"}} = child, parent) do
    if parent in ~w(onentry onexit transition if foreach finalize) do
      with :ok <- jido_action_attributes(child), do: validate_children(child, "action")
    else
      error(child, :invalid_element_placement, "Jido action is not valid in this location",
        profile_feature: "jido_action_extension"
      )
    end
  end

  defp validate_child(child, _parent) do
    error(
      child,
      :unknown_profile_element,
      "Foreign executable element is not in the Jido profile",
      profile_feature: "unknown_element"
    )
  end

  defp validate_embedded(node) do
    node.content
    |> Enum.reduce_while(:ok, fn
      {kind, _text}, :ok when kind in [:text, :cdata] ->
        {:cont, :ok}

      {:element, child}, :ok ->
        case validate_embedded(child) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
    end)
  end

  defp attributes(node) do
    local = elem(node.name, 1)
    allowed = Map.fetch!(@attributes, local)

    Enum.reduce_while(node.attributes, :ok, fn attribute, :ok ->
      case attribute.name do
        {nil, name} ->
          if name in allowed do
            {:cont, :ok}
          else
            {:halt,
             error(
               node,
               :unknown_profile_attribute,
               "Attribute is not in the Jido SCXML Profile",
               profile_feature: profile_feature(node)
             )}
          end

        _ ->
          {:halt,
           error(node, :unknown_profile_attribute, "Attribute is not in the Jido SCXML Profile",
             profile_feature: profile_feature(node)
           )}
      end
    end)
  end

  defp jido_action_attributes(node) do
    with :ok <- only_unqualified(node, ~w(id params)),
         :ok <- required_value(node, "id") do
      :ok
    end
  end

  defp only_unqualified(node, allowed) do
    if Enum.all?(node.attributes, fn
         %{name: {nil, value}} -> value in allowed
         _attribute -> false
       end) do
      :ok
    else
      error(node, :unknown_profile_attribute, "Jido action attribute is not supported",
        profile_feature: "jido_action_extension"
      )
    end
  end

  defp element_values(node, "state") do
    initial_children = Enum.filter(elements(node), &(elem(&1.name, 1) == "initial"))
    state_children = Enum.filter(elements(node), &(elem(&1.name, 1) in ~w(state parallel final)))

    with :ok <- optional_identifier(node, "id"),
         :ok <- maximum_children(node, "datamodel", 1),
         :ok <- idrefs_if_present(node, "initial"),
         true <- length(initial_children) <= 1,
         true <- not (present?(node, "initial") and initial_children != []),
         true <-
           (not present?(node, "initial") and initial_children == []) or state_children != [] do
      :ok
    else
      false -> error(node, :invalid_initial, "State initial declaration is ambiguous")
      {:error, _} = error -> error
    end
  end

  defp element_values(node, "parallel") do
    children = Enum.filter(elements(node), &(elem(&1.name, 1) in ~w(state parallel)))

    with :ok <- optional_identifier(node, "id"),
         :ok <- maximum_children(node, "datamodel", 1),
         true <- children != [] do
      :ok
    else
      false -> error(node, :invalid_parallel, "Parallel state requires at least one region")
      {:error, _} = error -> error
    end
  end

  defp element_values(node, "final") do
    with :ok <- optional_identifier(node, "id"),
         :ok <- maximum_children(node, "donedata", 1) do
      :ok
    end
  end

  defp element_values(node, "history") do
    transitions = Enum.filter(elements(node), &(elem(&1.name, 1) == "transition"))

    with :ok <- optional_identifier(node, "id"),
         :ok <- optional_value(node, "type", ["shallow", "deep"], :invalid_history_type),
         true <- length(transitions) == 1,
         [transition] = transitions,
         true <- present?(transition, "target"),
         true <- Enum.all?(~w(event cond), &(not present?(transition, &1))) do
      :ok
    else
      false ->
        error(node, :invalid_history, "History state requires one target-only default transition")

      {:error, _} = error ->
        error
    end
  end

  defp element_values(node, "initial") do
    transitions = Enum.filter(elements(node), &(elem(&1.name, 1) == "transition"))

    case transitions do
      [transition] ->
        if present?(transition, "target") and
             Enum.all?(~w(event cond type), &(not present?(transition, &1))) do
          :ok
        else
          error(node, :invalid_initial, "Initial transition must contain only a target")
        end

      _ ->
        error(node, :invalid_initial, "Initial element requires one transition")
    end
  end

  defp element_values(node, "transition") do
    with :ok <- optional_value(node, "type", ["internal", "external"], :invalid_transition_type),
         :ok <- nonempty_if_present(node, "event"),
         :ok <- idrefs_if_present(node, "target"),
         :ok <- nonempty_if_present(node, "cond"),
         true <- Enum.any?(~w(event cond target), &present?(node, &1)) do
      :ok
    else
      false -> error(node, :invalid_transition, "Transition requires event, condition, or target")
      {:error, _} = error -> error
    end
  end

  defp element_values(node, "data") do
    with :ok <- required_value(node, "id"),
         :ok <- optional_identifier(node, "id"),
         :ok <- location_segment_identifier(node, "id"),
         :ok <- external_source(node),
         :ok <- at_most_one_value(node, ~w(src expr), meaningful_content?(node)) do
      :ok
    end
  end

  defp element_values(node, "content") do
    with :ok <- external_source(node),
         :ok <- at_most_one_value(node, ~w(src expr), meaningful_content?(node)) do
      :ok
    end
  end

  defp element_values(node, "param") do
    with :ok <- required_value(node, "name"),
         :ok <- exactly_one_attribute(node, ~w(expr location)),
         :ok <- empty_content(node) do
      :ok
    end
  end

  defp element_values(node, "raise"), do: required_value(node, "event")

  defp element_values(node, "if") do
    with :ok <- required_value(node, "cond"), do: valid_if_markers(node)
  end

  defp element_values(node, "elseif") do
    with :ok <- required_value(node, "cond"), do: empty_content(node)
  end

  defp element_values(node, "else"), do: empty_content(node)

  defp element_values(node, "foreach") do
    with :ok <- required_value(node, "array"),
         :ok <- required_value(node, "item"),
         true <- executable_content?(node) do
      :ok
    else
      false ->
        error(
          node,
          :invalid_element_cardinality,
          "Foreach requires executable content"
        )

      {:error, _} = error ->
        error
    end
  end

  defp element_values(node, "assign") do
    with :ok <- required_value(node, "location"),
         true <- present?(node, "expr") != meaningful_content?(node) do
      :ok
    else
      false -> mutually_exclusive(node, "Assign requires exactly one value source")
      {:error, _} = error -> error
    end
  end

  defp element_values(node, "cancel") do
    cond do
      present?(node, "sendid") == present?(node, "sendidexpr") ->
        error(node, :invalid_cancel, "Cancel requires exactly one send identifier")

      present?(node, "sendid") ->
        optional_identifier(node, "sendid")

      true ->
        :ok
    end
  end

  defp element_values(node, "send") do
    contents = children_named(node, "content")
    params = children_named(node, "param")

    with :ok <- optional_identifier(node, "id"),
         :ok <-
           mutually_exclusive_pairs(node, [
             ~w(event eventexpr),
             ~w(target targetexpr),
             ~w(type typeexpr),
             ~w(id idlocation),
             ~w(delay delayexpr)
           ]),
         :ok <- maximum_children(node, "content", 1),
         :ok <- exactly_one_send_payload(node, contents),
         true <-
           not (attribute(node, "target") in ["_internal", "#_internal"] and
                  Enum.any?(~w(delay delayexpr), &present?(node, &1))),
         true <- not (contents != [] and (present?(node, "namelist") or params != [])) do
      :ok
    else
      false -> mutually_exclusive(node, "Send attributes or content are mutually exclusive")
      {:error, _} = error -> error
    end
  end

  defp element_values(node, "invoke") do
    contents = children_named(node, "content")
    params = children_named(node, "param")

    with :ok <- optional_identifier(node, "id"),
         :ok <- invocation_source(node, "src"),
         :ok <- invocation_source(node, "srcexpr"),
         :ok <- optional_value(node, "autoforward", ["true", "false"], :invalid_autoforward),
         :ok <- mutually_exclusive_pairs(node, [~w(type typeexpr), ~w(id idlocation)]),
         :ok <- at_most_one_value(node, ~w(src srcexpr), contents != []),
         :ok <- maximum_children(node, "content", 1),
         :ok <- maximum_children(node, "finalize", 1),
         true <- not (present?(node, "namelist") and params != []) do
      :ok
    else
      false -> mutually_exclusive(node, "Invoke namelist excludes param")
      {:error, _} = error -> error
    end
  end

  defp element_values(node, "donedata") do
    contents = children_named(node, "content")
    params = children_named(node, "param")

    with :ok <- maximum_children(node, "content", 1),
         true <- (length(contents) == 1 and params == []) or (contents == [] and params != []) do
      :ok
    else
      false -> mutually_exclusive(node, "Done data requires content or param, but not both")
      {:error, _} = error -> error
    end
  end

  defp element_values(node, "scxml"), do: maximum_children(node, "datamodel", 1)

  defp element_values(_node, _local), do: :ok

  defp element_structure(node, "state") do
    state_children = Enum.filter(elements(node), &(elem(&1.name, 1) in ~w(state parallel final)))
    valid_history_parent(node, state_children)
  end

  defp element_structure(_node, _local), do: :ok

  defp external_source(node) do
    if present?(node, "src") do
      feature =
        if elem(node.name, 1) == "content",
          do: "external_content_source",
          else: "external_data_source"

      error(
        node,
        :external_source_unsupported,
        "External XML resources are not supported",
        profile_feature: feature,
        correction: %{"supply_inline_content" => true}
      )
    else
      :ok
    end
  end

  defp root_states(root) do
    if Enum.any?(elements(root), fn child -> elem(child.name, 1) in ~w(state parallel final) end) do
      :ok
    else
      error(root, :missing_root_state, "SCXML document requires a top-level state")
    end
  end

  defp valid_history_parent(node, state_children) do
    case children_named(node, "history") do
      [] ->
        :ok

      [history | _rest] when state_children == [] ->
        error(history, :invalid_history, "History requires a compound parent state")

      _histories ->
        :ok
    end
  end

  defp maximum_children(node, local, maximum) do
    if length(children_named(node, local)) <= maximum do
      :ok
    else
      error(node, :invalid_element_cardinality, "SCXML child element cardinality is invalid")
    end
  end

  defp exactly_one_attribute(node, names) do
    if Enum.count(names, &present?(node, &1)) == 1 do
      :ok
    else
      mutually_exclusive(node, "Exactly one SCXML attribute is required")
    end
  end

  defp mutually_exclusive_pairs(node, pairs) do
    case Enum.find(pairs, fn names -> Enum.count(names, &present?(node, &1)) > 1 end) do
      nil -> :ok
      _pair -> mutually_exclusive(node, "SCXML attributes are mutually exclusive")
    end
  end

  defp at_most_one_value(node, names, has_content) do
    count = Enum.count(names, &present?(node, &1)) + if(has_content, do: 1, else: 0)

    if count <= 1,
      do: :ok,
      else: mutually_exclusive(node, "SCXML value sources are mutually exclusive")
  end

  defp exactly_one_send_payload(node, contents) do
    count = Enum.count(~w(event eventexpr), &present?(node, &1)) + length(contents)

    if count == 1,
      do: :ok,
      else: mutually_exclusive(node, "Send requires exactly one event or content source")
  end

  defp meaningful_content?(node) do
    Enum.any?(node.content, fn
      {:element, _child} -> true
      {kind, text} when kind in [:text, :cdata] -> String.trim(text) != ""
    end)
  end

  defp executable_content?(node) do
    Enum.any?(elements(node), fn
      %{name: {@scxml, local}} -> local in @executable_elements
      %{name: {@jido, "action"}} -> true
      _child -> false
    end)
  end

  defp empty_content(node) do
    if meaningful_content?(node),
      do: error(node, :invalid_element_cardinality, "SCXML element must be empty"),
      else: :ok
  end

  defp valid_if_markers(node) do
    markers = Enum.filter(elements(node), &(elem(&1.name, 1) in ~w(elseif else)))

    else_positions =
      markers
      |> Enum.with_index()
      |> Enum.filter(fn {item, _} -> elem(item.name, 1) == "else" end)

    cond do
      length(else_positions) > 1 ->
        error(node, :invalid_element_cardinality, "If allows at most one else marker")

      match?([{_marker, position}] when position != length(markers) - 1, else_positions) ->
        mutually_exclusive(node, "Else must follow all elseif markers")

      true ->
        :ok
    end
  end

  defp mutually_exclusive(node, message) do
    error(node, :mutually_exclusive_content, message)
  end

  defp required_value(node, name) do
    case attribute(node, name) do
      value when is_binary(value) and value != "" -> :ok
      _ -> error(node, :missing_required_attribute, "Required SCXML attribute is missing")
    end
  end

  defp nonempty_if_present(node, name) do
    case attribute(node, name) do
      nil -> :ok
      "" -> error(node, :invalid_attribute_value, "SCXML attribute cannot be empty")
      _value -> :ok
    end
  end

  defp optional_identifier(node, name) do
    case attribute(node, name) do
      nil ->
        :ok

      value ->
        case Diagnostic.validate_id(value, node.source.path ++ [name]) do
          :ok ->
            if String.starts_with?(value, Session.generated_id_prefix()) do
              error(
                node,
                :reserved_generated_id,
                "SCXML authors cannot use the processor-generated identifier prefix"
              )
            else
              :ok
            end

          {:error, diagnostic} ->
            {:error,
             %{
               diagnostic
               | location: location(node),
                 profile_feature: profile_feature(node)
             }}
        end
    end
  end

  defp location_segment_identifier(node, name) do
    case Location.parse(attribute(node, name)) do
      {:ok, [_segment]} ->
        :ok

      _other ->
        error(node, :invalid_id, "Data identifier must be one legal location segment")
    end
  end

  defp idrefs_if_present(node, name) do
    case attribute(node, name) do
      nil ->
        :ok

      value ->
        values = String.split(value, ~r/[\x20\x09\x0D\x0A]+/u, trim: true)

        if values != [] and length(values) == length(Enum.uniq(values)) do
          Enum.reduce_while(values, :ok, fn id, :ok ->
            case Diagnostic.validate_id(id, node.source.path ++ [name]) do
              :ok ->
                {:cont, :ok}

              {:error, diagnostic} ->
                {:halt,
                 {:error,
                  %{
                    diagnostic
                    | location: location(node),
                      profile_feature: profile_feature(node)
                  }}}
            end
          end)
        else
          error(node, :invalid_id_list, "SCXML identifier list is invalid")
        end
    end
  end

  defp invocation_source(node, name) do
    case attribute(node, name) do
      nil ->
        :ok

      _value ->
        case optional_identifier(node, name) do
          :ok ->
            :ok

          {:error, _diagnostic} when name == "src" ->
            error(
              node,
              :external_source_unsupported,
              "Invoke source must be a registered local capability alias",
              profile_feature: "remote_invocation",
              correction: %{"register_local_alias" => true}
            )

          {:error, _} = error ->
            error
        end
    end
  end

  defp value(node, name, values, code) do
    if attribute(node, name) in values,
      do: :ok,
      else: error(node, code, "SCXML attribute value is not supported")
  end

  defp optional_value(node, name, values, code) do
    case attribute(node, name) do
      nil ->
        :ok

      value ->
        if value in values,
          do: :ok,
          else: error(node, code, "SCXML attribute value is not supported")
    end
  end

  defp attribute(node, name) do
    case Enum.find(node.attributes, &(&1.name == {nil, name})) do
      nil -> nil
      attribute -> attribute.value
    end
  end

  defp present?(node, name), do: attribute(node, name) != nil

  defp elements(node) do
    for {:element, child} <- node.content, do: child
  end

  defp null_action_content(root) do
    if attribute(root, "datamodel") in [nil, "null"] do
      case find_jido_action(root) do
        nil ->
          :ok

        action ->
          error(action, :null_action_forbidden, "The null data model cannot execute Actions",
            profile_feature: "jido_action_extension"
          )
      end
    else
      :ok
    end
  end

  defp find_jido_action(node) do
    Enum.find_value(elements(node), fn child ->
      if child.name == {@jido, "action"}, do: child, else: find_jido_action(child)
    end)
  end

  defp children_named(node, local) do
    Enum.filter(elements(node), &(elem(&1.name, 1) == local))
  end

  defp text_allowed?(local), do: local in ["content", "data", "assign"]

  defp error(node, code, message, opts \\ []) do
    {:error,
     Diagnostic.new(code, message,
       path: node.source.path,
       location: location(node),
       profile_feature: Keyword.get(opts, :profile_feature, profile_feature(node)),
       correction: Keyword.get(opts, :correction, %{})
     )}
  end

  defp location(node), do: %{"uri" => node.source.uri}

  defp profile_feature(node) do
    case elem(node.name, 1) do
      "state" ->
        if Enum.any?(elements(node), &(elem(&1.name, 1) in ~w(state parallel final))),
          do: "state_compound",
          else: "state_atomic"

      "parallel" ->
        "state_parallel"

      "final" ->
        "state_final"

      "history" ->
        if attribute(node, "type") == "deep", do: "history_deep", else: "history_shallow"

      "transition" ->
        if attribute(node, "type") == "internal",
          do: "transition_internal",
          else: "transition_external"

      "invoke" ->
        if attribute(node, "type") == "jido",
          do: "invoke_jido_element",
          else: "invoke_scxml_element"

      local ->
        "#{local}_element"
    end
  end
end
