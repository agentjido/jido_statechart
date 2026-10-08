defmodule Jido.Statechart.DataModel.Jido do
  @moduledoc "The restricted Jido data model for portable, registered expressions."

  @behaviour Jido.Statechart.DataModel

  alias Jido.Statechart.{DataModel, Diagnostic, Expression, Location}

  @impl true
  def capabilities do
    %{
      assignment: true,
      content: true,
      data: true,
      iteration: true,
      predicate: ["In", "registered_expression"]
    }
  end

  @impl true
  def initialize(declarations, environment, options)
      when is_map(declarations) and is_map(environment) do
    with {:ok, _limits} <- DataModel.limits(options),
         :ok <- declaration_keys(declarations),
         {:ok, ordered} <- ordered_declarations(declarations) do
      ordered
      |> Enum.reduce_while({:ok, %{}}, fn {identifier, declaration}, {:ok, data} ->
        current_environment =
          Map.put(environment, :data, Map.merge(environment[:data] || %{}, data))

        case declaration_value(declaration, current_environment, options) do
          {:ok, value} ->
            next = Map.put(data, identifier, value)

            case DataModel.validate_value(next, options, [:data]) do
              :ok -> {:cont, {:ok, next}}
              {:error, _} = error -> {:halt, error}
            end

          {:error, _} = error ->
            {:halt, error}
        end
      end)
    end
  end

  def initialize(_declarations, _environment, options) do
    with {:ok, _limits} <- DataModel.limits(options) do
      {:error, Diagnostic.new(:invalid_data, "Data declarations must be a map", path: [:data])}
    end
  end

  @impl true
  def condition(expression, environment, options) do
    case value(expression, environment, options) do
      {:ok, boolean} when is_boolean(boolean) ->
        {:ok, boolean}

      {:ok, _other} ->
        {:error,
         Diagnostic.new(:condition_not_boolean, "Condition expression must return a Boolean",
           path: [:condition]
         )}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def value(expression, environment, options),
    do: Expression.evaluate(expression, normalize_environment(environment), options)

  @impl true
  def assign(location, value, data, options) when is_map(data) do
    with {:ok, _limits} <- DataModel.limits(options),
         {:ok, _segments} <- Location.parse(location),
         :ok <- writable(location),
         :ok <- DataModel.validate_value(value, options, [:assignment]),
         {:ok, updated} <- Location.put(data, location, value),
         :ok <- DataModel.validate_value(updated, options, [:data]) do
      {:ok, updated}
    end
  end

  def assign(_location, _value, _data, options) do
    with {:ok, _limits} <- DataModel.limits(options) do
      {:error, Diagnostic.new(:invalid_data, "Assigned data must be a map", path: [:data])}
    end
  end

  @impl true
  def iterate(expression, environment, options) do
    with {:ok, _limits} <- DataModel.limits(options),
         {:ok, value} <- value(expression, environment, options),
         {:ok, snapshot} <- snapshot(value),
         :ok <- iteration_limit(snapshot, options) do
      {:ok, snapshot}
    end
  end

  @impl true
  def protected?(location), do: DataModel.protected_location?(location)

  @impl true
  def content(spec, environment, options) when is_map(spec) do
    with {:ok, _limits} <- DataModel.limits(options) do
      case Map.get(spec, "expression") do
        expression when is_binary(expression) and expression != "" ->
          value(expression, environment, options)

        nil ->
          DataModel.literal_content(spec, options)

        _other ->
          {:error,
           Diagnostic.new(:invalid_content, "Content expression must be a registered identifier",
             path: [:content, :expression]
           )}
      end
    end
  end

  def content(_spec, _environment, options) do
    with {:ok, _limits} <- DataModel.limits(options) do
      {:error, Diagnostic.new(:invalid_content, "Content must be a map", path: [:content])}
    end
  end

  @impl true
  def construct(spec, environment, options) when is_map(spec) do
    with {:ok, _limits} <- DataModel.limits(options) do
      params = Map.get(spec, "params", [])
      content_spec = Map.get(spec, "content")

      cond do
        params != [] and not is_nil(content_spec) ->
          {:error,
           Diagnostic.new(:invalid_content, "Parameters and content are mutually exclusive",
             path: [:content]
           )}

        params != [] ->
          construct_params(params, environment, options)

        is_map(content_spec) ->
          content(content_spec, environment, options)

        is_nil(content_spec) ->
          {:ok, nil}

        true ->
          {:error, Diagnostic.new(:invalid_content, "Content container is invalid")}
      end
    end
  end

  def construct(_spec, _environment, options) do
    with {:ok, _limits} <- DataModel.limits(options) do
      {:error, Diagnostic.new(:invalid_content, "Content container must be a map")}
    end
  end

  defp declaration_keys(declarations) do
    declarations
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn key, :ok ->
      cond do
        is_binary(key) and protected?(key) ->
          {:halt,
           {:error,
            Diagnostic.new(:protected_location, "SCXML system variables cannot be declared",
              path: [:data, key]
            )}}

        match?({:ok, [_segment]}, Location.parse(key)) ->
          {:cont, :ok}

        true ->
          {:halt,
           {:error,
            Diagnostic.new(
              :invalid_data_key,
              "Data declaration keys must be one legal location segment",
              path: [:data, key]
            )}}
      end
    end)
  end

  defp ordered_declarations(declarations) do
    entries = Map.to_list(declarations)

    ordinal_states =
      Enum.map(entries, fn
        {_identifier, declaration} when is_map(declaration) ->
          case Map.fetch(declaration, "ordinal") do
            {:ok, ordinal} when is_integer(ordinal) and ordinal >= 0 -> {:ordinal, ordinal}
            {:ok, _ordinal} -> :invalid
            :error -> :absent
          end

        _entry ->
          :absent
      end)

    cond do
      Enum.all?(ordinal_states, &(&1 == :absent)) ->
        {:ok, Enum.sort_by(entries, &elem(&1, 0))}

      Enum.all?(ordinal_states, &match?({:ordinal, _}, &1)) ->
        ordinals = Enum.map(ordinal_states, fn {:ordinal, ordinal} -> ordinal end)

        if length(Enum.uniq(ordinals)) == length(ordinals) do
          {:ok,
           Enum.sort_by(entries, fn {_identifier, declaration} -> declaration["ordinal"] end)}
        else
          invalid_declaration_order()
        end

      true ->
        invalid_declaration_order()
    end
  end

  defp invalid_declaration_order do
    {:error,
     Diagnostic.new(
       :invalid_data_declaration_order,
       "Data declaration ordinals must be unique nonnegative integers",
       path: [:data]
     )}
  end

  defp declaration_value(declaration, environment, options) when is_map(declaration) do
    cond do
      is_binary(Map.get(declaration, "expr")) ->
        value(Map.fetch!(declaration, "expr"), environment, options)

      is_map(Map.get(declaration, "content")) ->
        content(Map.fetch!(declaration, "content"), environment, options)

      map_size(Map.drop(declaration, ["ordinal"])) == 0 ->
        {:ok, nil}

      true ->
        {:error,
         Diagnostic.new(:invalid_data_declaration, "Data declaration is invalid", path: [:data])}
    end
  end

  defp declaration_value(_declaration, _environment, _options) do
    {:error, Diagnostic.new(:invalid_data_declaration, "Data declaration must be a map")}
  end

  defp writable(location) do
    if protected?(location) do
      {:error,
       Diagnostic.new(:protected_location, "SCXML system variables cannot be assigned",
         path: [:location]
       )}
    else
      :ok
    end
  end

  defp snapshot(value) when is_list(value) do
    {:ok, value |> Enum.with_index() |> Enum.map(fn {item, index} -> {item, index} end)}
  end

  defp snapshot(value) when is_map(value) and not is_struct(value) do
    if Enum.all?(Map.keys(value), &is_binary/1) do
      {:ok,
       value
       |> Enum.sort_by(&elem(&1, 0))
       |> Enum.map(fn {key, item} -> {item, key} end)}
    else
      {:error,
       Diagnostic.new(:invalid_iteration_value, "Iteration map keys must be strings",
         path: [:foreach]
       )}
    end
  end

  defp snapshot(_value) do
    {:error,
     Diagnostic.new(:invalid_iteration_value, "Iteration requires a list or map",
       path: [:foreach]
     )}
  end

  defp iteration_limit(snapshot, options) do
    with {:ok, limits} <- DataModel.limits(options) do
      maximum = limits.microsteps_per_macrostep

      if length(snapshot) <= maximum do
        :ok
      else
        {:error,
         Diagnostic.new(:iteration_limit_exceeded, "Iteration snapshot exceeds its item limit",
           path: [:foreach],
           correction: %{"maximum_items" => maximum}
         )}
      end
    end
  end

  # SCXML 1.0, section 6.2.3, requires every namelist and param occurrence,
  # including duplicates. An ordered entry list keeps that information portable.
  defp construct_params(params, environment, options) when is_list(params) do
    params
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {param, index}, {:ok, acc} ->
      with {:ok, name} <- param_name(param, index),
           {:ok, value} <- param_value(param, environment, options),
           entry = %{"name" => name, "value" => value},
           :ok <- DataModel.validate_value(entry, options, [:params, index]) do
        {:cont, {:ok, [entry | acc]}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} ->
        payload = Enum.reverse(reversed)

        with :ok <- DataModel.validate_value(payload, options, [:params]),
             do: {:ok, payload}

      {:error, _diagnostic} = error ->
        error
    end
  end

  defp construct_params(_params, _environment, _options) do
    {:error, Diagnostic.new(:invalid_param, "Parameters must be a list", path: [:params])}
  end

  defp param_name(%{"name" => name}, _index) when is_binary(name) and name != "", do: {:ok, name}

  defp param_name(_param, index) do
    {:error,
     Diagnostic.new(:invalid_param, "Parameter name must be a string",
       path: [:params, index, :name]
     )}
  end

  defp param_value(%{"expr" => expression}, environment, options)
       when is_binary(expression) and expression != "",
       do: value(expression, environment, options)

  defp param_value(%{"location" => location}, environment, _options)
       when is_binary(location) and location != "" do
    read_location(location, environment)
  end

  defp param_value(_param, _environment, _options) do
    {:error,
     Diagnostic.new(:invalid_param, "Parameter requires one expression or location",
       path: [:params]
     )}
  end

  defp read_location(location, environment) do
    with {:ok, [root | _rest] = path} <- Location.parse(location) do
      if protected?(root) do
        environment |> Map.get(:system, %{}) |> Location.fetch(path)
      else
        environment |> Map.get(:data, %{}) |> Location.fetch(path)
      end
    end
  end

  defp normalize_environment(environment) when is_map(environment) do
    environment
    |> Map.put_new(:data, %{})
    |> Map.put_new(:system, %{})
    |> Map.put_new(:bindings, %{})
    |> Map.put_new(:active_state_ids, [])
  end

  defp normalize_environment(_environment),
    do: %{data: %{}, system: %{}, bindings: %{}, active_state_ids: []}
end
