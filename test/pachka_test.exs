defmodule PachkaTest do
  use ExUnit.Case

  import Mox

  alias Pachka.State

  alias Test.Support.Sinks
  alias Test.Support.NoopTimer

  setup [:set_mox_global, :verify_on_exit!, :stub_timer, :configure_sink]

  defp stub_timer(_context) do
    stub_with(Pachka.TimerMock, NoopTimer)
    :ok
  end

  defp configure_sink(_context) do
    Sinks.set_receiver_pid(self())

    on_exit(fn -> Sinks.clear() end)
  end

  defp start_server(_context, sink \\ Pachka.SinkMock) do
    name = server_name()
    pid = start_link_supervised!({Pachka, name: name, sink: sink})

    %{name: name, pid: pid}
  end

  defp server_name do
    :"#{Pachka}_#{System.unique_integer()}"
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

  describe "SendSink" do
    setup do
      Mox.stub_with(Pachka.SinkMock, Sinks.SendSink)
      :ok
    end

    setup :start_server

    test "collects and sends batches", %{name: name, pid: pid} do
      for _step <- 1..5 do
        messages = send_messages(name, 300)

        send(pid, :batch_timeout)

        assert_receive {:batch, ^messages}
      end

      for _step <- 1..5 do
        messages = send_messages(name, 500)
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
  end

  describe "BlockSink" do
    setup do
      stub_with(Pachka.SinkMock, Sinks.BlockSink)
      :ok
    end

    setup :start_server

    test "blocks writes on overload and recovers after", %{name: name, pid: pid} do
      first_batch = send_messages(name, 500)
      second_batch = send_messages(name, 10_000)

      for i <- 1..10 do
        assert {:error, :overloaded} = Pachka.send_message(name, i)
      end

      stub_with(Pachka.SinkMock, Sinks.SendSink)

      export_pid = get_export_pid(pid)
      monitor_ref = Process.monitor(export_pid)
      send(pid, {:export_timeout, export_pid})
      assert_receive {:DOWN, ^monitor_ref, :process, ^export_pid, :killed}

      self = self()

      stub(Pachka.TimerMock, :send_after, fn dest, msg, time ->
        if msg == :batch_timeout do
          send(self, :process_recovered)
        end

        NoopTimer.send_after(dest, msg, time)
      end)

      send(pid, :retry_timeout)
      assert_receive {:batch, ^first_batch}
      assert_receive {:batch, ^second_batch}

      assert_receive :process_recovered

      assert :ok = Pachka.send_message(name, :message)
    end

    test "kills exporting process on timeout without losing messages", %{name: name, pid: pid} do
      batch_1 = send_messages(name, 500)
      refute_receive {:batch, _batch_1}

      batch_2 = send_messages(name, 500)
      refute_receive {:batch, _messages}

      export_pid = get_export_pid(pid)
      monitor_ref = Process.monitor(export_pid)
      send(pid, {:export_timeout, export_pid})
      assert_receive {:DOWN, ^monitor_ref, :process, ^export_pid, :killed}

      stub_with(Pachka.SinkMock, Sinks.SendSink)

      send(pid, :retry_timeout)
      assert_receive {:batch, ^batch_1}
      assert_receive {:batch, ^batch_2}
    end
  end

  test "returns export error and calculates new retry timeout with it" do
    %{name: name, pid: pid} = start_server(%{}, Sinks.ErrorSink)

    _batch = send_messages(name, 500)
    assert_receive {:retry, 1}

    for retry_num <- 2..5 do
      send(pid, :retry_timeout)
      assert_receive {:retry, ^retry_num}
    end
  end
end
