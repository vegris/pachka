defmodule Pachka.Timer do
  @callback send_after(pid() | atom(), term(), non_neg_integer()) :: reference()
  @callback cancel_timer(reference()) :: non_neg_integer() | false | :ok

  @implementation Application.compile_env(:pachka, [__MODULE__, :implementation], __MODULE__.Real)

  def implementation, do: @implementation
end

defmodule Pachka.Timer.Real do
  @behaviour Pachka.Timer

  defdelegate send_after(dest, msg, time), to: Process
  defdelegate cancel_timer(timer_ref), to: Process
end
