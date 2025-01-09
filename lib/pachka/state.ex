defmodule Pachka.State do
  @moduledoc false

  @type t :: %__MODULE__{
          config: Pachka.Config.t(),
          state: __MODULE__.Idle.t() | __MODULE__.Exporting.t() | __MODULE__.RetryBackoff.t(),
          queue: [Pachka.message()],
          queue_length: non_neg_integer()
        }

  @enforce_keys ~w[config state]a
  defstruct @enforce_keys ++ [queue: [], queue_length: 0]

  defguard is_empty(state) when state.queue_length == 0
  defguard is_batch_ready(state) when state.queue_length >= state.config.max_batch_size
  defguard is_full(state) when state.queue_length >= state.config.critical_queue_size

  @spec add_message(t(), Pachka.message()) :: t()
  def add_message(%__MODULE__{} = state, message) do
    %__MODULE__{state | queue: [message | state.queue], queue_length: state.queue_length + 1}
  end

  @spec take_batch(t()) :: {[Pachka.message()], t()}
  def take_batch(%__MODULE__{} = state) do
    rest_length = max(state.queue_length - state.config.max_batch_size, 0)
    {rest, batch} = Enum.split(state.queue, rest_length)

    state = %__MODULE__{state | queue: rest, queue_length: rest_length}

    {Enum.reverse(batch), state}
  end
end

defmodule Pachka.State.Idle do
  @moduledoc false

  @type t :: %__MODULE__{
          batch_timer: reference()
        }

  @enforce_keys [:batch_timer]
  defstruct @enforce_keys
end

defmodule Pachka.State.Exporting do
  @moduledoc false

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
  @moduledoc false

  @type t :: %__MODULE__{
          retry_num: non_neg_integer(),
          retry_timer: reference(),
          export_batch: [Pachka.message()],
          failure_reason: Pachka.Sink.failure_reason()
        }

  @enforce_keys ~w[retry_num retry_timer export_batch failure_reason]a
  defstruct @enforce_keys
end
