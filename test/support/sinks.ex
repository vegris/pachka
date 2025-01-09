defmodule Test.Support.Sinks do
  alias __MODULE__

  defmodule SendSink do
    @behaviour Pachka.Sink

    @impl true
    def send_batch(messages, _server_value) do
      send(Sinks.receiver_pid(), {:batch, messages})
      :ok
    end
  end

  defmodule BlockSink do
    @behaviour Pachka.Sink

    @impl true
    def send_batch(messages, _server_value) do
      receive do
        :unblock -> :ok
      end

      send(Sinks.receiver_pid(), {:unblocked, messages})
      :ok
    end
  end

  defmodule ErrorSink do
    @behaviour Pachka.Sink

    @failure_reason :export_failed

    @impl true
    def send_batch(_messages, _server_value), do: {:error, @failure_reason}

    @impl true
    def retry_timeout(retry_num, @failure_reason, _server_value) do
      send(Sinks.receiver_pid(), {:retry, retry_num})
      retry_num * 100
    end
  end

  defmodule DrainSink do
    @behaviour Pachka.Sink

    @impl true
    def send_batch(_messages, _server_value) do
      Process.sleep(:infinity)
    end

    @impl true
    def drain_on_terminate(messages, batch_size, server_value) do
      send(Sinks.receiver_pid(), {:drained, messages, batch_size, server_value})
      :ok
    end
  end

  def set_receiver_pid(pid) do
    Application.put_env(:pachka, __MODULE__, receiver_pid: pid)
  end

  def receiver_pid do
    :pachka
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(:receiver_pid)
  end

  def clear, do: Application.delete_env(:pachka, __MODULE__)
end
