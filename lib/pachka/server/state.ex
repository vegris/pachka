defmodule Pachka.Server.State do
  @type t :: %__MODULE__{
          config: Pachka.Config.t(),
          state: __MODULE__.Idle.t() | __MODULE__.Exporting.t() | __MODULE__.RetryBackoff.t(),
          batch: [Pachka.message()],
          batch_length: non_neg_integer()
        }

  @enforce_keys ~w[config state]a
  defstruct @enforce_keys ++ [batch: [], batch_length: 0]

  @spec add_message(t(), Pachka.message()) :: t()
  def add_message(%__MODULE__{} = state, message) do
    %__MODULE__{state | batch: [message | state.batch], batch_length: state.batch_length + 1}
  end

  @spec take_batch(t()) :: {[Pachka.message()], t()}
  def take_batch(%__MODULE__{} = state) do
    batch = Enum.reverse(state.batch)
    state = %__MODULE__{state | batch: [], batch_length: 0}

    {batch, state}
  end
end

defmodule Pachka.Server.State.Idle do
  @type t :: %__MODULE__{
          batch_timer: reference()
        }

  @enforce_keys [:batch_timer]
  defstruct @enforce_keys
end

defmodule Pachka.Server.State.Exporting do
  @type t :: %__MODULE__{
          export_timer: reference(),
          export_pid: pid(),
          export_monitor: reference(),
          export_batch: [Pachka.message()],
          retry_num: non_neg_integer()
        }

  @enforce_keys ~w[export_timer export_pid export_monitor export_batch]a
  defstruct @enforce_keys ++ [retry_num: 0]
end

defmodule Pachka.Server.State.RetryBackoff do
  @type t :: %__MODULE__{
          retry_num: non_neg_integer(),
          retry_timer: reference(),
          export_batch: [Pachka.message()],
          failure_reason: :killed | Pachka.Sink.failure_reason()
        }

  @enforce_keys ~w[retry_num retry_timer export_batch failure_reason]a
  defstruct @enforce_keys
end
