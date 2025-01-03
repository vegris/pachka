defmodule Pachka.Sink do
  @type send_error :: term()
  @type failure_reason :: send_error() | :killed

  @callback send_batch(messages :: [Pachka.message()], server_value :: term()) ::
              :ok | {:error, send_error()}

  @callback retry_timeout(
              retry_num :: pos_integer(),
              failure_reason :: failure_reason()
            ) :: timeout()

  @optional_callbacks retry_timeout: 2
end
