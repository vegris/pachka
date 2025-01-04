defmodule Pachka.Sink do
  @type server_value :: term()

  @type send_error :: term()
  @type failure_reason :: send_error() | :killed

  @callback send_batch(messages :: [Pachka.message()], server_value :: server_value()) ::
              :ok | {:error, send_error()}

  @callback retry_timeout(
              retry_num :: pos_integer(),
              failure_reason :: failure_reason(),
              server_value :: server_value()
            ) :: timeout()

  @optional_callbacks retry_timeout: 3
end
