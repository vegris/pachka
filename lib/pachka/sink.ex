defmodule Pachka.Sink do
  @type failure_reason :: term()

  @callback send_batch(messages :: [Pachka.message()]) :: :ok | {:error, failure_reason()}
  @callback retry_timeout(
              retry_num :: pos_integer(),
              failure_reason :: :killed | failure_reason()
            ) :: timeout()

  @optional_callbacks retry_timeout: 2
end
