defmodule Pachka.Server.State do
  @type t :: %__MODULE__{
          sink: module(),
          state: __MODULE__.Idle.t() | __MODULE__.Exporting.t() | __MODULE__.RetryBackoff.t(),
          batch: Pachka.Server.Batch.t()
        }

  @enforce_keys ~w[sink state batch]a
  defstruct @enforce_keys
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
          export_batch: [Pachka.message()]
        }

  @enforce_keys ~w[retry_num retry_timer export_batch]a
  defstruct @enforce_keys
end
