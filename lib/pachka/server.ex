defmodule Pachka.Server do
  use GenServer

  require Logger

  alias __MODULE__.Tables
  alias __MODULE__.State, as: S
  alias __MODULE__.State.{Idle, Exporting, RetryBackoff}

  @timer Pachka.Timer.implementation()

  @max_batch_size 500
  @critical_batch_size 10_000
  @max_batch_delay :timer.seconds(5)

  @check_timeout :timer.seconds(1)
  @export_timeout :timer.seconds(10)
  @retry_timeout :timer.seconds(1)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    tables = Tables.create(name)

    state = %S{
      name: name,
      handler: Keyword.fetch!(opts, :handler),
      state: %Idle{batch_timer: set_batch_timer()},
      check_timer: set_check_timer(),
      tables: tables
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

        {:DOWN, ref, :process, pid, reason} ->
          handle_process_down(state, ref, pid, reason)

        :retry_timeout ->
          handle_retry_timeout(state)
      end

    {:noreply, state}
  end

  defp handle_batch_timeout(%S{state: %Idle{}} = state) do
    inactive_table = Tables.switch_active(state.name, state.tables)
    %S{state | state: export_batch(state.handler, inactive_table)}
  end

  defp handle_batch_timeout(%S{state: s} = state) do
    Logger.warning("Received batch timeout in wrong state", state: s.__struct__)

    state
  end

  defp handle_check_timeout(%S{state: s} = state) do
    table_size = Tables.active_size(state.name)

    cond do
      is_struct(s, Idle) and table_size >= @max_batch_size ->
        inactive_table = Tables.switch_active(state.name, state.tables)

        %S{
          state
          | state: export_batch(state.handler, inactive_table),
            check_timer: set_check_timer()
        }

      table_size >= @critical_batch_size ->
        true = :ets.update_element(state.name, :current_table, {3, :overloaded})

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

  defp handle_process_down(%S{state: %Exporting{} = e} = state, ref, pid, reason) do
    Logger.debug("Received process DOWN message", pid: pid, ref: ref, reason: reason)

    _ = @timer.cancel_timer(e.export_timer)

    inactive_table = Tables.inactive_table(state.name, state.tables)
    :ets.insert(inactive_table, {:counter, 0})

    finish_exporting(state, reason)
  end

  defp handle_retry_timeout(%S{state: %RetryBackoff{} = r} = state) do
    inactive_table = Tables.inactive_table(state.name, state.tables)

    state.handler
    |> export_batch(inactive_table)
    |> then(fn %Exporting{} = e ->
      %Exporting{e | retry_num: r.retry_num}
    end)
    |> then(&%S{state | state: &1})
  end

  defp finish_exporting(%S{} = state, :normal) do
    next_s =
      if Tables.active_size(state.name) >= @max_batch_size do
        inactive_table = Tables.switch_active(state.name, state.tables)
        export_batch(state.handler, inactive_table)
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
        Logger.debug("Starting batch export", table: table)

        :ets.delete(table, :counter)

        table
        |> :ets.tab2list()
        |> List.keysort(0)
        |> Enum.map(fn {_index, value} -> value end)
        |> then(&handler.send_batch/1)

        :ets.delete_all_objects(table)
      end)

    %Exporting{
      export_timer: @timer.send_after(self(), {:export_timeout, pid}, @export_timeout),
      export_pid: pid,
      export_monitor: monitor_ref
    }
  end

  defp set_check_timer do
    @timer.send_after(self(), :check_timeout, @check_timeout)
  end

  defp set_batch_timer do
    @timer.send_after(self(), :batch_timeout, @max_batch_delay)
  end
end
