defmodule Jido.Statechart.Examples.Approval do
  use Jido.Statechart.Agent,
    name: "example_approval",
    data_schema:
      Zoi.object(%{approved: Zoi.boolean() |> Zoi.default(false)})
      |> Zoi.default(%{approved: false})

  statechart id: "approval", version: "1", initial: "review" do
    state "review", initial: "pending" do
      state "pending" do
        transition "approve", target: "accepted", actions: ["approve"]
      end

      state "accepted", type: :final

      transition "done.state.review",
        target: "complete",
        guard: "is_approved",
        actions: [%{effect: "finish"}]
    end

    state "complete", type: :final
  end

  def registry do
    %Jido.Statechart.Registry{
      guards: %{"is_approved" => fn data, _ -> data.approved end},
      reducers: %{"approve" => fn data, _, _ -> {:ok, %{data | approved: true}} end}
    }
  end

  def effects do
    %{"finish" => fn _ -> {:ok, %Jido.Agent.Directive.Stop{reason: :normal}} end}
  end
end

alias Jido.Statechart.Examples.Approval
agent = Approval.new!(id: "approval-1")
signal = Jido.Signal.new!("approve", %{}, source: "/example")
{:ok, complete, [%Jido.Agent.Directive.Stop{}]} = Approval.cmd(agent, signal)
true = complete.state.chart.status == "done"
true = complete.state.data.approved
IO.inspect(complete.state, label: "Approval candidate")
