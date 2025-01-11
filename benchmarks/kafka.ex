defmodule Pachka.Benchmarks.Kafka do
  defmodule Sink do
    @behaviour Pachka.Sink

    def send_batch(messages, config) do
      :ok = :brod.produce_sync(:kafka_client, config.topic, config.partition, "", messages)
      :ok
    end
  end

  def run do
    Benchee.run(
      %{
        "single kafka produce" => &run_single/0,
        "manual batch insert" => &run_batch/0,
        "pachka kafka batch" => &run_pachka/0
      },
      before_scenario: fn input ->
        setup_kafka()
        input
      end,
      after_scenario: fn _input -> teardown_kafka() end
    )
  end

  @topic "benchmark_topic"
  @partition 0

  defp setup_kafka do
    {_, 0} =
      System.cmd("docker", [
        "run",
        "-d",
        "--rm",
        "--name",
        "kafka-benchmark",
        "-p",
        "9092:9092",
        "-e",
        "KAFKA_CFG_NODE_ID=0",
        "-e",
        "KAFKA_CFG_PROCESS_ROLES=controller,broker",
        "-e",
        "KAFKA_CFG_LISTENERS=PLAINTEXT://:9092,CONTROLLER://:9093",
        "-e",
        "KAFKA_CFG_ADVERTISED_LISTENERS=PLAINTEXT://localhost:9092",
        "-e",
        "KAFKA_CFG_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT",
        "-e",
        "KAFKA_CFG_CONTROLLER_QUORUM_VOTERS=0@localhost:9093",
        "-e",
        "KAFKA_CFG_CONTROLLER_LISTENER_NAMES=CONTROLLER",
        "bitnami/kafka:latest"
      ])

    # Wait for Kafka to start
    Process.sleep(5000)

    endpoints = [{~c"localhost", 9092}]

    :ok =
      :brod.create_topics(
        endpoints,
        [%{name: @topic, num_partitions: 1, replication_factor: 1, assignments: [], configs: []}],
        %{timeout: 1000}
      )

    :ok = :brod.start_client(endpoints, :kafka_client)

    :ok = :brod.start_producer(:kafka_client, @topic, [])
  end

  defp teardown_kafka do
    :ok = :brod.stop_client(:kafka_client)
    {_, 0} = System.cmd("docker", ["stop", "kafka-benchmark"])
    # Wait for Kafka container to be removed
    Process.sleep(1_000)
    :ok
  end

  @messages 1..10_000
  @batch_size 500

  defp run_single do
    for i <- 1..10_000 do
      :ok = :brod.produce_sync(:kafka_client, @topic, @partition, "#{i}", "Message #{i}")
    end

    :ok
  end

  defp run_batch do
    @messages
    |> Enum.chunk_every(@batch_size)
    |> Enum.each(fn batch ->
      messages = Enum.map(batch, &{"#{&1}", "Message #{&1}"})
      :ok = :brod.produce_sync(:kafka_client, @topic, @partition, "", messages)
    end)
  end

  defp run_pachka do
    {:ok, pid} =
      Pachka.start_link(
        sink: Sink,
        max_batch_size: @batch_size,
        server_value: %{topic: @topic, partition: @partition}
      )

    for i <- 1..10_000 do
      :ok = Pachka.send_message(pid, {"#{i}", "Message #{i}"})
    end

    Pachka.stop(pid)
  end
end
