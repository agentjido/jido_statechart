defmodule Jido.Statechart.ActionRunner do
  @moduledoc "Runs one trusted Statechart Action through the Jido.Exec boundary."

  alias Jido.Action.Output
  alias Jido.Statechart.{DataModel, Diagnostic, Registry}
  alias Jido.Statechart.Registry.Entry

  @context_fields [:session_id, :event, :configuration, :turn_id]

  @doc "Runs a registered Action with bounded input, output, context, and deadline."
  @spec run(String.t(), map(), map(), keyword()) ::
          {:ok, term()} | {:error, Diagnostic.t()}
  def run(identifier, params, environment, options)
      when is_binary(identifier) and is_map(params) and is_map(environment) and is_list(options) do
    if Keyword.keyword?(options) do
      with {:ok, registry} <- registry(options),
           {:ok, limits} <- limits(options),
           {:ok, entry} <- registered(registry, identifier),
           :ok <- permission(entry),
           :ok <- DataModel.validate_value(params, [limits: limits], [:action, :params]),
           {:ok, context} <- context(environment, limits),
           {:ok, timeout} <- remaining_timeout(Keyword.get(options, :deadline, :infinity)),
           result <- execute(entry.handler, params, context, timeout, options),
           {:ok, output} <- normalize_result(result),
           :ok <- validate_output(output, limits) do
        {:ok, unwrap(output)}
      end
    else
      {:error, Diagnostic.new(:invalid_action_call, "Action options are invalid")}
    end
  end

  def run(_identifier, _params, _environment, _options) do
    {:error, Diagnostic.new(:invalid_action_call, "Action call is invalid", path: [:action])}
  end

  defp registry(options) do
    case Keyword.get(options, :registry) do
      %Registry{} = registry -> {:ok, registry}
      _other -> {:error, Diagnostic.new(:invalid_registry, "A trusted Registry is required")}
    end
  end

  defp limits(options) do
    DataModel.limits(options)
  end

  defp registered(registry, identifier) do
    case Registry.fetch(registry, :action, identifier) do
      {:ok, entry} ->
        {:ok, entry}

      :error ->
        {:error,
         Diagnostic.new(:action_not_registered, "Action identifier is not registered",
           path: [:action, identifier]
         )}
    end
  end

  defp permission(%Entry{permissions: permissions}) do
    if "execute" in permissions do
      :ok
    else
      {:error,
       Diagnostic.new(:action_permission_denied, "Action execute permission is not declared",
         path: [:action],
         correction: %{"required_permission" => "execute"}
       )}
    end
  end

  defp context(environment, limits) do
    statechart =
      Map.new(@context_fields, fn field ->
        {Atom.to_string(field), Map.get(environment, field)}
      end)

    with :ok <- DataModel.validate_value(statechart, [limits: limits], [:action, :context]) do
      {:ok, %{statechart: statechart}}
    end
  end

  defp remaining_timeout(:infinity), do: {:ok, :infinity}

  defp remaining_timeout(deadline) when is_integer(deadline) do
    {:ok, max(deadline - System.monotonic_time(:millisecond), 0)}
  end

  defp remaining_timeout(_deadline) do
    {:error, Diagnostic.new(:invalid_deadline, "Action deadline is invalid", path: [:deadline])}
  end

  defp execute(target, params, context, timeout, options) do
    exec_options = [timeout: timeout, max_concurrency: 1, max_continuations: 0]

    exec_options =
      case Keyword.fetch(options, :task_supervisor) do
        {:ok, supervisor} -> Keyword.put(exec_options, :task_supervisor, supervisor)
        :error -> exec_options
      end

    Jido.Exec.run(target, params, context, exec_options)
  end

  defp normalize_result({:ok, _output, effects}) when effects != [] do
    {:error,
     Diagnostic.new(:action_effects_forbidden, "Statechart Actions cannot return effects",
       path: [:action, :effects]
     )}
  end

  defp normalize_result({:ok, output, []}), do: {:ok, output}
  defp normalize_result({:ok, output}), do: {:ok, output}

  defp normalize_result({:error, %Jido.Exec.Error.CancelledError{}}) do
    {:error,
     Diagnostic.new(:action_cancelled, "Statechart Action execution was cancelled",
       path: [:action]
     )}
  end

  defp normalize_result({:error, error}) do
    cond do
      timeout_error?(error) ->
        {:error,
         Diagnostic.new(:action_timeout, "Statechart Action exceeded its remaining deadline",
           path: [:action]
         )}

      continuation_error?(error) ->
        {:error,
         Diagnostic.new(
           :action_continuation_forbidden,
           "Statechart Actions cannot return continuations",
           path: [:action]
         )}

      true ->
        {:error,
         Diagnostic.new(:action_failed, "Registered Statechart Action failed", path: [:action])}
    end
  end

  defp normalize_result(_result) do
    {:error,
     Diagnostic.new(:action_failed, "Registered Statechart Action returned an invalid result",
       path: [:action]
     )}
  end

  defp validate_output(%Output{kind: :stream}, _limits) do
    {:error,
     Diagnostic.new(:action_stream_forbidden, "Statechart Actions cannot return streams",
       path: [:action, :output]
     )}
  end

  defp validate_output(%Output{kind: :opaque}, _limits) do
    {:error,
     Diagnostic.new(:action_opaque_forbidden, "Statechart Actions cannot return opaque output",
       path: [:action, :output]
     )}
  end

  defp validate_output(%Output{value: value}, limits), do: validate_portable_output(value, limits)
  defp validate_output(output, limits), do: validate_portable_output(output, limits)

  defp validate_portable_output(output, limits) do
    cond do
      directive?(output) ->
        {:error,
         Diagnostic.new(
           :action_directive_forbidden,
           "Statechart Actions cannot return Directives",
           path: [:action, :output]
         )}

      true ->
        case DataModel.validate_value(output, [limits: limits], [:action, :output]) do
          :ok ->
            :ok

          {:error, %Diagnostic{code: :data_limit_exceeded}} ->
            {:error,
             Diagnostic.new(:action_output_too_large, "Statechart Action output is too large",
               path: [:action, :output],
               correction: %{"maximum_bytes" => limits.data_bytes}
             )}

          {:error, %Diagnostic{} = diagnostic} ->
            {:error, diagnostic}
        end
    end
  end

  defp unwrap(%Output{value: value}), do: value
  defp unwrap(output), do: output

  defp timeout_error?(%Jido.Exec.Error.TimeoutError{}), do: true
  defp timeout_error?(%Jido.Action.Error.TimeoutError{}), do: true
  defp timeout_error?(%Jido.Flow.Error.TimeoutError{}), do: true
  defp timeout_error?(_error), do: false

  defp continuation_error?(%Jido.Action.Error.ExecutionFailureError{
         details: %{max_continuations: 0}
       }),
       do: true

  defp continuation_error?(%Jido.Action.Error.ExecutionFailureError{message: message})
       when message in [
              "continuation limit exceeded",
              "action returned an invalid continuation",
              "action returned an invalid continuation target"
            ],
       do: true

  defp continuation_error?(_error), do: false

  defp directive?(%{__struct__: module} = value) when is_atom(module) do
    Jido.Agent.Directive.built_in?(value) or directive_module?(module)
  end

  defp directive?(value) when is_map(value),
    do: Enum.any?(value, fn {key, item} -> directive?(key) or directive?(item) end)

  defp directive?(value) when is_list(value), do: Enum.any?(value, &directive?/1)

  defp directive?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.any?(&directive?/1)

  defp directive?(_value), do: false

  defp directive_module?(module) do
    function_exported?(module, :validate, 1) and
      Jido.Agent.Directive in List.wrap(module.module_info(:attributes)[:behaviour])
  rescue
    _exception -> false
  end
end
