defmodule Pachka.Sink do
  @moduledoc """
  Behaviour module for implementing message sinks in Pachka.

  A sink is responsible for processing batches of messages collected by Pachka.
  It defines how messages should be delivered to their destination and handles retry logic when delivery fails.

  ## Example

      defmodule MySink do
        @behaviour Pachka.Sink

        @impl true
        def send_batch(messages, _server_value) do
          # Process the batch of messages
          :ok
        end

        @impl true
        def retry_timeout(retry_num, _failure_reason, _server_value) do
          # Exponential backoff
          :timer.seconds(retry_num * 2)
        end
      end
  """

  @typedoc """
  Custom value that is passed to all sink callbacks.

  Can be used to distinguish between different Pachka processes using the same sink module or to store server-specific configuration.
  Configured in `Pachka.start_link/1`.
  """
  @type server_value :: term()

  @typedoc """
  Error returned by `send_batch/2` when message delivery fails.
  """
  @type send_error :: term()

  @typedoc """
  Reason for message delivery failure.

  Can be either a custom error from `send_batch/2` or `:killed` when
  the export process is terminated due to timeout.
  """
  @type failure_reason :: send_error() | :killed

  @doc """
  Processes a batch of messages.

  This callback is called when Pachka has collected enough messages to form a batch
  or when the batch timeout is reached. The implementation should deliver these messages to their destination.

  ## Parameters

    * `messages` - List of messages to be processed
    * `server_value` - Custom value configured when starting Pachka

  ## Returns

    * `:ok` - if messages were successfully processed
    * `{:error, reason}` - if processing failed
  """
  @callback send_batch(messages :: [Pachka.message()], server_value :: server_value()) ::
              :ok | {:error, send_error()}

  @doc """
  Determines the timeout before retrying a failed batch.

  Called when `send_batch/2` returns an error or when the export process is killed
  due to timeout. The implementation can use the retry attempt number and failure
  reason to implement custom backoff strategies.

  ## Parameters

    * `retry_num` - Number of retry attempts made so far (starts from 1)
    * `failure_reason` - Reason why the previous attempt failed
    * `server_value` - Custom value configured when starting Pachka

  ## Returns

  Timeout in milliseconds before the next retry attempt.

  > #### Optional callback {: .info}
  >
  > Default implementation will wait for a number of seconds equal to retry number
  """
  @callback retry_timeout(
              retry_num :: pos_integer(),
              failure_reason :: failure_reason(),
              server_value :: server_value()
            ) :: timeout()

  @doc """
  Handles remaining messages during Pachka server termination.

  Called when the Pachka server is stopping and there are still messages
  in the queue. The implementation can choose how to handle these messages
  to prevent data loss.

  ## Parameters

    * `messages` - List of remaining messages
    * `batch_size` - Maximum batch size configured for the server
    * `server_value` - Custom value configured when starting Pachka

  > #### Optional callback {: .info}
  >
  > If one is not implemented, Pachka will process remaining messages normally
  """
  @callback drain_on_terminate(
              messages :: [Pachka.message()],
              batch_size :: pos_integer(),
              server_value :: server_value()
            ) :: :ok

  @optional_callbacks retry_timeout: 3, drain_on_terminate: 3
end
