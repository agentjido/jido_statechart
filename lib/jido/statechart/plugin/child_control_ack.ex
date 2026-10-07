defmodule Jido.Statechart.Plugin.ChildControlAck do
  @moduledoc false
  use Jido.Agent.Directive

  @enforce_keys [:session_incarnation, :operation_id, :generation]
  defstruct @enforce_keys

  @impl Jido.Agent.Directive
  def validate(%__MODULE__{} = value)
      when is_binary(value.session_incarnation) and value.session_incarnation != "" and
             is_binary(value.operation_id) and value.operation_id != "" and
             is_integer(value.generation) and value.generation >= 0,
      do: {:ok, value}

  def validate(_value), do: {:error, :invalid_statechart_child_control_ack}
end
