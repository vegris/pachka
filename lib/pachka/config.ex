defmodule Pachka.Config do
  schema = [
    name: [type_spec: quote(do: GenServer.name())],
    sink: [type: :atom, required: true, type_spec: quote(do: module())],
    server_value: [type: :any, default: nil, type_spec: quote(do: Pachka.Sink.server_value())],
    start_link_opts: [type: :keyword_list, type_spec: quote(do: GenServer.options())],
    max_batch_size: [type: :pos_integer, default: 500],
    critical_batch_size: [type: :pos_integer, default: 10_000],
    max_batch_delay: [type: :timeout, default: :timer.seconds(5)],
    export_timeout: [type: :timeout, default: :timer.seconds(10)]
  ]

  struct_schema = Keyword.drop(schema, [:name, :start_link_opts])

  # Converts `type1 | type2 | type3` into `[type1, type2, type3]`
  split_type_union = fn
    {:|, _meta, [type, rest]}, acc, rec_fn -> rec_fn.(rest, [type | acc], rec_fn)
    type, acc, _rec_fn -> [type | acc]
  end

  struct_types =
    struct_schema
    |> NimbleOptions.option_typespec()
    |> split_type_union.([], split_type_union)

  @type t :: %__MODULE__{unquote_splicing(struct_types)}
  @type options :: [unquote(NimbleOptions.option_typespec(schema))]

  @enforce_keys Keyword.keys(struct_schema)
  defstruct @enforce_keys

  @schema NimbleOptions.new!(schema)

  @spec parse_options(options()) :: {t(), GenServer.options()}
  def parse_options(options) do
    {genserver_opts, pachka_opts} =
      options
      |> NimbleOptions.validate!(@schema)
      |> Keyword.split([:name, :start_link_opts])

    config = struct!(__MODULE__, pachka_opts)

    start_link_opts =
      genserver_opts
      |> Keyword.get(:start_link_opts, [])
      |> Keyword.merge(Keyword.take(genserver_opts, [:name]))

    {config, start_link_opts}
  end
end
