defmodule Jido.Statechart.Runtime.Intent do
  @moduledoc "Materializes complete immutable runtime intent during a macrostep."

  alias Jido.Statechart.Runtime.{Invocation, Target, Timer}
  alias Jido.Statechart.Session.Operation
  alias Jido.Statechart.{Diagnostic, Limits, Registry, Session}

  @scxml_processor "http://www.w3.org/TR/scxml/#SCXMLEventProcessor"

  @spec from_semantic(
          map(),
          Session.t(),
          Registry.t(),
          Limits.t(),
          DateTime.t() | String.t(),
          keyword()
        ) :: {:ok, Operation.t()} | {:error, Diagnostic.t()}
  def from_semantic(value, session, registry, limits, now, options \\ [])

  def from_semantic(
        %{} = value,
        %Session{} = session,
        %Registry{} = registry,
        %Limits{} = limits,
        now,
        options
      )
      when not is_struct(value) and is_list(options) do
    generation = Keyword.get(options, :generation, session.operation_counter)
    created_revision = Keyword.get(options, :created_revision, session.revision)

    case Diagnostic.fetch(value, :kind) do
      kind when kind in [:send, "send"] ->
        send_intent(value, session, registry, limits, now, generation, created_revision)

      kind when kind in [:cancel, "cancel"] ->
        cancel_intent(value, session, generation, created_revision)

      kind
      when kind in [:invoke, "invoke", :stop_invoke, "stop_invoke", :invoke_send, "invoke_send"] ->
        Invocation.from_semantic(value, session, registry, limits, now,
          generation: generation,
          created_revision: created_revision,
          prior_operations: Keyword.get(options, :prior_operations, [])
        )

      _other ->
        {:error, Diagnostic.new(:invalid_operation_kind, "Runtime intent kind is invalid")}
    end
  end

  def from_semantic(_value, _session, _registry, _limits, _now, _options),
    do: {:error, Diagnostic.new(:invalid_runtime_intent, "Runtime intent is invalid")}

  defp send_intent(value, session, registry, limits, now, generation, revision) do
    event = Diagnostic.fetch(value, :event)
    target = Diagnostic.fetch(value, :target) || "#_self"
    type = Diagnostic.fetch(value, :type)
    send_id = Diagnostic.fetch(value, :send_id)

    with :ok <- static_target(value),
         :ok <- event_type(type),
         {:ok, resolved} <- Target.resolve(target, event, registry),
         {:ok, due_at} <- Timer.due_at(Diagnostic.fetch(value, :delay), now, limits),
         :ok <- send_id(send_id),
         correlation <-
           value
           |> stringify()
           |> Map.put("target", target_text(resolved, target))
           |> Map.put("due_at", due_at)
           |> Map.delete("delay"),
         :ok <- Diagnostic.portable(correlation, [:runtime, :intent]) do
      Operation.new(%{
        session_incarnation: session.incarnation,
        kind: if(due_at, do: :timer, else: :send),
        target: correlation["target"],
        key: if(send_id, do: "send:" <> send_id),
        payload_digest: Diagnostic.digest(correlation),
        due_at: due_at,
        generation: generation,
        created_revision: revision,
        correlation: correlation
      })
    end
  end

  defp cancel_intent(value, session, generation, revision) do
    send_id = Diagnostic.fetch(value, :send_id)

    with :ok <- required_send_id(send_id),
         correlation <- %{"kind" => "cancel", "send_id" => send_id} do
      Operation.new(%{
        session_incarnation: session.incarnation,
        kind: :cancel,
        target: "send:" <> send_id,
        key: "send:" <> send_id,
        payload_digest: Diagnostic.digest(correlation),
        generation: generation,
        created_revision: revision,
        correlation: correlation
      })
    end
  end

  defp event_type(nil), do: :ok
  defp event_type(@scxml_processor), do: :ok

  defp event_type(_other),
    do: {:error, Diagnostic.new(:unsupported_send_type, "Send type is unsupported")}

  defp static_target(value) do
    if Diagnostic.fetch(value, :target_selected, false) do
      {:error,
       Diagnostic.new(
         :dynamic_runtime_target,
         "Runtime send target must be a static allowlisted target"
       )}
    else
      :ok
    end
  end

  defp send_id(nil), do: :ok
  defp send_id(value), do: required_send_id(value)

  defp required_send_id(value) when is_binary(value) and value != "" do
    Diagnostic.validate_id(value, [:send, :id])
  end

  defp required_send_id(_value),
    do: {:error, Diagnostic.new(:invalid_send_id, "Send ID is invalid", path: [:send, :id])}

  defp target_text(%Target{}, target) when is_binary(target), do: target

  defp stringify(value) do
    Map.new(value, fn {key, item} -> {to_string(key), item} end)
  end
end
