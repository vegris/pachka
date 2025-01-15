# Pachka

[![Hex.pm Version](https://img.shields.io/hexpm/v/pachka)](https://hex.pm/packages/pachka)
[![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/pachka/)
[![CI](https://github.com/vegris/pachka/actions/workflows/ci.yml/badge.svg)](https://github.com/vegris/pachka/actions/workflows/ci.yml)
[![Coverage Status](https://coveralls.io/repos/github/vegris/pachka/badge.svg?branch=main)](https://coveralls.io/github/vegris/pachka?branch=main)

Pachka is a message batching library for Elixir.

It provides a reliable way to collect messages and deliver them in batches to configurable destinations.
Messages are buffered until either the batch size limit is reached or the batch timeout occurs.
Failed deliveries are automatically retried with configurable backoff strategies.

## Features

* Configurable batch sizes and timeouts
* Customizable message sinks for different delivery targets
* Automatic retries with customizable backoff
* Overload protection with queue size limits
* Graceful shutdown with message draining

## Installation

```elixir
def deps do
  [
    {:pachka, "~> 1.0.0"}
  ]
end
```

## Usage

1. Define a sink module that implements the `Pachka.Sink` behavior:

```elixir
defmodule MyApp.MessageSink do
  @behaviour Pachka.Sink
  
  @impl true
  def send_batch(messages, _server_value) do
    # Process messages in batch
    :ok
  end
end
```

2. Start Pachka server:

```elixir
{:ok, pid} = Pachka.start_link(
  name: MyPachka,
  sink: MyApp.MessageSink,
  max_batch_size: 100,
  max_batch_delay: :timer.seconds(1)
)
```

3. Send messages:

```elixir
:ok = Pachka.send_message(MyPachka, %{event: "user_login"})
:ok = Pachka.send_message(MyPachka, %{event: "page_view"})
```

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for details.
