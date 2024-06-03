defmodule Pachka.Config do
  schema = [
    name: [type: :atom, required: true],
    sink: [type: :atom, required: true, type_spec: quote(do: module())],
    max_batch_size: [type: :pos_integer, default: 500],
    critical_batch_size: [type: :pos_integer, default: 10_000],
    max_batch_delay: [type: :timeout, default: :timer.seconds(5)],
    export_timeout: [type: :timeout, default: :timer.seconds(10)]
  ]

  @schema NimbleOptions.new!(schema)

  typespecs = NimbleOptions.option_typespec(schema)

  @type options :: [unquote(typespecs)]

  defmodule DeunionizeSpec do
    def deunionize(typespec), do: deunionize(typespec, [])

    defp deunionize({:|, _meta, [type, rest]}, acc), do: deunionize(rest, [type | acc])
    defp deunionize(type, acc), do: [type | acc]
  end

  @type t :: %__MODULE__{unquote_splicing(DeunionizeSpec.deunionize(typespecs))}

  @enforce_keys Keyword.keys(schema)
  defstruct @enforce_keys

  @spec from_options(options()) :: t()
  def from_options(options) do
    options
    |> NimbleOptions.validate!(@schema)
    |> then(&struct!(__MODULE__, &1))
  end

  # Specify return type as timeout() to align with retry_timeout from Pachka.Sink
  # although this function always returns pos_integer()
  @dialyzer {:no_extra_return, default_retry_timeout: 2}

  @spec default_retry_timeout(pos_integer(), :killed | Pachka.Sink.failure_reason()) :: timeout()
  def default_retry_timeout(retry_num, _failure_reason), do: :timer.seconds(retry_num)
end
