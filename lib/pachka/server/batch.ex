defmodule Pachka.Server.Batch do
  import Record

  @type t :: record(:batch, list: [Pachka.message()], length: non_neg_integer())
  defrecordp :batch, __MODULE__, list: [], length: 0

  defguard is_empty(batch) when batch(batch, :length) == 0

  @dialyzer {:no_underspecs, new: 0}

  @spec new() :: t()
  def new, do: batch()

  @spec add(t(), Pachka.message()) :: t()
  def add(batch, message) do
    batch(list: list, length: length) = batch

    batch(list: [message | list], length: length + 1)
  end

  @spec length(t()) :: non_neg_integer()
  def length(batch), do: batch(batch, :length)

  @spec to_list(t()) :: [Pachka.message()]
  def to_list(batch) do
    batch
    |> batch(:list)
    |> Enum.reverse()
  end
end
