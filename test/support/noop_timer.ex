defmodule Test.Support.NoopTimer do
  @behaviour Pachka.Timer

  def send_after(_pid, _msg, _time), do: make_ref()
  def cancel_timer(_timer_ref), do: :ok
end
