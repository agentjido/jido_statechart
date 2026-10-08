defmodule Jido.Statechart.Plugin.OwnedChildControl do
  @moduledoc false
  use Jido.Agent.Directive

  @enforce_keys [
    :action,
    :tag,
    :invoke_operation_id,
    :invoke_generation,
    :invoke_id,
    :session_incarnation,
    :control_operation_id
  ]
  defstruct @enforce_keys ++ [signal: nil]

  @impl Jido.Agent.Directive
  def validate(%__MODULE__{} = value)
      when value.action in [:emit, :stop] and is_binary(value.tag) and value.tag != "" and
             is_binary(value.invoke_operation_id) and value.invoke_operation_id != "" and
             is_integer(value.invoke_generation) and value.invoke_generation >= 0 and
             is_binary(value.invoke_id) and value.invoke_id != "" and
             is_binary(value.session_incarnation) and value.session_incarnation != "" and
             is_binary(value.control_operation_id) and value.control_operation_id != "" do
    if value.action == :stop or match?(%Jido.Signal{}, value.signal),
      do: {:ok, value},
      else: {:error, :invalid_statechart_owned_child_control}
  end

  def validate(_value), do: {:error, :invalid_statechart_owned_child_control}
end
