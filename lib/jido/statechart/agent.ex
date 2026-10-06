defmodule Jido.Statechart.Agent do
  @moduledoc """
  Elixir authoring for ordinary Jido Agent definitions.

      use Jido.Statechart.Agent, name: "door"

      statechart id: "door", initial: "closed" do
        state "closed" do
          transition "open", target: "opened"
        end
        state "opened" do
          transition "close", target: "closed"
        end
      end

  Override `registry/0` for trusted guards and reducers. Override `effects/0`
  with a map of string IDs to pure one-argument Directive builders. Each builder
  returns `{:ok, directive}`. Signals cannot select code or replace this metadata.

  New Agents start with a `"new"` chart configuration. The first Signal runs
  initial entry and stabilization before its event, in one bounded Turn.
  This keeps initialization effects inside Jido's commit boundary.
  """
  @behaviour Jido.Agent
  alias Jido.Statechart.{Definition, Error, Instance, Registry, Validator}

  @doc "Defines an Agent and imports the statechart authoring block."
  defmacro __using__(opts) do
    quote do
      @behaviour Jido.Agent
      import Jido.Statechart.Agent, only: [statechart: 2]
      @statechart_agent_options unquote(opts)
      @before_compile Jido.Statechart.Agent
      def registry, do: %Jido.Statechart.Registry{}
      def effects, do: %{}
      defoverridable registry: 0, effects: 0
    end
  end

  @doc "Compiles a statechart authoring block into the normalized data model."
  defmacro statechart(opts, do: block) do
    states = lower_states(block, nil)

    quote do
      if Module.has_attribute?(__MODULE__, :statechart_definition),
        do: raise(ArgumentError, "Define exactly one statechart block")

      @statechart_definition Jido.Statechart.compile!(
                               Map.merge(Map.new(unquote(opts)), %{states: unquote(states)})
                             )
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    opts = Module.get_attribute(env.module, :statechart_agent_options)
    definition = Module.get_attribute(env.module, :statechart_definition)
    if definition == nil, do: raise(ArgumentError, "Define one statechart block")
    name = Keyword.fetch!(opts, :name)
    vsn = Keyword.get(opts, :vsn, 1)
    data_schema = Keyword.get(opts, :data_schema, Zoi.map() |> Zoi.default(%{}))

    quote do
      @doc "Returns the compiled statechart definition."
      def chart_definition, do: unquote(Macro.escape(definition))
      @doc "Returns the Agent definition version."
      def vsn, do: unquote(vsn)
      @doc "Returns the ordinary Jido Agent definition with trusted chart metadata."
      def definition do
        case Jido.Statechart.Agent.build(
               __MODULE__,
               unquote(name),
               chart_definition(),
               registry(),
               data_schema: unquote(Macro.escape(data_schema)),
               vsn: vsn(),
               effects: effects()
             ) do
          {:ok, agent} -> agent
          {:error, error} -> raise error
        end
      end

      @doc false
      def __agent_config__,
        do: definition() |> Map.from_struct() |> Map.drop([:id, :state, :module])

      @doc "Creates an Agent instance."
      def new(overrides \\ []), do: Jido.Agent.instantiate(__MODULE__, overrides)
      @doc "Creates an Agent instance or raises its validation error."
      def new!(overrides \\ []), do: Jido.Agent.instantiate!(__MODULE__, overrides)
      @doc "Applies one Signal without starting AgentServer."
      def cmd(agent, signal, opts \\ []), do: Jido.Agent.cmd(agent, signal, opts)
      @impl Jido.Agent
      def handle_signal(signal, agent), do: Jido.Statechart.Agent.handle_signal(signal, agent)
      @impl Jido.Agent
      def checkpoint(agent, context), do: Jido.Statechart.Agent.checkpoint(agent, context)
      @impl Jido.Agent
      def restore(payload, context),
        do: Jido.Statechart.Agent.restore(__MODULE__, payload, context)
    end
  end

  @doc "Builds an ordinary Agent definition from compiled data and trusted callbacks."
  @spec build(module(), String.t(), Definition.t(), Registry.t(), keyword()) ::
          {:ok, Jido.Agent.t()} | {:error, term()}
  def build(module, name, definition, registry \\ %Registry{}, opts \\ []) do
    with :ok <- Validator.definition(definition),
         :ok <- Registry.validate(definition, registry),
         :ok <- valid_effects(Keyword.get(opts, :effects, %{})) do
      default = %{fingerprint: definition.fingerprint, active: [], status: "new"}

      schema =
        Zoi.object(%{
          chart: Zoi.map() |> Zoi.default(default),
          data: Keyword.get(opts, :data_schema, Zoi.map() |> Zoi.default(%{}))
        })
        |> Zoi.refine({__MODULE__, :validate_state, [definition]})

      Jido.Agent.new(%{
        module: module,
        name: name,
        vsn: Keyword.get(opts, :vsn, 1),
        schema: schema,
        metadata: %{
          statechart: %{
            definition: definition,
            registry: registry,
            effects: Keyword.get(opts, :effects, %{})
          }
        }
      })
    end
  end

  @doc "Creates one trusted Step Turn bound to the original Signal."
  @spec handle_signal(Jido.Signal.t(), Jido.Agent.t()) :: Jido.Agent.handle_result()
  @impl Jido.Agent
  def handle_signal(%Jido.Signal{} = signal, %Jido.Agent{} = agent) do
    with {:ok, trusted} <- trusted_metadata(agent),
         {:ok, data} <- Jido.Agent.Turn.normalize_input(signal.data),
         {:ok, event} <- Jido.Statechart.Event.new(signal.type, data) do
      Jido.Agent.Turn.new(Jido.Statechart.Step, %{trusted: trusted, event: event}, signal)
    end
  end

  @doc false
  def trusted_metadata(%Jido.Agent{metadata: %{statechart: trusted}} = agent) do
    with :ok <- Validator.definition(trusted.definition),
         :ok <- Registry.validate(trusted.definition, trusted.registry),
         :ok <- valid_effects(trusted.effects),
         :ok <- same_module_definition(agent) do
      {:ok, trusted}
    end
  rescue
    _ -> Error.result(:definition_mismatch, "Malformed trusted statechart metadata")
  end

  def trusted_metadata(_),
    do: Error.result(:definition_mismatch, "Agent lacks trusted statechart metadata")

  defp same_module_definition(agent) do
    if function_exported?(agent.module, :definition, 0) and
         Jido.Agent.definition(agent) != agent.module.definition(),
       do: Error.result(:definition_mismatch, "Agent definition differs from its trusted module"),
       else: :ok
  end

  @doc "Checks complete Agent chart and domain state without changing values."
  @spec validate_state(term(), Definition.t(), keyword()) :: :ok | {:error, String.t()}
  defdelegate validate_state(state, definition, options), to: Jido.Statechart.AgentState

  @doc "Converts an interpreter candidate into Agent state fields."
  @spec encode_state(Instance.t()) :: map()
  defdelegate encode_state(instance), to: Jido.Statechart.AgentState

  @doc "Reads mutable chart configuration without selecting executable code."
  @spec decode_state(term()) :: {:ok, Instance.t()} | {:error, Error.t()}
  defdelegate decode_state(state), to: Jido.Statechart.AgentState

  @doc "Creates a custom checkpoint payload with a behavior fingerprint."
  @spec checkpoint(Jido.Agent.t(), map()) :: {:ok, map()} | {:error, term()}
  @impl Jido.Agent
  def checkpoint(agent, _context) do
    with {:ok, trusted} <- trusted_metadata(agent),
         {:ok, instance} <- decode_state(agent.state),
         :ok <- Validator.instance(trusted.definition, instance) do
      {:ok, %{id: agent.id, fingerprint: trusted.definition.fingerprint, state: agent.state}}
    end
  end

  @doc "Restores only mutable state using the current trusted module definition."
  @spec restore(module(), term(), map()) :: {:ok, Jido.Agent.t()} | {:error, term()}
  def restore(module, %{id: id, fingerprint: fingerprint, state: state} = payload, _context)
      when map_size(payload) == 3 do
    definition = module.definition()

    if fingerprint == definition.metadata.statechart.definition.fingerprint do
      Jido.Agent.validate_instance(%{definition | id: id, state: state})
    else
      Error.result(:definition_mismatch, "Checkpoint behavior fingerprint does not match")
    end
  end

  def restore(_, _, _), do: Error.result(:invalid_checkpoint, "Malformed statechart checkpoint")

  @doc "Restores a data-built generic Agent using an explicitly supplied trusted definition."
  @spec restore(term(), map()) :: {:ok, Jido.Agent.t()} | {:error, term()}
  @impl Jido.Agent
  def restore(
        %{id: id, fingerprint: fingerprint, state: state} = payload,
        %{statechart_definition: %Jido.Agent{module: __MODULE__} = definition}
      )
      when map_size(payload) == 3 do
    with {:ok, trusted} <- trusted_metadata(definition),
         true <- fingerprint == trusted.definition.fingerprint do
      Jido.Agent.validate_instance(%{definition | id: id, state: state})
    else
      false ->
        Error.result(:definition_mismatch, "Checkpoint behavior fingerprint does not match")

      error ->
        error
    end
  end

  def restore(_, _),
    do:
      Error.result(
        :invalid_checkpoint,
        "Generic restore requires a trusted statechart_definition in context"
      )

  defp valid_effects(effects) when is_map(effects) and not is_struct(effects) do
    if map_size(effects) <= 4096 and
         Enum.all?(effects, fn {id, builder} ->
           is_binary(id) and byte_size(id) in 1..4096 and String.valid?(id) and
             is_function(builder, 1)
         end),
       do: :ok,
       else: Error.result(:invalid_registry, "Effect IDs require trusted Directive builders")
  end

  defp valid_effects(_),
    do: Error.result(:invalid_registry, "Effect builders must be a plain map")

  defp lower_states(block, parent) do
    block
    |> statements()
    |> Enum.flat_map(fn
      {:state, _, [id]} ->
        lower_state(id, [], nil, parent)

      {:state, _, [id, opts]} ->
        {block, opts} = Keyword.pop(opts, :do)
        lower_state(id, opts, block, parent)

      {:state, _, [id, opts, [do: child]]} ->
        lower_state(id, opts, child, parent)

      _ ->
        raise ArgumentError, "Statechart blocks accept only state declarations"
    end)
  end

  defp lower_state(id, opts, block, parent) do
    declarations = statements(block)
    {transitions, children} = Enum.split_with(declarations, &match?({:transition, _, _}, &1))

    transitions =
      Enum.map(transitions, fn
        {:transition, _, [event, opts]} ->
          quote do: Map.put(Map.new(unquote(opts)), :event, unquote(event))

        {:transition, _, [event]} ->
          quote do: %{event: unquote(event)}

        _ ->
          raise ArgumentError, "Invalid transition declaration"
      end)

    type = if children == [], do: :atomic, else: :compound

    state =
      quote do
        Map.merge(
          %{
            id: unquote(id),
            parent: unquote(parent),
            type: unquote(type),
            transitions: unquote(transitions)
          },
          Map.new(unquote(opts))
        )
      end

    [state | lower_states({:__block__, [], children}, id)]
  end

  defp statements(nil), do: []
  defp statements({:__block__, _, list}), do: list
  defp statements(statement), do: [statement]
end
