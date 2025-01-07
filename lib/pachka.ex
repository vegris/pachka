defmodule Pachka do
  use GenServer

  alias Pachka.Config

  # One letter name for easier pattern matching
  alias Pachka.State, as: S
  alias Pachka.State.{Idle, Exporting, RetryBackoff}

  require Logger

  # Require guards and create an alias to use them
  require Pachka.State, as: State

  @timer Pachka.Timer.implementation()

  @type message :: term()

  @type option :: unquote(NimbleOptions.option_typespec(Config.schema()))
  @type options :: [option()]

  @doc """
  Sends a message to a `Pachka` server process.

  The message will be added to the queue and eventually delivered to the configured sink. 
  If the server's queue is full, the message will be rejected.

  ## Parameters

    * `name` - The name or pid of the Pachka server process
    * `message` - The message to be sent

  ## Return values

  Returns `:ok` if the message was successfully queued, or `{:error, :overloaded}` if the server's queue is full.

  ## Examples

      iex> Pachka.send_message(MyPachka, %{event: "user_login"})
      :ok

      iex> Pachka.send_message(pid, "message") 
      :ok
  """
  @spec send_message(GenServer.server(), Pachka.message()) :: :ok | {:error, :overloaded}
  def send_message(name, message) do
    GenServer.call(name, {:message, message})
  end

  @doc """
  Starts a `Pachka` server process linked to the current process.

  ## Options

  #{NimbleOptions.docs(Config.schema())}

  ## Return values

  If the server is successfully created and initialized, this function returns `{:ok, pid}`, where `pid` is the PID of the server. If a process with the specified server name already exists, this function returns `{:error, {:already_started, pid}}` with the PID of that process.

  Raises a `NimbleOptions.ValidationError` exception if `opts` are not valid.
  """
  @spec start_link(options()) :: GenServer.on_start()
  def start_link(opts) do
    {config, start_link_opts} = Config.parse_options(opts)
    GenServer.start_link(__MODULE__, config, start_link_opts)
  end

  @spec stop(GenServer.server(), timeout()) :: :ok
  def stop(server, timeout \\ :infinity) do
    GenServer.stop(server, :normal, timeout)
  end

  @impl true
  def init(%Config{} = config) do
    Process.flag(:trap_exit, true)

    state = %S{
      config: config,
      state: %Idle{batch_timer: @timer.send_after(self(), :batch_timeout, config.max_batch_delay)}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:message, _message}, _from, %S{} = state) when State.is_full(state) do
    {:reply, {:error, :overloaded}, state}
  end

  def handle_call({:message, message}, _from, %S{} = state) do
    state =
      state
      |> State.add_message(message)
      |> check_queue_size()

    {:reply, :ok, state}
  end

  defp check_queue_size(%S{state: %Idle{}} = state) when State.is_batch_ready(state),
    do: to_exporting(state)

  defp check_queue_size(%S{} = state), do: state

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
    if State.is_empty(state) do
      to_idle(state)
    else
      to_exporting(state)
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
      if State.is_batch_ready(state) do
        to_exporting(state)
      else
        to_idle(state)
      end
    else
      to_retry_backoff(state, reason)
    end
  end

  defp handle_retry_timeout(%S{state: %RetryBackoff{}} = state) do
    to_exporting(state)
  end

  @impl true
  def terminate(_reason, %S{} = state), do: drain_messages(state)

  defp drain_messages(%S{state: %Idle{}} = state) when State.is_empty(state), do: state

  defp drain_messages(%S{state: %Idle{}} = state) do
    state |> to_exporting() |> drain_messages()
  end

  defp drain_messages(%S{state: %Exporting{}} = state) do
    state =
      receive do
        {:export_timeout, pid} -> handle_export_timeout(state, pid)
        {:EXIT, pid, reason} -> handle_process_exit(state, pid, reason)
      end

    drain_messages(state)
  end

  defp drain_messages(%S{state: %RetryBackoff{}} = state) do
    state =
      receive do
        :retry_timeout -> to_exporting(state)
      end

    drain_messages(state)
  end

  defp to_idle(%S{state: %struct{}} = state) when struct in [Idle, Exporting] do
    idle = %Idle{
      batch_timer: @timer.send_after(self(), :batch_timeout, state.config.max_batch_delay)
    }

    %S{state | state: idle}
  end

  defp to_exporting(%S{state: %struct{}} = state) when struct in [Idle, Exporting] do
    {batch, state} = State.take_batch(state)

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
      if function_exported?(sink, :retry_timeout, 3) do
        sink.retry_timeout(retry_num, reason, state.config.server_value)
      else
        default_retry_timeout(retry_num)
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
    server_value = config.server_value

    pid =
      spawn_link(fn ->
        Logger.debug("Starting batch export")

        case sink.send_batch(batch, server_value) do
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

  defp default_retry_timeout(retry_num), do: :timer.seconds(retry_num)
end
