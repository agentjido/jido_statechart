defmodule Jido.Statechart.Runtime.Target do
  @moduledoc "Strict, allowlisted local targets for recoverable Statechart delivery."

  alias Jido.Statechart.Session.Operation
  alias Jido.Statechart.{Diagnostic, Registry, Session}

  defstruct kind: nil, value: nil, entry: nil

  @type kind :: :self | :parent | :invoke | :agent
  @type t :: %__MODULE__{kind: kind(), value: String.t() | nil, entry: Registry.Entry.t() | nil}

  @spec parse(term()) :: {:ok, t()} | {:error, Diagnostic.t()}
  def parse(target) when target in ["#_self", "self"], do: {:ok, %__MODULE__{kind: :self}}
  def parse(target) when target in ["#_parent", "parent"], do: {:ok, %__MODULE__{kind: :parent}}

  def parse("#_invoke." <> id), do: parsed_id(:invoke, id)
  def parse("invoke:" <> id), do: parsed_id(:invoke, id)
  def parse("agent:" <> alias_name), do: parsed_id(:agent, alias_name)
  def parse(_target), do: target_error(:invalid_runtime_target, "Send target grammar is invalid")

  @spec resolve(term(), term(), Registry.t()) :: {:ok, t()} | {:error, Diagnostic.t()}
  def resolve(target, event, %Registry{} = registry) do
    with :ok <- event_name(event),
         {:ok, parsed} <- parse(target) do
      resolve_parsed(parsed, event, registry)
    end
  end

  @spec signal(Operation.t(), Session.t()) ::
          {:ok, Jido.Signal.t()} | {:error, Diagnostic.t()}
  def signal(%Operation{} = operation, %Session{} = session) do
    event = Map.get(operation.correlation, "event")
    data = Map.get(operation.correlation, "data")
    send_id = Map.get(operation.correlation, "send_id")
    turn_id = Map.get(operation.correlation, "turn_id")

    with :ok <- event_name(event),
         {:ok, signal} <-
           Jido.Signal.new(event, data,
             id: operation.id,
             source: "/jido/statechart/#{session.id}"
           ),
         {:ok, signal} <- put_optional(signal, "jidoscsendid", send_id),
         {:ok, signal} <- Jido.Signal.put_context(signal, "jidoscopid", operation.id),
         {:ok, signal} <- Jido.Signal.put_context(signal, "jidoscgen", operation.generation),
         {:ok, signal} <- Jido.Signal.put_context(signal, "jidosceventclass", "external"),
         {:ok, signal} <- Jido.Signal.put_context(signal, "jidoscsessionid", session.id),
         {:ok, signal} <- put_optional(signal, "jidoscturnid", turn_id),
         {:ok, signal} <-
           Jido.Signal.put_context(signal, "jidoscsessionrev", operation.created_revision),
         {:ok, signal} <-
           Jido.Signal.put_context(signal, "jidoscorigintype", "jido.statechart") do
      {:ok, signal}
    else
      {:error, %Diagnostic{} = diagnostic} ->
        {:error, diagnostic}

      {:error, reason} ->
        {:error,
         Diagnostic.new(:invalid_runtime_signal, "Runtime Signal is invalid",
           correction: %{"reason" => signal_error_code(reason)}
         )}
    end
  end

  @spec dispatch(t(), Jido.Signal.t(), String.t(), map()) :: :ok | {:error, term()}
  def dispatch(
        %__MODULE__{kind: :self},
        signal,
        _operation_id,
        %{agent_server: server, runtime_signer: signer}
      )
      when is_function(signer, 1) do
    with {:ok, signal} <- signer.(signal), do: deliver_to_agent(server, signal)
  end

  def dispatch(%__MODULE__{kind: :self}, _signal, _operation_id, _context),
    do: {:error, {:permanent, :self_delivery_not_authenticated}}

  def dispatch(%__MODULE__{kind: kind, entry: entry}, signal, operation_id, context)
      when kind in [:parent, :agent] do
    with :ok <- current_capability(entry),
         :ok <- capability_owner(entry, context) do
      deliver(entry.handler, signal, operation_id, context)
    end
  end

  defp resolve_parsed(%__MODULE__{kind: :self} = target, _event, _registry), do: {:ok, target}

  defp resolve_parsed(%__MODULE__{kind: :invoke}, _event, _registry),
    do:
      target_error(:invoke_target_unsupported, "Invoke delivery requires an active U8 capability")

  defp resolve_parsed(%__MODULE__{kind: :parent} = target, event, registry),
    do: resolve_capability(target, "parent", event, registry)

  defp resolve_parsed(%__MODULE__{kind: :agent, value: name} = target, event, registry) do
    resolve_capability(target, name, event, registry)
  end

  defp resolve_capability(target, name, event, registry) do
    case Registry.fetch(registry, :target, name) do
      {:ok, entry} ->
        with :ok <- target_permissions(entry, event),
             :ok <- local_scope(entry),
             :ok <- idempotent_adapter(entry.handler) do
          {:ok, %{target | entry: entry}}
        end

      :error ->
        target_error(:unknown_runtime_target, "Runtime target is not registered")
    end
  end

  defp target_permissions(entry, event) do
    permissions = entry.permissions
    allowed = Map.get(entry.metadata, "allowed_signal_types")

    cond do
      "send:event" not in permissions and "send:event:#{event}" not in permissions ->
        target_error(:target_permission_denied, "Runtime target cannot send this event")

      "delivery:at_least_once" not in permissions or
          "idempotency:operation_id" not in permissions ->
        target_error(:target_not_idempotent, "Runtime target has no operation-id contract")

      Map.get(entry.metadata, "active", true) != true ->
        target_error(:stale_runtime_target, "Runtime target capability is stale")

      not is_nil(allowed) and (not is_list(allowed) or event not in allowed) ->
        target_error(:target_signal_type_not_allowed, "Runtime target rejects this Signal type")

      true ->
        :ok
    end
  end

  defp local_scope(entry) do
    case Map.get(entry.metadata, "scope", "local_agent") do
      "local_agent" -> :ok
      _other -> target_error(:target_scope_not_allowed, "Runtime target must be a local Agent")
    end
  end

  defp idempotent_adapter(module) when is_atom(module) and not is_nil(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :deliver, 3) and
         function_exported?(module, :idempotency, 0) and module.idempotency() == :operation_id do
      :ok
    else
      target_error(
        :target_not_idempotent,
        "Runtime target adapter is not operation-id idempotent"
      )
    end
  rescue
    _error -> target_error(:target_not_idempotent, "Runtime target adapter is invalid")
  end

  defp idempotent_adapter(_handler),
    do: target_error(:target_not_idempotent, "Runtime target adapter is invalid")

  defp current_capability(entry) do
    if Map.get(entry.metadata, "active", true) == true,
      do: :ok,
      else: {:error, {:permanent, :stale_capability}}
  end

  defp capability_owner(entry, context) do
    agent_id = Map.get(context, :agent_id)

    case Map.get(entry.metadata, "owner_agent_id") do
      nil ->
        :ok

      ^agent_id ->
        :ok

      _other ->
        {:error, {:permanent, :cross_agent_capability}}
    end
  end

  defp deliver(module, signal, operation_id, context) when is_atom(module),
    do: module.deliver(signal, operation_id, context)

  defp deliver_to_agent(server, signal) do
    case Jido.AgentServer.call(server, signal, 5_000) do
      {:ok, _agent} -> :ok
      {:error, {:duplicate_signal, id}} when id == signal.id -> :ok
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, {:uncertain, reason}}
  end

  defp parsed_id(kind, id) do
    case Diagnostic.validate_id(id, [:target]) do
      :ok ->
        {:ok, %__MODULE__{kind: kind, value: id}}

      {:error, _diagnostic} ->
        target_error(:invalid_runtime_target, "Target identifier is invalid")
    end
  end

  defp event_name(value) when is_binary(value) and value != "" do
    if String.valid?(value),
      do: :ok,
      else: target_error(:invalid_runtime_signal, "Event is invalid")
  end

  defp event_name(_value), do: target_error(:invalid_runtime_signal, "Event name is required")

  defp put_optional(signal, _name, nil), do: {:ok, signal}
  defp put_optional(signal, name, value), do: Jido.Signal.put_context(signal, name, value)

  defp signal_error_code(_reason), do: "invalid_signal"

  defp target_error(code, message),
    do: {:error, Diagnostic.new(code, message, path: [:send, :target])}
end
