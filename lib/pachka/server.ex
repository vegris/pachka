defmodule Pachka.Server do
  use GenServer

  require Logger

  defmodule State do
    @type t :: %__MODULE__{
            handler: module(),
            state: __MODULE__.Idle.t() | __MODULE__.Exporting.t() | __MODULE__.RetryBackoff.t(),
            check_timer: reference()
          }

    @enforce_keys ~w[handler state check_timer]a
    defstruct @enforce_keys
  end

  defmodule State.Idle do
    @type t :: %__MODULE__{
            batch_timer: reference()
          }

    @enforce_keys [:batch_timer]
    defstruct @enforce_keys
  end

  defmodule State.Exporting do
    @type t :: %__MODULE__{
            export_timer: reference(),
            export_pid: pid(),
            export_monitor: reference(),
            process_down_reason: nil | :normal | :killed,
            table_inherited?: boolean(),
            retry_num: non_neg_integer()
          }

    @enforce_keys ~w[export_timer export_pid export_monitor]a
    defstruct @enforce_keys ++ [:process_down_reason, table_inherited?: false, retry_num: 0]
  end

  defmodule State.RetryBackoff do
    @type t :: %__MODULE__{
            retry_num: non_neg_integer(),
            retry_timer: reference()
          }

    @enforce_keys ~w[retry_num retry_timer]a
    defstruct @enforce_keys
  end

  alias State, as: S
  alias State.{Idle, Exporting, RetryBackoff}

  @timer Pachka.Timer.implementation()

  @max_batch_size 500
  @critical_batch_size 10_000
  @max_batch_delay :timer.seconds(5)

  @check_timeout :timer.seconds(1)
  @export_timeout :timer.seconds(10)
  @retry_timeout :timer.seconds(1)

  @table_1 :"#{__MODULE__}.Table1"
  @table_2 :"#{__MODULE__}.Table2"

  @current_table_key {__MODULE__, :current_table}
  @current_table_status_key {__MODULE__, :current_table_status}

  @spec send_message(Pachka.message()) :: :ok | {:error, :overloaded}
  def send_message(message) do
    status = :persistent_term.get(@current_table_status_key)

    if status == :available do
      @current_table_key
      |> :persistent_term.get()
      |> :ets.insert({:batch, message})

      :ok
    else
      {:error, status}
    end
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    for name <- [@table_1, @table_2] do
      _ =
        :ets.new(name, [
          :duplicate_bag,
          :public,
          :named_table,
          {:heir, self(), nil},
          write_concurrency: true
        ])
    end

    :persistent_term.put(@current_table_key, @table_1)
    :persistent_term.put(@current_table_status_key, :available)

    state = %S{
      handler: Keyword.fetch!(opts, :handler),
      state: %Idle{batch_timer: set_batch_timer()},
      check_timer: set_check_timer()
    }

    {:ok, state}
  end

  @impl true
  def handle_info(msg, %S{} = state) do
    state =
      case msg do
        :batch_timeout ->
          handle_batch_timeout(state)

        :check_timeout ->
          handle_check_timeout(state)

        {:export_timeout, export_pid} ->
          handle_export_timeout(state, export_pid)

        {:"ETS-TRANSFER", table, from_pid, _heir_data} ->
          handle_ets_transfer(state, table, from_pid)

        {:DOWN, ref, :process, pid, reason} ->
          handle_process_down(state, ref, pid, reason)

        :retry_timeout ->
          handle_retry_timeout(state)
      end

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    for name <- [@table_1, @table_2] do
      :ets.delete(name)
    end

    :ok
  end

  defp handle_batch_timeout(%S{state: %Idle{}} = state) do
    %State{state | state: export_batch(state.handler, switch_tables())}
  end

  defp handle_batch_timeout(%S{state: s} = state) do
    Logger.warning("Received batch timeout in wrong state", state: s.__struct__)

    state
  end

  defp handle_check_timeout(%S{state: s} = state) do
    table_size = current_table_size()

    cond do
      is_struct(s, Idle) and table_size >= @max_batch_size ->
        %S{
          state
          | state: export_batch(state.handler, switch_tables()),
            check_timer: set_check_timer()
        }

      table_size >= @critical_batch_size ->
        :persistent_term.put(@current_table_status_key, :overloaded)

        %S{state | check_timer: nil}

      :otherwise ->
        %S{state | check_timer: set_check_timer()}
    end
  end

  defp handle_export_timeout(%S{state: %Exporting{} = e} = state, export_pid) do
    if export_pid == e.export_pid do
      Process.exit(e.export_pid, :kill)
    else
      Logger.warning("Received export timeout for old process",
        old_pid: export_pid,
        current_pid: e.export_pid
      )
    end

    state
  end

  defp handle_export_timeout(%S{state: s} = state, export_pid) do
    Logger.warning("Received export timeout in wrong state",
      state: s.__struct__,
      export_pid: export_pid
    )

    state
  end

  defp handle_ets_transfer(%S{state: %Exporting{} = e} = state, table, from_pid) do
    Logger.debug("Inherited table from late process", table: table, process: from_pid)

    %Exporting{e | table_inherited?: true}
    |> then(&%S{state | state: &1})
    |> maybe_finish_exporting()
  end

  defp handle_process_down(%S{state: %Exporting{} = e} = state, ref, pid, reason) do
    Logger.debug("Received process DOWN message", pid: pid, ref: ref, reason: reason)

    %Exporting{e | process_down_reason: reason}
    |> then(&%S{state | state: &1})
    |> maybe_finish_exporting()
  end

  defp handle_retry_timeout(%S{state: %RetryBackoff{} = r} = state) do
    inactive_table =
      case :persistent_term.get(@current_table_key) do
        @table_1 -> @table_2
        @table_2 -> @table_1
      end

    state.handler
    |> export_batch(inactive_table)
    |> then(fn %Exporting{} = e ->
      %Exporting{e | retry_num: r.retry_num}
    end)
    |> then(&%S{state | state: &1})
  end

  defp maybe_finish_exporting(%S{state: %Exporting{} = e} = state) do
    if e.table_inherited? and e.process_down_reason != nil do
      _ = @timer.cancel_timer(e.export_timer)
      finish_exporting(state, e.process_down_reason)
    else
      state
    end
  end

  defp finish_exporting(%S{} = state, :normal) do
    next_s =
      if current_table_size() >= @max_batch_size do
        export_batch(state.handler, switch_tables())
      else
        %Idle{batch_timer: set_batch_timer()}
      end

    check_timer =
      if state.check_timer == nil do
        set_check_timer()
      else
        state.check_timer
      end

    %S{state | state: next_s, check_timer: check_timer}
  end

  defp finish_exporting(%S{state: %Exporting{} = e} = state, :killed) do
    r = %RetryBackoff{
      retry_num: e.retry_num + 1,
      retry_timer: @timer.send_after(self(), :retry_timeout, @retry_timeout)
    }

    %S{state | state: r}
  end

  defp export_batch(handler, table) do
    {pid, monitor_ref} =
      spawn_monitor(fn ->
        receive do
          {:"ETS-TRANSFER", table, owner_pid, handler} ->
            Logger.debug("Received table from server", table: table, server: owner_pid)

            table
            |> :ets.tab2list()
            |> Enum.map(fn {:batch, value} -> value end)
            |> then(&handler.send_batch/1)

            :ets.delete_all_objects(table)
        end
      end)

    :ets.give_away(table, pid, handler)

    %Exporting{
      export_timer: @timer.send_after(self(), {:export_timeout, pid}, @export_timeout),
      export_pid: pid,
      export_monitor: monitor_ref
    }
  end

  defp current_table_size do
    @current_table_key
    |> :persistent_term.get()
    |> :ets.info(:size)
  end

  defp switch_tables do
    current_table = :persistent_term.get(@current_table_key)

    inactive_table =
      case current_table do
        @table_1 -> @table_2
        @table_2 -> @table_1
      end

    :persistent_term.put(@current_table_key, inactive_table)
    :persistent_term.put(@current_table_status_key, :available)

    current_table
  end

  defp set_check_timer do
    @timer.send_after(self(), :check_timeout, @check_timeout)
  end

  defp set_batch_timer do
    @timer.send_after(self(), :batch_timeout, @max_batch_delay)
  end
end
