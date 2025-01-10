defmodule Pachka.TimerTest do
  use ExUnit.Case, async: true

  alias Pachka.Timer.Real, as: RealTimer

  describe "implementation/0" do
    test "returns TimerMock in tests" do
      assert Pachka.Timer.implementation() == Pachka.TimerMock
    end
  end

  describe "Pachka.Timer.Real" do
    test "timer sends a message to the process" do
      RealTimer.send_after(self(), :message, 0)
      assert_receive :message
    end

    test "timer is configured with correct time" do
      timer = RealTimer.send_after(self(), :message, 1_000)
      assert_in_delta Process.cancel_timer(timer), 1_000, 100
    end

    test "cancel_timer/1 cancels timer" do
      timer = RealTimer.send_after(self(), :message, 1_000)
      assert_in_delta RealTimer.cancel_timer(timer), 1_000, 100
      refute Process.read_timer(timer)
    end
  end
end
