defmodule Pachka do
  @type message :: term()

  defdelegate send_message(name, message), to: Pachka.Server.Tables, as: :write_message
end
