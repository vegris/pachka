defmodule Pachka do
  @type message :: term()

  defdelegate send_message(message), to: Pachka.Server
end
