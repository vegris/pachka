defmodule Pachka do
  @type message :: term()

  defdelegate send_message(name, message), to: Pachka.Server
end
