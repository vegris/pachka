defmodule Pachka.Config do
  @moduledoc false

  schema = [
    sink: [
      type: :atom,
      required: true,
      type_spec: quote(do: module()),
      type_doc: "`t:module/0`",
      doc:
        "The module that implements the `Pachka.Sink` behavior for processing batched messages."
    ],
    name: [
      type_spec: quote(do: GenServer.name()),
      type_doc: "`t:GenServer.name/0`",
      doc:
        "The name to register the Pachka server process under. See [Name Registration](https://hexdocs.pm/elixir/GenServer.html#module-name-registration) for details."
    ],
    server_value: [
      type: :any,
      default: nil,
      type_spec: quote(do: Pachka.Sink.server_value()),
      type_doc: "`t:Pachka.Sink.server_value/0`",
      doc:
        "Value passed by the server process to `Pachka.Sink` callback functions. Can be used to distinguish between different Pachka processes using the same sink module or to store server-specific configuration."
    ],
    start_link_opts: [
      type: :keyword_list,
      type_spec: quote(do: GenServer.options()),
      type_doc: "`t:GenServer.options/0`",
      doc: "Options passed to `GenServer.start_link/3`"
    ],
    max_batch_size: [
      type: :pos_integer,
      default: 500,
      type_doc: "`t:pos_integer/0`",
      doc:
        "Maximum number of messages to accumulate before forcing a batch export. Batches sent to `c:Pachka.Sink.send_batch/2` are guaranteed to be no larger than that size."
    ],
    critical_queue_size: [
      type: :pos_integer,
      default: 10_000,
      type_doc: "`t:pos_integer/0`",
      doc: "Maximum number of messages the server can hold before it starts rejecting new ones."
    ],
    max_batch_delay: [
      type: :timeout,
      default: :timer.seconds(5),
      type_doc: "`t:timeout/0`",
      doc: "Maximum time to wait before exporting a batch."
    ],
    export_timeout: [
      type: :timeout,
      default: :timer.seconds(10),
      type_doc: "`t:timeout/0`",
      doc: "Maximum time allowed for the `c:Pachka.Sink.send_batch/2` to process a batch."
    ]
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

  @enforce_keys Keyword.keys(struct_schema)
  defstruct @enforce_keys

  @schema NimbleOptions.new!(schema)

  @spec parse_options(Pachka.options()) :: {t(), GenServer.options()}
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

  @spec schema :: NimbleOptions.t()
  def schema, do: @schema
end
