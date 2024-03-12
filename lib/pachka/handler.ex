defmodule Pachka.Handler do
  @callback send_batch([Pachka.message()]) :: :ok
end
