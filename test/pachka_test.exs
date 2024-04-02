defmodule PachkaTest do
  use ExUnit.Case

  import Mox

  alias Pachka.Server.State

  alias Test.Support.{NoopTimer, Sink}

  setup [:set_mox_global, :verify_on_exit!, :stub_timer, :configure_sink, :start_server]

  defp stub_timer(_context) do
    stub_with(Pachka.TimerMock, NoopTimer)
    :ok
  end

  defp configure_sink(_context) do
    Sink.set_receiver_pid(self())

    on_exit(fn -> Sink.clear() end)
  end

  defp start_server(_context) do
    name = server_name()
    pid = start_link_supervised!({Pachka.Server, name: name, sink: Sink})

    %{name: name, pid: pid}
  end

  defp server_name do
    :"#{Pachka.Server}_#{System.unique_integer()}"
  end

  defp send_messages(name, count) do
    random = Enum.random(1..10_000)

    for i <- random..(random + count - 1) do
      :ok = Pachka.send_message(name, i)
      i
    end
  end

  defp get_export_pid(server_pid) do
    %State{state: %State.Exporting{export_pid: export_pid}} = :sys.get_state(server_pid)
    export_pid
  end

  test "collects and sends batches", %{name: name, pid: pid} do
    for _step <- 1..5 do
      messages = send_messages(name, 300)

      # Send triggered by batch timeout
      send(pid, :batch_timeout)

      assert_receive {:batch, ^messages}
    end

    for _step <- 1..5 do
      messages = send_messages(name, 500)

      # Send triggered by batch size
      assert_receive {:batch, ^messages}
    end
  end

  test "does not start export when table is empty", %{name: name, pid: pid} do
    send(pid, :batch_timeout)
    refute_receive {:batch, _messages}

    messages = send_messages(name, 500)

    assert_receive {:batch, ^messages}

    send(pid, :batch_timeout)
    refute_receive {:batch, _messages}
  end

  @tag :skip
  test "blocks writes on overload", %{name: name, pid: pid} do
    Sink.set_blocking?(true)

    messages = send_messages(name, 15_000)

    send(pid, :check_timeout)
    assert_receive {:batch, ^messages}

    _messages = send_messages(name, 15_000)

    send(pid, :check_timeout)
    refute_receive {:batch, _messages}

    for i <- 1..10 do
      assert {:error, :overloaded} = Pachka.send_message(name, i)
    end
  end

  test "kills exporting process on timeout without losing messages", %{name: name, pid: pid} do
    Sink.set_blocking?(true)

    batch_1 = send_messages(name, 500)
    refute_receive {:batch, _batch_1}

    batch_2 = send_messages(name, 500)
    refute_receive {:batch, _messages}

    export_pid = get_export_pid(pid)
    monitor_ref = Process.monitor(export_pid)
    send(pid, {:export_timeout, export_pid})
    assert_receive {:DOWN, ^monitor_ref, :process, ^export_pid, :killed}

    Sink.set_blocking?(false)

    send(pid, :retry_timeout)
    assert_receive {:batch, ^batch_1}
    assert_receive {:batch, ^batch_2}
  end
end
