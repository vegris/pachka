defmodule Pachka.Server do
  use GenServer

  require Logger

  alias Pachka.Config
  alias Pachka.StatusTable

  alias __MODULE__.State, as: S
  alias __MODULE__.State.{Idle, Exporting, RetryBackoff}

  @timer Pachka.Timer.implementation()

  @spec send_message(atom(), Pachka.message()) :: :ok | {:error, :overloaded}
  def send_message(name, message) do
    status = StatusTable.get_status(name)

    if status == :available do
      GenServer.call(name, {:message, message})
    else
      {:error, status}
    end
  end

  @spec start_link(Config.options()) :: GenServer.on_start()
  def start_link(opts) do
    config = Config.from_options(opts)
    GenServer.start_link(__MODULE__, config, name: config.name)
  end

  @impl true
  def init(%Config{} = config) do
    Process.flag(:trap_exit, true)

    StatusTable.set_status(config.name, :available)

    state = %S{
      config: config,
      state: %Idle{batch_timer: @timer.send_after(self(), :batch_timeout, config.max_batch_delay)}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:message, message}, _from, %S{} = state) do
    state =
      state
      |> S.add_message(message)
      |> check_queue_size()

    {:reply, :ok, state}
  end

  defp check_queue_size(%S{} = state) when state.batch_length < state.config.max_batch_size,
    do: state

  defp check_queue_size(%S{state: %Idle{}} = state), do: to_exporting(state)

  defp check_queue_size(%S{} = state) do
    if Kernel.rem(state.batch_length, state.config.max_batch_size) == 0 and overloaded?(state) do
      StatusTable.set_status(state.config.name, :overloaded)
    end

    state
  end

  @impl true
  def handle_info(msg, %S{} = state) do
    state =
      case msg do
        :batch_timeout ->
          handle_batch_timeout(state)

        {:export_timeout, export_pid} ->
          handle_export_timeout(state, export_pid)

        {:EXIT, pid, reason} ->
          handle_process_exit(state, pid, reason)

        :retry_timeout ->
          handle_retry_timeout(state)
      end

    {:noreply, state}
  end

  defp handle_batch_timeout(%S{state: %Idle{}} = state) do
    if state.batch_length > 0 do
      to_exporting(state)
    else
      to_idle(state)
    end
  end

  defp handle_batch_timeout(%S{state: s} = state) do
    Logger.warning("Received batch timeout in wrong state", state: s.__struct__)

    state
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

  defp handle_process_exit(%S{state: %Exporting{} = e} = state, pid, reason) do
    Logger.debug("Received process EXIT message", pid: pid, reason: reason)

    _ = @timer.cancel_timer(e.export_timer)

    if reason == :normal do
      if state.batch_length >= state.config.max_batch_size do
        to_exporting(state)
      else
        StatusTable.set_status(state.config.name, :available)

        to_idle(state)
      end
    else
      to_retry_backoff(state, reason)
    end
  end

  defp handle_retry_timeout(%S{state: %RetryBackoff{}} = state) do
    to_exporting(state)
  end

  defp to_idle(%S{state: %struct{}} = state) when struct in [Idle, Exporting] do
    idle = %Idle{
      batch_timer: @timer.send_after(self(), :batch_timeout, state.config.max_batch_delay)
    }

    %S{state | state: idle}
  end

  defp to_exporting(%S{state: %struct{}} = state) when struct in [Idle, Exporting] do
    {batch, state} = S.take_batch(state)

    %S{state | state: export(state.config, batch)}
  end

  defp to_exporting(%S{state: %RetryBackoff{} = r} = state) do
    exporting = export(state.config, r.export_batch, r.retry_num)

    %S{state | state: exporting}
  end

  defp to_retry_backoff(%S{state: %Exporting{} = e} = state, reason) do
    sink = state.config.sink

    retry_num = e.retry_num + 1

    retry_timeout =
      if function_exported?(sink, :retry_timeout, 2) do
        sink.retry_timeout(retry_num, reason)
      else
        Config.default_retry_timeout(retry_num, reason)
      end

    retry_backoff = %RetryBackoff{
      retry_num: retry_num,
      retry_timer: @timer.send_after(self(), :retry_timeout, retry_timeout),
      export_batch: e.export_batch,
      failure_reason: reason
    }

    %S{state | state: retry_backoff}
  end

  defp export(%Config{} = config, batch, retry_num \\ 0) do
    sink = config.sink

    pid =
      spawn_link(fn ->
        Logger.debug("Starting batch export")

        case sink.send_batch(batch) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.debug("Batch export failed", reason: reason)
            exit(reason)
        end
      end)

    %Exporting{
      export_timer: @timer.send_after(self(), {:export_timeout, pid}, config.export_timeout),
      export_pid: pid,
      export_batch: batch,
      retry_num: retry_num
    }
  end

  defp overloaded?(%S{} = state) do
    {:message_queue_len, message_count} = Process.info(self(), :message_queue_len)

    state.batch_length + message_count >= state.config.critical_batch_size
  end
end
