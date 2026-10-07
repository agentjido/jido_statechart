defmodule Jido.Statechart.Model.Event do
  @moduledoc "A normalized SCXML event with separate transport and send identities."

  alias Jido.Statechart.Diagnostic

  @classes [:external, :internal, :platform]
  @fields [
    :name,
    :class,
    :data,
    :message_id,
    :send_id,
    :origin,
    :origin_type,
    :invoke_id,
    :turn_id,
    :session_id
  ]

  defstruct name: nil,
            class: :external,
            data: nil,
            message_id: nil,
            send_id: nil,
            origin: nil,
            origin_type: nil,
            invoke_id: nil,
            turn_id: nil,
            session_id: nil

  @type t :: %__MODULE__{}

  @spec new(map()) :: {:ok, t()} | {:error, Diagnostic.t()}
  def new(attrs) when is_map(attrs) do
    with :ok <- Diagnostic.validate_fields(attrs, @fields, [:event]) do
      event = %__MODULE__{
        name: Diagnostic.fetch(attrs, :name),
        class: Diagnostic.fetch(attrs, :class, :external),
        data: Diagnostic.fetch(attrs, :data),
        message_id: Diagnostic.fetch(attrs, :message_id),
        send_id: Diagnostic.fetch(attrs, :send_id),
        origin: Diagnostic.fetch(attrs, :origin),
        origin_type: Diagnostic.fetch(attrs, :origin_type),
        invoke_id: Diagnostic.fetch(attrs, :invoke_id),
        turn_id: Diagnostic.fetch(attrs, :turn_id),
        session_id: Diagnostic.fetch(attrs, :session_id)
      }

      with {:ok, _name} <- Diagnostic.require_string(event, :name, [:event]),
           {:ok, class} <- event_class(event.class),
           :ok <- Diagnostic.portable(event.data, [:event, :data]),
           :ok <- optional_strings(event) do
        {:ok, %{event | class: class}}
      end
    end
  end

  def new(_attrs),
    do: {:error, Diagnostic.new(:invalid_event, "event must be a map", path: [:event])}

  @spec new!(map()) :: t()
  def new!(attrs), do: attrs |> new() |> Diagnostic.unwrap!()

  @doc false
  @spec new_external(map()) :: {:ok, t()} | {:error, Diagnostic.t()}
  def new_external(%__MODULE__{} = event), do: event |> Map.from_struct() |> new_external()

  def new_external(attrs) when is_map(attrs) do
    with {:ok, event} <- new(attrs),
         :ok <- external_class(event.class) do
      {:ok, event}
    end
  end

  def new_external(_attrs),
    do: {:error, Diagnostic.new(:invalid_event, "external event must be a map", path: [:event])}

  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = event) do
    event
    |> Map.from_struct()
    |> Map.new(fn
      {:class, value} -> {"class", Atom.to_string(value)}
      {key, value} -> {Atom.to_string(key), value}
    end)
  end

  defp event_class(class) when class in @classes, do: {:ok, class}

  defp event_class(class) when is_binary(class) do
    case Enum.find(@classes, &(Atom.to_string(&1) == class)) do
      nil -> invalid_event_class()
      known -> {:ok, known}
    end
  end

  defp event_class(_class), do: invalid_event_class()

  defp invalid_event_class,
    do:
      {:error,
       Diagnostic.new(:invalid_event_class, "event class is not supported",
         path: [:event, :class]
       )}

  defp external_class(:external), do: :ok

  defp external_class(_class),
    do:
      {:error,
       Diagnostic.new(:invalid_external_event_class, "public event class must be external",
         path: [:event, :class]
       )}

  defp optional_strings(event) do
    [:message_id, :send_id, :origin, :origin_type, :invoke_id, :turn_id, :session_id]
    |> Enum.reduce_while(:ok, fn field, :ok ->
      case Diagnostic.optional_string(event, field, [:event]) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
end
