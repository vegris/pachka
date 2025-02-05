defmodule Pachka do
  @moduledoc """
  Pachka is a message batching library for Elixir applications.

  It provides a reliable way to collect messages and deliver them in batches to configurable destinations.
  Messages are buffered until either the batch size limit is reached or the batch timeout occurs.
  Failed deliveries are automatically retried with configurable backoff strategies.

  ## Features

    * Configurable batch sizes and timeouts
    * Customizable message sinks for different delivery targets
    * Automatic retries with customizable backoff
    * Overload protection with queue size limits
    * Graceful shutdown with message draining

  ## Example

      defmodule MyApp.MessageSink do
        @behaviour Pachka.Sink
        
        @impl true
        def send_batch(messages, _server_value) do
          # Process messages in batch
          :ok
        end
      end

      # Start Pachka server
      {:ok, pid} = Pachka.start_link(
        name: MyPachka,
        sink: MyApp.MessageSink,
        max_batch_size: 100,
        max_batch_delay: :timer.seconds(1)
      )

      # Send messages
      :ok = Pachka.send_message(MyPachka, %{event: "user_login"})
      :ok = Pachka.send_message(MyPachka, %{event: "page_view"})

  The messages will be collected and delivered to the sink in batches based on the configured
  batch size and delay parameters.

  ## Shutdown

  When a Pachka server receives a shutdown request (via `Pachka.stop/2` or from its parent `Supervisor`), it enters termination mode. During termination, Pachka stops accepting new messages and processes all accumulated messages.

  If `Pachka.Sink` does not implement `c:Pachka.Sink.drain_on_terminate/3`, Pachka processes accumulated messages using its standard operation flow - dividing the queue into batches and invoking `c:Pachka.Sink.send_batch/2` for each batch. On batch failure, Pachka initiates retries with intervals determined by `c:Pachka.Sink.retry_timeout/3`.

  If `Pachka.Sink` implements `c:Pachka.Sink.drain_on_terminate/3`, the Pachka server transfers control to this function along with all accumulated messages.

  > #### `c:Pachka.Sink.drain_on_terminate/3` {: .tip}
  > You can skip implementing `c:Pachka.Sink.drain_on_terminate/3` when export failure risk is minimal - for instance, when storing messages in an SQLite database on the local machine's disk.
  > 
  > For all other scenarios, implement `c:Pachka.Sink.drain_on_terminate/3` with a fallback system to prevent message loss during network outages or target system failures.

  ### In-flight export

  When a Pachka server enters termination mode during an ongoing export, it allows this export to complete normally within the time defined by `export_timeout`. This is a deliberate decision based on the notion that the intersection of two normal operations - batch export and process termination should not result in an abnormal operation - export cancellation before `export_timeout` expires.

  If the in-flight export fails, unsent messages are returned to the queue and the entire queue is passed to `c:Pachka.Sink.drain_on_terminate/3`.

  ### Shutdown timeout

  Pachka does not define a time limit for termination mode. The actual termination time limit is set by the requesting system - either through the `timeout` parameter of `Pachka.stop/2` or via the `:shutdown` option when launched through a `Supervisor` (see [Shutdown values (:shutdown)](https://hexdocs.pm/elixir/Supervisor.html#module-shutdown-values-shutdown)).

  > #### Set the termination timeout based on the worst-case scenario {: .tip}
  > - messages to send = `critical_queue_size` messages in queue + `max_batch_size` unsent messages from in-flight export
  > - time to send them = `shutdown timeout` - `export_timeout` duration spent by the failed export

  ## Startup and shutdown order

  When using Pachka in your supervision tree, the order of children is important for proper startup and shutdown behavior:

  1. Start the sink system first
  2. Start Pachka servers
  3. Start message producers last

  This ordering ensures:

  - During startup: The sink system is ready to receive messages before Pachka begins processing
  - During shutdown: Message producers stop first, then Pachka drains remaining messages, and finally the sink system terminates

  Example configuration:

      children = [
        # 1. Sink system (e.g. database connection)
        MyApp.Repo,
        
        # 2. Pachka server
        {Pachka, name: MyPachka, sink: MyApp.MessageSink},
        
        # 3. Message producers
        MyApp.UserTracker,
        MyApp.MetricsCollector
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  This order prevents message loss during system startup and shutdown since supervisors start children sequentially and shut them down in reverse order (see [Start and shutdown](https://hexdocs.pm/elixir/Supervisor.html#module-start-and-shutdown)).
  """

  use GenServer

  alias Pachka.Config

  # One letter name for easier pattern matching
  alias Pachka.State, as: S
  alias Pachka.State.{Idle, Exporting, RetryBackoff}

  require Logger

  # Require guards and create an alias to use them
  require Pachka.State, as: State

  @timer Pachka.Timer.implementation()

  @typedoc """
  A message that can be sent to a `Pachka` server process.
  """
  @type message :: term()

  @typedoc """
  Option values used by the `start_link/1` function.
  """
  @type option :: unquote(NimbleOptions.option_typespec(Config.schema()))

  @typedoc """
  Options used by the `start_link/1` function.
  """
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

  If the server is successfully created and initialized, this function returns `{:ok, pid}`, where `pid` is the PID of the server.
  If a process with the specified server name already exists, this function returns `{:error, {:already_started, pid}}` with the PID of that process.

  Raises a `NimbleOptions.ValidationError` exception if `opts` are not valid.
  """
  @spec start_link(options()) :: GenServer.on_start()
  def start_link(opts) do
    {config, start_link_opts} = Config.parse_options(opts)
    GenServer.start_link(__MODULE__, config, start_link_opts)
  end

  @doc """
  Synchronously stops the server.

  Refer to the [Shutdown](#module-shutdown) section for information about server termination.
  """
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
  def terminate(_reason, %S{config: %Config{} = config} = state) do
    if function_exported?(config.sink, :drain_on_terminate, 3) do
      unexported_batch = finish_exporting(state)
      messages = unexported_batch ++ Enum.reverse(state.queue)
      config.sink.drain_on_terminate(messages, config.max_batch_size, config.server_value)
    else
      drain_messages(state)
    end

    :ok
  end

  defp finish_exporting(%S{state: %Exporting{} = e} = state) do
    receive do
      {:export_timeout, pid} ->
        state
        |> handle_export_timeout(pid)
        |> finish_exporting()

      {:EXIT, pid, reason} ->
        Logger.debug("Received process EXIT message", pid: pid, reason: reason)

        _ = @timer.cancel_timer(e.export_timer)

        if reason == :normal do
          []
        else
          e.export_batch
        end
    end
  end

  defp finish_exporting(%S{}), do: []

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
