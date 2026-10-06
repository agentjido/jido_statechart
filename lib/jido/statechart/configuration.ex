defmodule Jido.Statechart.Configuration do
  @moduledoc "Mutable chart configuration. Active states are an ordered root-to-leaf path."
  @type t :: %__MODULE__{
          fingerprint: String.t(),
          active: [String.t()],
          status: :new | :running | :done
        }
  @enforce_keys [:fingerprint, :active, :status]
  defstruct @enforce_keys
end

defmodule Jido.Statechart.Instance do
  @moduledoc "A runtime chart value. It contains no process, callback, or executable module."
  @type t :: %__MODULE__{configuration: Jido.Statechart.Configuration.t(), data: map()}
  @enforce_keys [:configuration, :data]
  defstruct @enforce_keys
end

defmodule Jido.Statechart.Effect do
  @moduledoc "A post-commit request. The application owns the handler for its string ID."
  @type t :: %__MODULE__{id: String.t(), data: map()}
  @enforce_keys [:id, :data]
  defstruct @enforce_keys
end

defmodule Jido.Statechart.Result do
  @moduledoc "A stable macrostep result with ordered effects, trace, and operation counts."
  @type t :: %__MODULE__{
          instance: Jido.Statechart.Instance.t(),
          effects: [Jido.Statechart.Effect.t()],
          trace: [map()],
          stats: map()
        }
  @enforce_keys [:instance, :effects, :trace, :stats]
  defstruct @enforce_keys
end
