defmodule Jido.Statechart.Definition do
  @moduledoc "Immutable normalized behavior. Build this value with `Jido.Statechart.compile/1`."
  @type t :: %__MODULE__{
          id: String.t(),
          version: String.t(),
          initial: String.t(),
          states: %{String.t() => Jido.Statechart.State.t()},
          limits: Jido.Statechart.Limits.t(),
          fingerprint: String.t()
        }
  @enforce_keys [:id, :version, :initial, :states, :limits, :fingerprint]
  defstruct @enforce_keys
end

defmodule Jido.Statechart.State do
  @moduledoc "One normalized state with ordered transition and action lists."
  @type t :: %__MODULE__{
          id: String.t(),
          parent: String.t() | nil,
          type: :atomic | :compound | :final,
          initial: String.t() | nil,
          entry: list(),
          exit: list(),
          transitions: [Jido.Statechart.Transition.t()]
        }
  @enforce_keys [:id, :parent, :type, :initial, :entry, :exit, :transitions]
  defstruct @enforce_keys
end

defmodule Jido.Statechart.Transition do
  @moduledoc "One normalized transition. Higher priority wins within the same source state."
  @type t :: %__MODULE__{
          source: String.t(),
          event: String.t() | nil,
          target: String.t() | nil,
          guard: String.t() | nil,
          actions: list(),
          priority: integer(),
          order: non_neg_integer(),
          kind: :external | :internal
        }
  @enforce_keys [:source, :event, :target, :guard, :actions, :priority, :order, :kind]
  defstruct @enforce_keys
end
