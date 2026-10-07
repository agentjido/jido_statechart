defmodule Jido.Statechart.Runtime.Timer do
  @moduledoc "Absolute due-time and generation-fenced keyed timer helpers."

  alias Jido.Statechart.{Diagnostic, Limits}

  @delay ~r/\A(?:0|[0-9]+)(?:\.[0-9]+)?(ms|s)\z/u

  @type timers :: %{optional(String.t()) => %{generation: non_neg_integer(), token: reference()}}

  @spec due_at(nil | String.t(), DateTime.t() | String.t(), Limits.t()) ::
          {:ok, String.t() | nil} | {:error, Diagnostic.t()}
  def due_at(nil, _now, %Limits{}), do: {:ok, nil}

  def due_at(delay, now, %Limits{} = limits) when is_binary(delay) do
    with {:ok, milliseconds} <- delay_ms(delay),
         true <- milliseconds <= limits.timer_horizon_ms,
         {:ok, now} <- datetime(now) do
      due = DateTime.add(now, milliseconds, :millisecond)
      {:ok, DateTime.to_iso8601(due)}
    else
      false ->
        {:error,
         Diagnostic.new(:timer_horizon_exceeded, "Send delay exceeds the timer horizon",
           path: [:send, :delay],
           correction: %{"maximum_ms" => limits.timer_horizon_ms}
         )}

      {:error, _diagnostic} = error ->
        error
    end
  end

  def due_at(_delay, _now, %Limits{}), do: invalid_delay()

  @spec delay_ms(String.t()) :: {:ok, non_neg_integer()} | {:error, Diagnostic.t()}
  def delay_ms(delay) when is_binary(delay) and byte_size(delay) <= 64 do
    case Regex.run(@delay, delay, capture: :all_but_first) do
      [unit] ->
        number = String.trim_trailing(delay, unit)
        multiplier = if unit == "s", do: 1_000, else: 1
        decimal_milliseconds(number, multiplier)

      _other ->
        invalid_delay()
    end
  end

  def delay_ms(_delay), do: invalid_delay()

  @spec due?(String.t() | nil, DateTime.t() | String.t()) :: boolean()
  def due?(nil, _now), do: true

  def due?(due_at, now) do
    with {:ok, due} <- datetime(due_at),
         {:ok, now} <- datetime(now) do
      DateTime.compare(due, now) in [:lt, :eq]
    else
      _other -> false
    end
  end

  @spec milliseconds_until(String.t(), DateTime.t() | String.t()) ::
          {:ok, non_neg_integer()} | {:error, Diagnostic.t()}
  def milliseconds_until(due_at, now) do
    with {:ok, due} <- datetime(due_at),
         {:ok, now} <- datetime(now) do
      {:ok, max(DateTime.diff(due, now, :millisecond), 0)}
    end
  end

  @doc false
  @spec new() :: timers()
  def new, do: %{}

  @doc false
  @spec replace(timers(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, timers(), reference()}
  def replace(timers, key, generation, _delay_ms)
      when is_map(timers) and is_binary(key) and is_integer(generation) and generation >= 0 do
    token = make_ref()
    {:ok, Map.put(timers, key, %{generation: generation, token: token}), token}
  end

  @doc false
  @spec cancel(timers(), String.t(), non_neg_integer()) :: {:ok, timers()}
  def cancel(timers, key, generation) do
    timers =
      case Map.get(timers, key) do
        %{generation: current} when current <= generation -> Map.delete(timers, key)
        _other -> timers
      end

    {:ok, timers}
  end

  @doc false
  @spec fire(timers(), String.t(), non_neg_integer(), reference()) ::
          {:ok, timers()} | :stale | :missing
  def fire(timers, key, generation, token) do
    case Map.get(timers, key) do
      %{generation: ^generation, token: ^token} -> {:ok, Map.delete(timers, key)}
      nil -> :missing
      _other -> :stale
    end
  end

  @spec datetime(DateTime.t() | String.t()) :: {:ok, DateTime.t()} | {:error, Diagnostic.t()}
  def datetime(%DateTime{} = value), do: {:ok, value}

  def datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _other -> invalid_time()
    end
  end

  def datetime(_value), do: invalid_time()

  defp decimal_milliseconds(number, multiplier) do
    case String.split(number, ".", parts: 2) do
      [whole] ->
        {:ok, String.to_integer(whole) * multiplier}

      [whole, fraction] ->
        denominator = Integer.pow(10, byte_size(fraction))
        numerator = String.to_integer(whole <> fraction) * multiplier
        {:ok, div(numerator + div(denominator, 2), denominator)}
    end
  rescue
    _error -> invalid_delay()
  end

  defp invalid_delay do
    {:error,
     Diagnostic.new(:invalid_send_delay, "Send delay must use nonnegative ms or s text",
       path: [:send, :delay]
     )}
  end

  defp invalid_time do
    {:error,
     Diagnostic.new(:invalid_runtime_time, "Runtime time must be UTC ISO 8601 text",
       path: [:runtime, :time]
     )}
  end
end
