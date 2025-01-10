# Taken from https://github.com/wojtekmach/mix_install_examples/blob/main/ecto_sql.exs
defmodule Pachka.Benchmarks.SQLite do
  defmodule Repo do
    use Ecto.Repo, adapter: Ecto.Adapters.SQLite3, otp_app: :pachka
  end

  defmodule Migration do
    use Ecto.Migration

    def change do
      create table("posts") do
        add(:title, :string)
        timestamps(type: :utc_datetime)
      end
    end
  end

  defmodule Post do
    use Ecto.Schema

    schema "posts" do
      field(:title, :string)
      timestamps(type: :utc_datetime_usec)
    end
  end

  defmodule Sink do
    alias Pachka.Benchmarks.SQLite.Post
    alias Pachka.Benchmarks.SQLite.Repo

    @behaviour Pachka.Sink

    def send_batch(messages, _server_value) do
      posts =
        Enum.map(messages, fn title ->
          %{title: title, inserted_at: {:placeholder, :now}, updated_at: {:placeholder, :now}}
        end)

      _ = Repo.insert_all(Post, posts, placeholders: %{now: DateTime.utc_now()})

      :ok
    end
  end

  def run do
    Benchee.run(
      %{
        "single insert" => &run_single/0,
        "manual batch insert" => &run_batch/0,
        "pachka batch insert" => &run_pachka/0
      },
      before_scenario: fn input ->
        setup_db()
        input
      end,
      after_scenario: fn _input -> teardown_db() end
    )
  end

  defp setup_db do
    :ok = Repo.__adapter__().storage_up(Repo.config())
    {:ok, _} = Repo.start_link()
    _ = Ecto.Migrator.run(Repo, [{0, Migration}], :up, all: true)

    :ok
  end

  defp teardown_db do
    Repo.stop()
    _ = Repo.__adapter__().storage_down(Repo.config())

    :ok
  end

  @messages 1..10_000
  @batch_size 500

  defp run_single do
    for i <- @messages do
      Repo.insert!(%Post{title: "Post #{i}"})
    end

    :ok
  end

  defp run_batch do
    @messages
    |> Enum.chunk_every(@batch_size)
    |> Enum.each(fn batch ->
      posts =
        Enum.map(batch, fn title ->
          %{
            title: "Post #{title}",
            inserted_at: {:placeholder, :now},
            updated_at: {:placeholder, :now}
          }
        end)

      _ = Repo.insert_all(Post, posts, placeholders: %{now: DateTime.utc_now()})
      :ok
    end)
  end

  defp run_pachka do
    {:ok, pid} = Pachka.start_link(sink: Sink, max_batch_size: @batch_size)

    for i <- @messages do
      :ok = Pachka.send_message(pid, "Post #{i}")
    end

    Pachka.stop(pid)
  end
end
