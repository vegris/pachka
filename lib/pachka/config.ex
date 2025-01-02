defmodule Pachka.Config do
  schema = [
    name: [type: :atom, required: true],
    sink: [type: :atom, required: true, type_spec: quote(do: module())],
    max_batch_size: [type: :pos_integer, default: 500],
    critical_batch_size: [type: :pos_integer, default: 10_000],
    max_batch_delay: [type: :timeout, default: :timer.seconds(5)],
    export_timeout: [type: :timeout, default: :timer.seconds(10)]
  ]

  typespec = NimbleOptions.option_typespec(schema)

  # Converts `type1 | type2 | type3` into `[type1, type2, type3]`
  split_type_union = fn
    {:|, _meta, [type, rest]}, acc, rec_fn -> rec_fn.(rest, [type | acc], rec_fn)
    type, acc, _rec_fn -> [type | acc]
  end

  types = split_type_union.(typespec, [], split_type_union)

  @type t :: %__MODULE__{unquote_splicing(types)}
  @type options :: [unquote(typespec)]

  @enforce_keys Keyword.keys(schema)
  defstruct @enforce_keys

  @schema NimbleOptions.new!(schema)

  @spec from_options(options()) :: t()
  def from_options(options) do
    options
    |> NimbleOptions.validate!(@schema)
    |> then(&struct!(__MODULE__, &1))
  end

  @spec default_retry_timeout(pos_integer(), Pachka.Sink.failure_reason()) :: non_neg_integer()
  def default_retry_timeout(retry_num, _failure_reason), do: :timer.seconds(retry_num)
end
