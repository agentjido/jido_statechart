defmodule Jido.Statechart.Examples.ParallelApprovalChart do
  @source_path Path.expand("parallel_approval.scxml", __DIR__)
  @external_resource @source_path
  @chart @source_path
         |> File.read!()
         |> Jido.Statechart.SCXML.compile!(
           id: "parallel-approval",
           source_uri: @source_path
         )
  @registry Jido.Statechart.Registry.new!(%{
              version: "parallel-approval-registry-1",
              entries: []
            })

  use Jido.Statechart.Chart, chart: @chart, registry: @registry
end

defmodule Jido.Statechart.Examples.ParallelApprovalAgent do
  use Jido.Agent,
    name: "parallel_approval_example",
    extensions: [Jido.Statechart.Agent.Extension]

  agent do
    schema(Zoi.object(%{label: Zoi.string() |> Zoi.default("approval")}))
  end

  routes do
    route("approval.legal", statechart: Jido.Statechart.Examples.ParallelApprovalChart)
  end
end

alias Jido.Statechart.Examples.{ParallelApprovalAgent, ParallelApprovalChart}
alias Jido.Statechart.{Agent, Limits, Profile, Session}

chart = ParallelApprovalChart.chart()
registry = ParallelApprovalChart.registry()
limits = Limits.default()

session =
  Session.new!(%{
    id: "parallel-approval-direct",
    incarnation: "parallel-approval-direct-1",
    chart_fingerprint: chart.fingerprint,
    profile_version: Profile.version(),
    registry_version: registry.version,
    registry_digest: registry.digest,
    limits_digest: Limits.digest(limits),
    invocation_remaining_descendants: limits.total_descendants
  })

{:ok, direct} = ParallelApprovalChart.initialize(session)
true = direct.session.configuration == ["legal_pending", "finance_pending"]

{:ok, direct} = ParallelApprovalChart.run(direct.session, %{name: "approval.legal"})
true = direct.session.configuration == ["legal_done", "finance_pending"]

{:ok, direct} = ParallelApprovalChart.run(direct.session, %{name: "approval.finance"})
true = direct.session.configuration == []
true = direct.session.status == :completed

runtime_name = :jido_statechart_parallel_approval_example
{:ok, runtime} = Jido.start_link(name: runtime_name, namespace: "examples/parallel-approval")
{:ok, server} = Jido.start_agent(runtime_name, ParallelApprovalAgent, id: "parallel-live")
{:ok, live} = Agent.initialize(server)
true = live.state.statechart.session.configuration == ["legal_pending", "finance_pending"]

legal =
  Jido.Signal.new!("approval.legal", %{},
    id: "parallel-live-legal",
    source: "/example"
  )

{:ok, live} = Jido.AgentServer.call(server, legal)
true = live.state.statechart.session.configuration == ["legal_done", "finance_pending"]

finance =
  Jido.Signal.new!("approval.finance", %{},
    id: "parallel-live-finance",
    source: "/example"
  )

{:ok, live} = Jido.AgentServer.call(server, finance)
true = live.state.statechart.session.configuration == direct.session.configuration
true = live.state.statechart.session.status == :completed

Supervisor.stop(runtime)
IO.puts("parallel approval: direct and live sessions completed in approved")
