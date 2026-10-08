defmodule Jido.Statechart.ActionRunnerTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Output
  alias Jido.Statechart.{ActionRunner, Diagnostic, Limits, Registry}

  defmodule ContextAction do
    use Jido.Action, name: "statechart_context"

    @impl true
    def run(_params, context) do
      statechart = context.statechart

      {:ok,
       %{
         "session_id" => statechart["session_id"],
         "event_name" => get_in(statechart, ["event", "name"]),
         "configuration" => statechart["configuration"],
         "has_agent" => Map.has_key?(context, :agent),
         "has_signal" => Map.has_key?(context, :signal),
         "has_exec_budget" => Jido.Exec.remaining_time(context) != nil
       }}
    end
  end

  defmodule EffectAction do
    use Jido.Action, name: "statechart_effect"

    @impl true
    def run(_params, _context), do: {:ok, %{"ok" => true}, [{__MODULE__, :effect, []}]}
  end

  defmodule StreamAction do
    use Jido.Action, name: "statechart_stream"

    @impl true
    def run(_params, _context), do: {:ok, Output.stream(Stream.map([1], & &1))}
  end

  defmodule OpaqueAction do
    use Jido.Action, name: "statechart_opaque"

    @impl true
    def run(_params, _context), do: {:ok, Output.opaque(make_ref())}
  end

  defmodule DirectiveAction do
    use Jido.Action, name: "statechart_directive"

    @impl true
    def run(_params, _context), do: {:ok, Output.raw(%Jido.Agent.Directive.Stop{})}
  end

  defmodule LargeAction do
    use Jido.Action, name: "statechart_large"

    @impl true
    def run(_params, _context), do: {:ok, %{"value" => String.duplicate("x", 1_000)}}
  end

  defmodule RawAction do
    use Jido.Action, name: "statechart_raw"

    @impl true
    def run(_params, _context), do: {:ok, Output.raw("ok")}
  end

  defmodule BatchAction do
    use Jido.Action, name: "statechart_batch"

    @impl true
    def run(_params, _context), do: {:ok, Output.batch([%{"id" => 1}])}
  end

  defmodule AtomKeyAction do
    use Jido.Action, name: "statechart_atom_key"

    @impl true
    def run(_params, _context), do: {:ok, %{unsafe: true}}
  end

  defmodule FailureAction do
    use Jido.Action, name: "statechart_failure"

    @impl true
    def run(_params, _context), do: {:error, :failed}
  end

  defmodule CancelledAction do
    use Jido.Action, name: "statechart_cancelled"

    @impl true
    def run(_params, _context), do: {:error, Jido.Exec.Error.cancelled_error()}
  end

  defmodule ContinuationAction do
    use Jido.Action, name: "statechart_continuation"

    @impl true
    def run(params, _context), do: {:continue, params, ContextAction}
  end

  defmodule InvalidContinuationInputAction do
    use Jido.Action, name: "statechart_invalid_continuation_input"

    @impl true
    def run(_params, _context), do: {:continue, "invalid", ContextAction}
  end

  defmodule InvalidContinuationTargetAction do
    use Jido.Action, name: "statechart_invalid_continuation_target"

    @impl true
    def run(params, _context), do: {:continue, params, :not_an_executable}
  end

  defmodule FlowTarget do
    def __jido_executable__, do: Jido.Executable.flow(__MODULE__)
  end

  defmodule SlowDescriptorAction do
    @behaviour Jido.Action
    @behaviour Jido.Executable

    @impl Jido.Executable
    def __jido_executable__ do
      Process.sleep(300)
      Jido.Executable.action(__MODULE__)
    end

    @impl Jido.Executable
    def validate_params(params), do: {:ok, params}

    @impl Jido.Executable
    def validate_output(output), do: {:ok, output}

    @impl Jido.Action
    def run(_params, _context), do: {:ok, %{}}
  end

  defmodule NeverAction do
    use Jido.Action, name: "statechart_never"

    @impl true
    def run(_params, _context), do: receive(do: (:never -> {:ok, %{}}))
  end

  test "runs a registered Action with a minimal context and remaining deadline" do
    registry = registry("run", ContextAction)
    deadline = System.monotonic_time(:millisecond) + 5_000

    environment = %{
      session_id: "session-1",
      event: %{"name" => "work", "data" => %{"id" => 1}},
      configuration: ["ready"],
      agent: %{secret: true},
      signal: %{secret: true}
    }

    assert {:ok, output} =
             ActionRunner.run("run", %{}, environment,
               registry: registry,
               limits: Limits.default(),
               deadline: deadline
             )

    assert output == %{
             "session_id" => "session-1",
             "event_name" => "work",
             "configuration" => ["ready"],
             "has_agent" => false,
             "has_signal" => false,
             "has_exec_budget" => true
           }
  end

  test "rejects unregistered and unauthorized Actions" do
    empty = Registry.new!(%{version: "registry-1", entries: []})

    assert {:error, %Diagnostic{code: :action_not_registered}} =
             ActionRunner.run("missing", %{}, %{},
               registry: empty,
               limits: Limits.default()
             )

    denied = registry("run", ContextAction, [])

    assert {:error, %Diagnostic{code: :action_permission_denied}} =
             ActionRunner.run("run", %{}, %{}, registry: denied, limits: Limits.default())
  end

  test "rejects effects, Directives, streams, opaque output, and oversized output" do
    cases = [
      {EffectAction, :action_effects_forbidden},
      {DirectiveAction, :action_directive_forbidden},
      {StreamAction, :action_stream_forbidden},
      {OpaqueAction, :action_opaque_forbidden}
    ]

    for {action, code} <- cases do
      assert {:error, %Diagnostic{code: ^code}} =
               ActionRunner.run("run", %{}, %{},
                 registry: registry("run", action),
                 limits: Limits.default()
               )
    end

    limits = Limits.new!(%{data_bytes: 100})

    assert {:error, %Diagnostic{code: :action_output_too_large}} =
             ActionRunner.run("run", %{}, %{},
               registry: registry("run", LargeAction),
               limits: limits
             )
  end

  test "rejects timeout and continuation" do
    assert {:error, %Diagnostic{code: :action_timeout}} =
             ActionRunner.run("run", %{}, %{},
               registry: registry("run", NeverAction),
               limits: Limits.default(),
               deadline: System.monotonic_time(:millisecond)
             )

    assert {:error, %Diagnostic{code: :action_continuation_forbidden}} =
             ActionRunner.run("run", %{}, %{},
               registry: registry("run", ContinuationAction),
               limits: Limits.default()
             )

    assert {:error, %Diagnostic{code: :action_cancelled}} =
             ActionRunner.run("run", %{}, %{},
               registry: registry("run", CancelledAction),
               limits: Limits.default()
             )

    for action <- [InvalidContinuationInputAction, InvalidContinuationTargetAction] do
      assert {:error, %Diagnostic{code: :action_continuation_forbidden}} =
               ActionRunner.run("run", %{}, %{},
                 registry: registry("run", action),
                 limits: Limits.default()
               )
    end
  end

  test "keeps executable descriptor resolution inside the expired deadline" do
    registry_started = System.monotonic_time(:millisecond)
    trusted = registry("run", SlowDescriptorAction)
    registry_elapsed = System.monotonic_time(:millisecond) - registry_started

    run_started = System.monotonic_time(:millisecond)

    assert {:error, %Diagnostic{code: :action_timeout}} =
             ActionRunner.run("run", %{}, %{},
               registry: trusted,
               limits: Limits.default(),
               deadline: System.monotonic_time(:millisecond) - 1
             )

    run_elapsed = System.monotonic_time(:millisecond) - run_started
    assert registry_elapsed < 150
    assert run_elapsed < 150
  end

  test "rejects a Flow in the Action registry without invoking its descriptor" do
    assert {:error, %Diagnostic{code: :invalid_registry_handler}} =
             Registry.new(%{
               version: "registry-1",
               entries: [
                 %{
                   kind: :action,
                   alias: "run",
                   permissions: ["execute"],
                   handler: FlowTarget
                 }
               ]
             })
  end

  test "accepts bounded raw and batch output and rejects other malformed calls" do
    assert {:ok, "ok"} =
             ActionRunner.run("run", %{}, %{},
               registry: registry("run", RawAction),
               limits: Limits.default(),
               task_supervisor: Jido.Exec.TaskSupervisor
             )

    assert {:ok, [%{"id" => 1}]} =
             ActionRunner.run("run", %{}, %{},
               registry: registry("run", BatchAction),
               limits: Limits.default()
             )

    assert {:error, %Diagnostic{code: :invalid_data_key}} =
             ActionRunner.run("run", %{}, %{},
               registry: registry("run", AtomKeyAction),
               limits: Limits.default()
             )

    assert {:error, %Diagnostic{code: :action_failed}} =
             ActionRunner.run("run", %{}, %{},
               registry: registry("run", FailureAction),
               limits: Limits.default()
             )

    assert {:error, %Diagnostic{code: :invalid_deadline}} =
             ActionRunner.run("run", %{}, %{},
               registry: registry("run", ContextAction),
               limits: Limits.default(),
               deadline: :invalid
             )

    assert {:error, %Diagnostic{code: :non_portable_value}} =
             ActionRunner.run("run", %{"pid" => self()}, %{},
               registry: registry("run", ContextAction),
               limits: Limits.default()
             )

    assert {:error, %Diagnostic{code: :invalid_action_call}} =
             ActionRunner.run(1, %{}, %{}, [])

    assert {:error, %Diagnostic{code: :invalid_action_call}} =
             ActionRunner.run("run", %{}, %{}, [1])

    forged = %{Limits.default() | data_bytes: -1}

    assert {:error, %Diagnostic{code: :limit_out_of_range}} =
             ActionRunner.run("run", %{}, %{},
               registry: registry("run", ContextAction),
               limits: forged
             )
  end

  defp registry(name, action, permissions \\ ["execute"]) do
    Registry.new!(%{
      version: "registry-1",
      entries: [
        %{
          kind: :action,
          alias: name,
          permissions: permissions,
          handler: action
        }
      ]
    })
  end
end
