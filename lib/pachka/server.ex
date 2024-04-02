defmodule Pachka.Server do
  use GenServer

  require Logger

  alias __MODULE__.Batch
  alias __MODULE__.State, as: S
  alias __MODULE__.State.{Idle, Exporting, RetryBackoff}

  @timer Pachka.Timer.implementation()

  @max_batch_delay :timer.seconds(5)

  @export_timeout :timer.seconds(10)
  @retry_timeout :timer.seconds(1)

  @spec send_message(atom(), Pachka.message()) :: :ok
  def send_message(name, message) do
    GenServer.call(name, {:message, message})
  end

  def start_link(opts) do
    {name, opts} = Keyword.pop!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    state = %S{
      sink: Keyword.fetch!(opts, :sink),
      state: %Idle{batch_timer: set_batch_timer()},
      batch: Batch.new()
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:message, message}, _from, %S{} = state) do
    state = %S{state | batch: Batch.add(state.batch, message)}
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(msg, %S{} = state) do
    state =
      case msg do
        :batch_timeout ->
          handle_batch_timeout(state)

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
    if Batch.length(state.batch) > 0 do
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

  defp handle_process_down(%S{state: %Exporting{} = e} = state, ref, pid, reason) do
    Logger.debug("Received process DOWN message", pid: pid, ref: ref, reason: reason)

    _ = @timer.cancel_timer(e.export_timer)

    if reason == :normal do
      to_idle(state)
    else
      to_retry_backoff(state)
    end
  end

  defp handle_retry_timeout(%S{state: %RetryBackoff{}} = state) do
    to_exporting(state)
  end

  defp to_idle(%S{state: %struct{}} = state) when struct in [Idle, Exporting] do
    %S{state | state: %Idle{batch_timer: set_batch_timer()}}
  end

  defp to_exporting(%S{state: %Idle{}} = state) do
    exporting = export(state.sink, Batch.to_list(state.batch))

    %S{state | state: exporting, batch: Batch.new()}
  end

  defp to_exporting(%S{state: %RetryBackoff{} = r} = state) do
    exporting = export(state.sink, r.export_batch, r.retry_num + 1)

    %S{state | state: exporting}
  end

  defp to_retry_backoff(%S{state: %Exporting{} = e} = state) do
    retry_backoff = %RetryBackoff{
      retry_num: e.retry_num,
      retry_timer: @timer.send_after(self(), :retry_timeout, @retry_timeout),
      export_batch: e.export_batch
    }

    %S{state | state: retry_backoff}
  end

  defp export(sink, batch, retry_num \\ 0) do
    {pid, monitor_ref} =
      spawn_monitor(fn ->
        Logger.debug("Starting batch export")

        sink.send_batch(batch)
      end)

    %Exporting{
      export_timer: @timer.send_after(self(), {:export_timeout, pid}, @export_timeout),
      export_pid: pid,
      export_monitor: monitor_ref,
      export_batch: batch,
      retry_num: retry_num
    }
  end

  defp set_batch_timer do
    @timer.send_after(self(), :batch_timeout, @max_batch_delay)
  end
end
