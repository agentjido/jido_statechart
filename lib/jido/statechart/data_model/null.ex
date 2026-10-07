defmodule Jido.Statechart.DataModel.Null do
  @moduledoc "The SCXML null data model with only the In(state_id) predicate."

  @behaviour Jido.Statechart.DataModel

  alias Jido.Statechart.{DataModel, Diagnostic}

  @in_pattern ~r/^\s*In\(\s*(['"])([A-Za-z_][A-Za-z0-9_.-]*)\1\s*\)\s*$/u

  @impl true
  def capabilities do
    %{
      assignment: false,
      content: true,
      data: false,
      iteration: false,
      predicate: ["In"]
    }
  end

  @impl true
  def initialize(declarations, _environment, options) do
    with {:ok, _limits} <- DataModel.limits(options) do
      if declarations == %{} do
        {:ok, %{}}
      else
        {:error,
         Diagnostic.new(:null_data_forbidden, "The null data model cannot store application data",
           path: [:data]
         )}
      end
    end
  end

  @impl true
  def condition(expression, environment, options) do
    with {:ok, _limits} <- DataModel.limits(options) do
      if is_binary(expression) and String.valid?(expression) do
        case Regex.run(@in_pattern, expression, capture: :all_but_first) do
          [_quote, state_id] -> {:ok, state_id in Map.get(environment, :active_state_ids, [])}
          _other -> invalid_expression()
        end
      else
        invalid_expression()
      end
    end
  end

  @impl true
  def value(_expression, _environment, options) do
    with {:ok, _limits} <- DataModel.limits(options) do
      {:error,
       Diagnostic.new(
         :null_expression_forbidden,
         "The null data model cannot evaluate value expressions",
         path: [:expression]
       )}
    end
  end

  @impl true
  def assign(_location, _value, _data, options) do
    with {:ok, _limits} <- DataModel.limits(options) do
      {:error,
       Diagnostic.new(:null_assignment_forbidden, "The null data model cannot assign data",
         path: [:location]
       )}
    end
  end

  @impl true
  def iterate(_expression, _environment, options) do
    with {:ok, _limits} <- DataModel.limits(options) do
      {:error,
       Diagnostic.new(:null_iteration_forbidden, "The null data model cannot iterate data",
         path: [:foreach]
       )}
    end
  end

  @impl true
  def protected?(location), do: DataModel.protected_location?(location)

  @impl true
  def content(spec, _environment, options) when is_map(spec) do
    with {:ok, _limits} <- DataModel.limits(options) do
      if present?(spec, "expression") do
        value(Map.get(spec, "expression"), %{}, options)
      else
        DataModel.literal_content(spec, options)
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
      cond do
        Map.get(spec, "params", []) != [] ->
          {:error,
           Diagnostic.new(
             :null_expression_forbidden,
             "The null data model cannot build parameters",
             path: [:params]
           )}

        is_map(Map.get(spec, "content")) ->
          content(Map.fetch!(spec, "content"), environment, options)

        true ->
          {:ok, nil}
      end
    end
  end

  def construct(_spec, _environment, options) do
    with {:ok, _limits} <- DataModel.limits(options) do
      {:error, Diagnostic.new(:invalid_content, "Content container must be a map")}
    end
  end

  defp invalid_expression do
    {:error,
     Diagnostic.new(:invalid_null_expression, "The null data model supports only In(state_id)",
       path: [:expression]
     )}
  end

  defp present?(map, key), do: Map.has_key?(map, key) and not is_nil(Map.get(map, key))
end
