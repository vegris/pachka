defmodule Pachka.Server do
  use GenServer

  require Logger

  defmodule State do
    @type t :: %__MODULE__{
            handler: module(),
            send_timer: reference(),
            check_timer: reference(),
            export_timer: reference(),
            export_ref: reference(),
            export_pid: pid()
          }

    @enforce_keys [:handler]
    defstruct @enforce_keys ++ ~w[send_timer check_timer export_timer export_ref export_pid]a
  end

  @max_batch_size 500
  @critical_batch_size 10_000
  @max_batch_delay :timer.seconds(5)

  @check_timout :timer.seconds(1)

  @export_timeout :timer.seconds(10)

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

    state = %State{
      handler: Keyword.fetch!(opts, :handler),
      send_timer: Process.send_after(self(), :batch_timeout, @max_batch_delay),
      check_timer: Process.send_after(self(), :check_timeout, @check_timout)
    }

    {:ok, state}
  end

  @impl true
  def handle_info(:batch_timeout, %State{} = state) do
    state =
      if is_nil(state.export_ref) and current_table_size() > 0 do
        export_batch(state)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info(:check_timeout, %State{} = state) do
    table_size = current_table_size()

    state =
      cond do
        is_nil(state.export_ref) and table_size >= @max_batch_size ->
          export_batch(state)

        is_reference(state.export_ref) and table_size >= @critical_batch_size ->
          :persistent_term.put(@current_table_status_key, :overloaded)
          state

        :otherwise ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:export_timeout, ref}, %State{} = state) do
    if ref == state.export_ref do
      Process.exit(state.export_pid, :kill)
    else
      Logger.warning("Received export timeout for finished process", monitor_ref: ref)
    end

    {:noreply, state}
  end

  def handle_info({:"ETS-TRANSFER", table, from_pid, _heir_data}, state) do
    Logger.debug("Inherited table from late process", table: table, process: from_pid)
    :ets.delete_all_objects(table)
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %State{export_ref: ref, export_pid: pid} = state
      ) do
    case reason do
      :normal ->
        _ = Process.cancel_timer(state.export_timer)
        :ok

      :killed ->
        :ok
    end

    {:noreply, %State{state | export_pid: nil, export_ref: nil, export_timer: nil}}
  end

  defp export_batch(%State{} = state) do
    old_table = switch_tables()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        receive do
          {:"ETS-TRANSFER", table, owner_pid, handler} ->
            Logger.debug("Received table from server", table: table, server: owner_pid)

            table
            |> :ets.tab2list()
            |> Keyword.fetch!(:batch)
            |> then(&handler.send_batch/1)
        end
      end)

    :ets.give_away(old_table, pid, state.handler)

    export_timer = Process.send_after(self(), {:export_timeout, monitor_ref}, @export_timeout)

    %State{state | export_pid: pid, export_ref: monitor_ref, export_timer: export_timer}
  end

  defp current_table_size do
    @current_table_key
    |> :persistent_term.get()
    |> :ets.info(:size)
  end

  defp switch_tables do
    old_table = :persistent_term.get(@current_table_key)

    new_table =
      case old_table do
        @table_1 -> @table_2
        @table_2 -> @table_1
      end

    :persistent_term.put(@current_table_key, new_table)
    :persistent_term.put(@current_table_status_key, :available)

    old_table
  end
end
