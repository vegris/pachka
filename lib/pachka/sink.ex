defmodule Pachka.Sink do
  @callback send_batch([Pachka.message()]) :: :ok
end
