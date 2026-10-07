defmodule Jido.Statechart.Runtime.Server do
  @moduledoc false

  alias Jido.Statechart.Runtime.Target
  alias Jido.Statechart.Session.Operation
  alias Jido.Statechart.{Registry, Session}

  @spec dispatch(Operation.t(), Session.t(), Registry.t(), map(), keyword()) ::
          {:confirmed_complete | :result_unknown | :retryable_failure | :permanent_failure, map()}
  def dispatch(
        %Operation{} = operation,
        %Session{} = session,
        %Registry{} = registry,
        context,
        options
      ) do
    event = Map.get(operation.correlation, "event")

    result =
      with {:ok, target} <- Target.resolve(operation.target, event, registry),
           {:ok, signal} <- Target.signal(operation, session) do
        Target.dispatch(target, signal, operation.id, context)
      end

    classify(result, operation, options)
  catch
    kind, _reason -> classify({:error, {:uncertain, kind}}, operation, options)
  end

  defp classify(:ok, operation, _options) do
    {:confirmed_complete,
     %{
       "attempt" => operation.attempt_count,
       "operation_id" => operation.id,
       "outcome" => "delivered"
     }}
  end

  defp classify({:error, {:permanent, reason}}, operation, _options),
    do: permanent(operation, reason)

  defp classify({:error, {:retryable, reason}}, operation, options) do
    retry_limit = Keyword.get(options, :retry_limit, 3)

    if operation.attempt_count >= retry_limit do
      permanent(operation, reason)
    else
      backoff = Keyword.get(options, :retry_backoff_ms, 100)
      exponent = max(operation.attempt_count - 1, 0)
      delay = min(backoff * Integer.pow(2, exponent), 60_000)
      due = DateTime.utc_now() |> DateTime.add(delay, :millisecond) |> DateTime.to_iso8601()

      {:retryable_failure,
       %{
         "attempt" => operation.attempt_count,
         "next_attempt_at" => due,
         "operation_id" => operation.id,
         "outcome" => "retryable_failure",
         "reason" => reason_code(reason)
       }}
    end
  end

  defp classify({:error, {:uncertain, reason}}, operation, options),
    do: unknown(operation, reason, options)

  defp classify({:error, %Jido.Statechart.Diagnostic{} = diagnostic}, operation, _options),
    do: permanent(operation, diagnostic.code)

  defp classify({:error, reason}, operation, options),
    do: unknown(operation, reason, options)

  defp unknown(operation, reason, options) do
    backoff = Keyword.get(options, :retry_backoff_ms, 100)
    exponent = max(operation.attempt_count - 1, 0)
    delay = min(backoff * Integer.pow(2, exponent), 60_000)
    due = DateTime.utc_now() |> DateTime.add(delay, :millisecond) |> DateTime.to_iso8601()

    {:result_unknown,
     %{
       "attempt" => operation.attempt_count,
       "next_attempt_at" => due,
       "operation_id" => operation.id,
       "outcome" => "result_unknown",
       "reason" => reason_code(reason)
     }}
  end

  defp permanent(operation, reason) do
    {:permanent_failure,
     %{
       "attempt" => operation.attempt_count,
       "operation_id" => operation.id,
       "outcome" => "permanent_failure",
       "reason" => reason_code(reason)
     }}
  end

  defp reason_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_code({kind, reason}) when is_atom(kind) and is_atom(reason), do: "#{kind}:#{reason}"
  defp reason_code(_reason), do: "delivery_failed"
end
