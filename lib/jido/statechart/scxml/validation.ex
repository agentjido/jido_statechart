defmodule Jido.Statechart.SCXML.Validation do
  @moduledoc false
  alias Jido.Statechart.Error

  def ensure!(true, _, _), do: :ok

  def ensure!(false, code, message),
    do: throw({:statechart_error, %Error{code: code, message: message}})
end
