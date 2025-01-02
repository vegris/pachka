defmodule Pachka.State do
  @type t :: %__MODULE__{
          config: Pachka.Config.t(),
          state: __MODULE__.Idle.t() | __MODULE__.Exporting.t() | __MODULE__.RetryBackoff.t(),
          batch: [Pachka.message()],
          batch_length: non_neg_integer()
        }

  @enforce_keys ~w[config state]a
  defstruct @enforce_keys ++ [batch: [], batch_length: 0]

  defguard is_empty(state) when state.batch_length == 0
  defguard is_batch_ready(state) when state.batch_length >= state.config.max_batch_size
  defguard is_full(state) when state.batch_length >= state.config.critical_batch_size

  @spec add_message(t(), Pachka.message()) :: t()
  def add_message(%__MODULE__{} = state, message) do
    %__MODULE__{state | batch: [message | state.batch], batch_length: state.batch_length + 1}
  end

  @spec take_batch(t()) :: {[Pachka.message()], t()}
  def take_batch(%__MODULE__{} = state) do
    rest_length = max(state.batch_length - state.config.max_batch_size, 0)
    {rest, batch} = Enum.split(state.batch, rest_length)

    state = %__MODULE__{state | batch: rest, batch_length: rest_length}

    {Enum.reverse(batch), state}
  end
end

defmodule Pachka.State.Idle do
  @type t :: %__MODULE__{
          batch_timer: reference()
        }

  @enforce_keys [:batch_timer]
  defstruct @enforce_keys
end

defmodule Pachka.State.Exporting do
  @type t :: %__MODULE__{
          export_timer: reference(),
          export_pid: pid(),
          export_batch: [Pachka.message()],
          retry_num: non_neg_integer()
        }

  @enforce_keys ~w[export_timer export_pid export_batch]a
  defstruct @enforce_keys ++ [retry_num: 0]
end

defmodule Pachka.State.RetryBackoff do
  @type t :: %__MODULE__{
          retry_num: non_neg_integer(),
          retry_timer: reference(),
          export_batch: [Pachka.message()],
          failure_reason: Pachka.Sink.failure_reason()
        }

  @enforce_keys ~w[retry_num retry_timer export_batch failure_reason]a
  defstruct @enforce_keys
end
