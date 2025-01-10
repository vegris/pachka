defmodule Pachka.StateTest do
  use ExUnit.Case, async: true

  require Pachka.State, as: State

  {config, _} = Pachka.Config.parse_options(sink: Pachka.SinkMock)
  @config config

  defp base_state do
    %State{config: @config, state: %State.Idle{batch_timer: nil}}
  end

  describe "is_empty/1" do
    test "returns true when empty" do
      assert State.is_empty(base_state())
    end

    test "returns false when has messages" do
      state = State.add_message(base_state(), :message)

      refute State.is_empty(state)
    end
  end

  describe "is_batch_ready/1" do
    test "returns false when empty" do
      refute State.is_batch_ready(base_state())
    end

    test "returns false when not enough messages" do
      batch_size = @config.max_batch_size
      state = Enum.reduce(1..(batch_size - 1), base_state(), &State.add_message(&2, &1))
      refute State.is_batch_ready(state)
    end

    test "returns true when enough messages" do
      batch_size = @config.max_batch_size
      state = Enum.reduce(1..batch_size, base_state(), &State.add_message(&2, &1))
      assert State.is_batch_ready(state)
    end
  end

  describe "is_full/1" do
    test "returns false when empty" do
      refute State.is_full(base_state())
    end

    test "returns false when not enough messages" do
      queue_size = @config.critical_queue_size
      state = Enum.reduce(1..(queue_size - 1), base_state(), &State.add_message(&2, &1))
      refute State.is_full(state)
    end

    test "returns true when enough messages" do
      queue_size = @config.critical_queue_size
      state = Enum.reduce(1..queue_size, base_state(), &State.add_message(&2, &1))
      assert State.is_full(state)
    end
  end
end
