defmodule PachkaTest do
  use ExUnit.Case

  import Mox

  alias Pachka.Server.State

  alias Test.Support.{NoopTimer, SendHandler}

  setup [:set_mox_global, :verify_on_exit!, :stub_timer, :configure_handler, :start_server]

  defp stub_timer(_context) do
    stub_with(Pachka.TimerMock, NoopTimer)
    :ok
  end

  defp configure_handler(_context) do
    SendHandler.set_receiver_pid(self())

    on_exit(fn -> SendHandler.clear() end)
  end

  defp start_server(_context) do
    name = server_name()
    pid = start_link_supervised!({Pachka.Server, name: name, handler: SendHandler})

    %{name: name, pid: pid}
  end

  defp server_name do
    :"#{Pachka.Server}_#{System.unique_integer()}"
  end

  test "collects and sends batches", %{name: name, pid: pid} do
    for _step <- 1..5 do
      messages =
        for i <- 1..500 do
          :ok = Pachka.send_message(name, i)
          i
        end

      send(pid, :batch_timeout)

      assert_receive {:batch, ^messages}
    end
  end

  test "does not start export when table is empty", %{name: name, pid: pid} do
    send(pid, :batch_timeout)
    refute_receive {:batch, _messages}

    send(pid, :check_timeout)
    refute_receive {:batch, _messages}

    messages =
      for i <- 1..5_000 do
        :ok = Pachka.send_message(name, i)
        i
      end

    send(pid, :batch_timeout)
    assert_receive {:batch, ^messages}

    send(pid, :batch_timeout)
    refute_receive {:batch, _messages}

    send(pid, :check_timeout)
    refute_receive {:batch, _messages}
  end

  test "blocks writes on overload", %{name: name, pid: pid} do
    SendHandler.set_blocking?(true)

    for i <- 1..15_000 do
      :ok = Pachka.send_message(name, i)
    end

    send(pid, :check_timeout)
    assert_receive {:batch, _messages}

    for i <- 1..15_000 do
      :ok = Pachka.send_message(name, i)
    end

    send(pid, :check_timeout)
    refute_receive {:batch, _messages}

    for i <- 1..10 do
      assert {:error, :overloaded} = Pachka.send_message(name, i)
    end
  end

  test "kills exporting process on timeout without losing messages", %{name: name, pid: pid} do
    SendHandler.set_blocking?(true)

    batch_1 =
      for i <- 1..500 do
        :ok = Pachka.send_message(name, i)
        i
      end

    send(pid, :check_timeout)
    assert_receive {:batch, ^batch_1}

    batch_2 =
      for i <- 500..1000 do
        :ok = Pachka.send_message(name, i)
        i
      end

    send(pid, :check_timeout)
    refute_receive {:batch, _messages}

    %State{state: %State.Exporting{export_pid: export_pid}} = :sys.get_state(pid)

    monitor_ref = Process.monitor(export_pid)
    send(pid, {:export_timeout, export_pid})
    assert_receive {:DOWN, ^monitor_ref, :process, ^export_pid, :killed}

    SendHandler.set_blocking?(false)

    send(pid, :retry_timeout)
    assert_receive {:batch, ^batch_1}
    send(pid, :check_timeout)
    assert_receive {:batch, ^batch_2}
  end
end
