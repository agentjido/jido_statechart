defmodule Jido.Statechart.SemanticFixture do
  @moduledoc false

  alias Jido.Statechart.{Limits, Profile, Registry, SCXML, Session}

  defmodule TargetAdapter do
    @moduledoc false

    def idempotency, do: :operation_id
    def deliver(_signal, _operation_id, _context), do: :ok
  end

  def chart(body, options \\ []) do
    datamodel = Keyword.get(options, :datamodel, "null")
    binding = Keyword.get(options, :binding, "early")

    SCXML.compile!(
      """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0"
             datamodel="#{datamodel}" binding="#{binding}" initial="root">
        #{body}
      </scxml>
      """,
      id: Keyword.get(options, :id, "semantic-chart")
    )
  end

  def registry(entries \\ []) do
    Registry.new!(%{version: "registry-1", entries: entries})
  end

  def expression(name, value) do
    %{
      kind: :expression,
      alias: name,
      permissions: [
        "evaluate",
        "read:bindings",
        "read:configuration",
        "read:data",
        "read:system"
      ],
      handler: {:expression, value}
    }
  end

  def target(
        name,
        permissions \\ ["delivery:at_least_once", "idempotency:operation_id", "send:event"]
      ) do
    %{
      kind: :target,
      alias: name,
      permissions: permissions,
      handler: TargetAdapter
    }
  end

  def session(chart, options \\ []) do
    registry = Keyword.get(options, :registry, registry())
    limits = Keyword.get(options, :limits, Limits.default())

    Session.new!(%{
      id: Keyword.get(options, :id, "session-1"),
      incarnation: "incarnation-1",
      chart_fingerprint: chart.fingerprint,
      registry_digest: registry.digest,
      limits_digest: Limits.digest(limits),
      registry_version: registry.version,
      profile_version: Profile.version(),
      status: Keyword.get(options, :status, :new),
      configuration: Keyword.get(options, :configuration, []),
      history: Keyword.get(options, :history, %{}),
      data: Keyword.get(options, :data, %{}),
      internal_queue: Keyword.get(options, :internal_queue, []),
      trace: Keyword.get(options, :trace, [])
    })
  end

  def options(options \\ []) do
    [
      registry: Keyword.get(options, :registry, registry()),
      limits: Keyword.get(options, :limits, Limits.default())
    ]
  end
end
