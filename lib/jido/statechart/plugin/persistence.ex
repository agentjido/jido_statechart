defmodule Jido.Statechart.Plugin.Persistence do
  @moduledoc false

  alias Jido.Persistence.Plugin.Context
  alias Jido.Statechart.{Limits, Plugin, Registry, Session}

  @checkpoint_version 4
  @version_three 3
  @version_two 2
  @version_one 1
  @fields [
    "checkpoint_version",
    "runtime_protocol_version",
    "profile_version",
    "data_model_version",
    "registry_manifest",
    "limits_version",
    "limits",
    "chart_fingerprint",
    "duplicate_window",
    "session",
    "recent_signal_ids"
  ]
  @version_two_fields @fields -- ["duplicate_window"]

  @doc false
  def checkpoint_version, do: @checkpoint_version

  @doc false
  def dump(value, %Context{direction: :dump}, opts) do
    with :ok <- Plugin.validate_state(value, []),
         {:ok, config} <- contract(opts),
         :ok <- validate_live_contract(value, config) do
      {:ok, encode(value, config)}
    end
  end

  def dump(_value, _context, _opts), do: {:error, :invalid_statechart_persistence_context}

  @doc false
  def load(value, %Context{direction: :load}, opts) do
    with {:ok, config} <- contract(opts),
         {:ok, stored} <- migrate(value, opts),
         :ok <- exact_fields(stored),
         :ok <- validate_stored_contract(stored, config),
         {:ok, session} <- load_session(stored["session"]),
         state = Plugin.state(session, stored["recent_signal_ids"]),
         :ok <- Plugin.validate_state(state, []),
         :ok <- validate_live_contract(state, config) do
      {:ok, state}
    end
  end

  def load(_value, _context, _opts), do: {:error, :invalid_statechart_persistence_context}

  @doc false
  def migrate(%{"checkpoint_version" => @checkpoint_version} = value, _opts), do: {:ok, value}

  def migrate(%{"checkpoint_version" => @version_three} = value, _opts) do
    with true <- Map.keys(value) |> Enum.sort() == Enum.sort(@fields),
         {:ok, session} <- migrate_session(value["session"]) do
      {:ok,
       value
       |> Map.put("checkpoint_version", @checkpoint_version)
       |> Map.put(
         "runtime_protocol_version",
         Session.contract_versions().runtime_protocol_version
       )
       |> Map.put("session", session)}
    else
      _other -> {:error, :invalid_statechart_v3_checkpoint}
    end
  end

  def migrate(%{"checkpoint_version" => @version_two} = value, opts) do
    with {:ok, config} <- contract(opts),
         true <- Map.keys(value) |> Enum.sort() == Enum.sort(@version_two_fields),
         {:ok, session} <- migrate_session(value["session"]) do
      {:ok,
       value
       |> Map.put("checkpoint_version", @checkpoint_version)
       |> Map.put(
         "runtime_protocol_version",
         Session.contract_versions().runtime_protocol_version
       )
       |> Map.put("duplicate_window", config.duplicate_window)
       |> Map.put("session", session)}
    else
      _other -> {:error, :invalid_statechart_v2_checkpoint}
    end
  end

  def migrate(%{"checkpoint_version" => @version_one} = value, opts) do
    with {:ok, config} <- contract(opts),
         true <- Map.keys(value) |> Enum.sort() == ["checkpoint_version", "session", "signal_ids"],
         ids when is_list(ids) <- value["signal_ids"],
         {:ok, session} <- migrate_session(value["session"]) do
      state = %{
        session: session,
        recent_signal_ids: ids
      }

      {:ok,
       config
       |> contract_envelope()
       |> Map.merge(%{
         "checkpoint_version" => @checkpoint_version,
         "session" => state.session,
         "recent_signal_ids" => state.recent_signal_ids
       })}
    else
      _other -> {:error, :invalid_statechart_v1_checkpoint}
    end
  end

  def migrate(%{"checkpoint_version" => version}, _opts),
    do: {:error, {:unsupported_checkpoint_version, version}}

  def migrate(_value, _opts), do: {:error, :invalid_statechart_checkpoint}

  defp encode(state, config) do
    config
    |> contract_envelope()
    |> Map.merge(%{
      "checkpoint_version" => @checkpoint_version,
      "session" => if(state.session, do: Session.dump(state.session), else: nil),
      "recent_signal_ids" => state.recent_signal_ids
    })
  end

  defp contract_envelope(config) do
    versions = Session.contract_versions()

    %{
      "runtime_protocol_version" => versions.runtime_protocol_version,
      "profile_version" => versions.profile_version,
      "data_model_version" => versions.data_model_version,
      "registry_manifest" => Registry.manifest(config.registry),
      "limits_version" => versions.limits_version,
      "limits" => Limits.dump(config.limits),
      "chart_fingerprint" => config.chart.fingerprint,
      "duplicate_window" => config.duplicate_window
    }
  end

  defp exact_fields(value) when is_map(value) do
    if Map.keys(value) |> Enum.sort() == Enum.sort(@fields),
      do: :ok,
      else: {:error, :invalid_statechart_checkpoint_fields}
  end

  defp exact_fields(_value), do: {:error, :invalid_statechart_checkpoint}

  defp validate_stored_contract(stored, config) do
    expected = contract_envelope(config)

    case Enum.find(Map.keys(expected), &(Map.get(stored, &1) != Map.fetch!(expected, &1))) do
      nil -> :ok
      field -> {:error, {:statechart_checkpoint_contract_mismatch, field}}
    end
  end

  defp validate_live_contract(%{recent_signal_ids: ids}, config)
       when length(ids) > config.duplicate_window,
       do: {:error, :statechart_duplicate_window_exceeded}

  defp validate_live_contract(%{session: nil}, _config), do: :ok

  defp validate_live_contract(%{session: %Session{} = session}, config) do
    with true <- session.chart_fingerprint == config.chart.fingerprint,
         :ok <- Session.validate_contract(session, config.registry, config.limits),
         :ok <- Session.validate_limits(session, config.limits) do
      :ok
    else
      false -> {:error, :statechart_chart_fingerprint_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp validate_live_contract(_state, _config), do: {:error, :invalid_statechart_session}

  defp load_session(nil), do: {:ok, nil}
  defp load_session(value), do: Session.load(value)

  defp migrate_session(nil), do: {:ok, nil}

  defp migrate_session(session) when is_map(session) do
    versions = Session.contract_versions()

    with true <- Map.get(session, "schema_version") == 1,
         true <- Map.get(session, "runtime_protocol_version") == 1,
         operations when is_map(operations) <- Map.get(session, "operations"),
         tombstones when is_map(tombstones) <- Map.get(session, "operation_tombstones"),
         {:ok, high_water} <- legacy_high_water(operations, tombstones) do
      {:ok,
       session
       |> Map.put("schema_version", versions.schema_version)
       |> Map.put("runtime_protocol_version", versions.runtime_protocol_version)
       |> Map.put("operation_high_water", high_water)
       |> Map.put("received_operation_ids", [])}
    else
      _other -> {:error, :unsupported_statechart_session_migration}
    end
  end

  defp migrate_session(_session), do: {:error, :unsupported_statechart_session_migration}

  defp legacy_high_water(operations, tombstones) do
    (Map.values(operations) ++ Map.values(tombstones))
    |> Enum.reduce_while({:ok, %{}}, fn record, {:ok, acc} ->
      key = Map.get(record, "key")
      generation = Map.get(record, "generation")

      cond do
        is_nil(key) ->
          {:cont, {:ok, acc}}

        is_binary(key) and key != "" and is_integer(generation) and generation >= 0 ->
          {:cont, {:ok, Map.update(acc, key, generation, &max(&1, generation))}}

        true ->
          {:halt, {:error, :unsupported_statechart_session_migration}}
      end
    end)
  end

  defp contract(opts) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: do_contract(opts),
      else: {:error, :invalid_statechart_plugin_options}
  end

  defp contract(_opts), do: {:error, :invalid_statechart_plugin_options}

  defp do_contract(opts) do
    chart_module = Keyword.get(opts, :chart)
    supplied_limits = Keyword.get(opts, :limits, Limits.default())
    duplicate_window = Keyword.get(opts, :duplicate_window, 1_024)

    with true <- chart_module?(chart_module),
         true <- is_integer(duplicate_window) and duplicate_window in 1..100_000,
         {:ok, limits} <- limits(supplied_limits) do
      {:ok,
       %{
         chart: chart_module.chart(),
         registry: chart_module.registry(),
         limits: limits,
         duplicate_window: duplicate_window
       }}
    else
      _other -> {:error, :invalid_statechart_plugin_options}
    end
  end

  defp limits(%Limits{} = limits), do: Limits.new(Map.from_struct(limits))
  defp limits(value), do: Limits.new(value)

  defp chart_module?(module) when is_atom(module) and not is_nil(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :chart, 0) and
      function_exported?(module, :registry, 0)
  end

  defp chart_module?(_module), do: false
end
