defmodule Jido.Statechart.ExamplesTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  @examples Path.expand("../../examples", __DIR__)

  test "door direct example is executable" do
    output = capture_io(fn -> Code.eval_file(Path.join(@examples, "door.exs")) end)
    assert output =~ "direct door: closed -> opened -> closed"
  end

  test "parallel approval direct and live example is executable" do
    output = capture_io(fn -> Code.eval_file(Path.join(@examples, "parallel_approval.exs")) end)
    assert output =~ "parallel approval: direct and live sessions completed in approved"
  end
end
