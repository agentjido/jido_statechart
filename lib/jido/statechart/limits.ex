defmodule Jido.Statechart.Limits do
  @moduledoc "Bounded resource limits that form part of a session contract."

  alias Jido.Statechart.Diagnostic

  @bounds %{
    xml_bytes: %{min: 1, max: 16_777_216, default: 1_048_576},
    xml_depth: %{min: 1, max: 256, default: 64},
    xml_attributes: %{min: 0, max: 512, default: 64},
    xml_nodes: %{min: 1, max: 100_000, default: 10_000},
    xml_text_bytes: %{min: 0, max: 8_388_608, default: 1_048_576},
    expression_steps: %{min: 1, max: 1_000_000, default: 10_000},
    microsteps_per_macrostep: %{min: 1, max: 10_000, default: 1_000},
    internal_queue_events: %{min: 0, max: 100_000, default: 10_000},
    trace_entries: %{min: 0, max: 100_000, default: 10_000},
    data_bytes: %{min: 0, max: 16_777_216, default: 1_048_576},
    external_intents: %{min: 0, max: 10_000, default: 1_000},
    timer_horizon_ms: %{min: 0, max: 31_536_000_000, default: 2_678_400_000},
    invocation_depth: %{min: 0, max: 64, default: 16},
    total_descendants: %{min: 0, max: 100_000, default: 1_000},
    pending_sends: %{min: 0, max: 100_000, default: 1_000},
    pending_timers: %{min: 0, max: 100_000, default: 1_000},
    pending_invocations: %{min: 0, max: 100_000, default: 1_000},
    terminal_records: %{min: 0, max: 1_000_000, default: 10_000},
    session_bytes: %{min: 1_024, max: 134_217_728, default: 8_388_608},
    reconciliation_batch: %{min: 1, max: 10_000, default: 100},
    runtime_concurrency: %{min: 1, max: 10_000, default: 64},
    runtime_turns_per_minute: %{min: 1, max: 1_000_000, default: 1_000}
  }

  @fields @bounds |> Map.keys() |> Enum.sort()

  defstruct Enum.map(@fields, &{&1, @bounds[&1].default})

  @type t :: %__MODULE__{}

  @doc "Returns the supported hard bounds."
  @spec bounds() :: map()
  def bounds, do: @bounds

  @doc "Returns the default limit attributes."
  @spec defaults() :: map()
  def defaults, do: Map.new(@bounds, fn {name, spec} -> {name, spec.default} end)

  @doc "Returns the validated default limits."
  @spec default() :: t()
  def default, do: struct!(__MODULE__, defaults())

  @doc "Builds a validated limits contract."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, Diagnostic.t()}
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    with :ok <- Diagnostic.validate_fields(attrs, @fields, [:limits]),
         {:ok, values} <- values(attrs) do
      {:ok, struct!(__MODULE__, values)}
    end
  end

  def new(_attrs),
    do: {:error, Diagnostic.new(:invalid_limits, "limits must be a map", path: [:limits])}

  @spec new!(map() | keyword() | t()) :: t()
  def new!(attrs), do: attrs |> new() |> Diagnostic.unwrap!()

  @doc "Returns a portable limits map."
  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = limits) do
    Map.new(@fields, fn field -> {Atom.to_string(field), Map.fetch!(limits, field)} end)
  end

  @doc "Returns the digest that binds a session to these limits."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = limits), do: limits |> dump() |> Diagnostic.digest()

  defp values(attrs) do
    Enum.reduce_while(@fields, {:ok, %{}}, fn field, {:ok, acc} ->
      value = Diagnostic.fetch(attrs, field, @bounds[field].default)
      %{min: min, max: max} = @bounds[field]

      if is_integer(value) and value >= min and value <= max do
        {:cont, {:ok, Map.put(acc, field, value)}}
      else
        {:halt,
         {:error,
          Diagnostic.new(:limit_out_of_range, "limit is outside its hard bounds",
            path: [:limits, field],
            correction: %{"minimum" => min, "maximum" => max}
          )}}
      end
    end)
  end
end
