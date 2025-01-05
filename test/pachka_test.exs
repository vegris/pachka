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
    pid = start_link_supervised!({Pachka, sink: sink})

    %{pid: pid}
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

    test "collects and sends batches", %{pid: pid} do
      for _step <- 1..5 do
        messages = send_messages(pid, 300)

        send(pid, :batch_timeout)

        assert_receive {:batch, ^messages}
      end

      for _step <- 1..5 do
        messages = send_messages(pid, 500)
        assert_receive {:batch, ^messages}
      end
    end

    test "does not start export when table is empty", %{pid: pid} do
      send(pid, :batch_timeout)
      refute_receive {:batch, _messages}

      messages = send_messages(pid, 500)

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

    test "blocks writes on overload and recovers after", %{pid: pid} do
      first_batch = send_messages(pid, 500)
      other_messages = send_messages(pid, 10_000)

      for i <- 1..10 do
        assert {:error, :overloaded} = Pachka.send_message(pid, i)
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

      for batch <- Enum.chunk_every(other_messages, 500) do
        assert_receive {:batch, ^batch}
      end

      assert_receive :process_recovered

      batch = send_messages(pid, 500)
      assert_receive {:batch, ^batch}
    end

    test "kills exporting process on timeout without losing messages", %{pid: pid} do
      batch_1 = send_messages(pid, 500)
      refute_receive {:batch, _batch_1}

      batch_2 = send_messages(pid, 500)
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
    pid = start_link_supervised!({Pachka, sink: Sinks.ErrorSink})

    _batch = send_messages(pid, 500)
    assert_receive {:retry, 1}

    for retry_num <- 2..5 do
      send(pid, :retry_timeout)
      assert_receive {:retry, ^retry_num}
    end
  end

  test "passes server value to send_batch function" do
    test_pid = self()

    stub(Pachka.SinkMock, :send_batch, fn messages, server_value ->
      send(test_pid, {:batch, messages, server_value})
      :ok
    end)

    server_value = make_ref()

    pid = start_link_supervised!({Pachka, sink: Pachka.SinkMock, server_value: server_value})

    # Passes server_value on regular export
    batch = send_messages(pid, 500)
    assert_receive {:batch, ^batch, ^server_value}

    # Passes server_value on terminate
    batch = send_messages(pid, 5)
    Pachka.stop(pid)
    assert_receive {:batch, ^batch, ^server_value}
  end

  test "passes server value to retry_timeout function" do
    test_pid = self()

    Pachka.SinkFullMock
    |> stub(:send_batch, fn _messages, _server_value -> {:error, :failed} end)
    |> stub(:retry_timeout, fn retry_num, _failure_reason, server_value ->
      send(test_pid, {:retry, server_value})
      retry_num
    end)

    server_value = make_ref()

    pid = start_link_supervised!({Pachka, sink: Pachka.SinkFullMock, server_value: server_value})

    _batch = send_messages(pid, 500)
    assert_receive {:retry, ^server_value}
  end

  describe "config" do
    @valid_config [
      sink: Pachka.SinkMock
    ]

    @valid_config_full [
      name: Pachka,
      sink: Pachka.SinkMock,
      server_value: :term,
      start_link_opts: [],
      max_batch_size: 500,
      critical_batch_size: 10_000,
      max_batch_delay: :timer.seconds(5),
      export_timeout: :timer.seconds(10)
    ]

    test "starts with valid config" do
      pid = start_link_supervised!({Pachka, @valid_config})
      assert Process.alive?(pid)
    end

    test "starts with full valid config" do
      pid = start_link_supervised!({Pachka, @valid_config_full})
      assert Process.alive?(pid)
    end

    test "raise without sink" do
      config = Keyword.delete(@valid_config, :sink)

      assert_raise RuntimeError, ~r/required :sink option not found/, fn ->
        start_link_supervised!({Pachka, config})
      end
    end

    test "raise on unknown key" do
      config = Keyword.put(@valid_config, :unknown, :value)

      assert_raise RuntimeError, ~r/unknown options \[:unknown\]/, fn ->
        start_link_supervised!({Pachka, config})
      end
    end

    test "is accessible via name" do
      name = :pachka
      message = "message"
      _pid = start_link_supervised!({Pachka, sink: Sinks.SendSink, name: name})

      :ok = Pachka.send_message(name, message)
      Pachka.stop(name)

      assert_receive {:batch, [^message]}
    end

    parameters = [
      {"raise on invalid sink", :sink, 1, "atom"},
      {"raise on max_batch_size == 0", :max_batch_size, 0, "positive integer"},
      {"raise on max_batch_size < 0", :max_batch_size, -500, "positive integer"},
      {"raise on critical_batch_size == 0", :critical_batch_size, 0, "positive integer"},
      {"raise on critical_batch_size < 0", :critical_batch_size, -500, "positive integer"},
      {"raise on max_batch_delay < 0", :max_batch_delay, -500,
       "non-negative integer or :infinity"},
      {"raise on export_timeout < 0", :export_timeout, -500, "non-negative integer or :infinity"}
    ]

    for {name, key, value, expected} <- parameters do
      test name do
        config = Keyword.put(@valid_config, unquote(key), unquote(value))

        error =
          "invalid value for :#{unquote(key)} option: expected #{unquote(expected)}, got: #{unquote(value)}"

        assert_raise RuntimeError, Regex.compile!(error), fn ->
          start_link_supervised!({Pachka, config})
        end
      end
    end
  end
end
