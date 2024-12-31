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

    def send_batch(messages) do
      posts =
        Enum.map(messages, fn title ->
          %{title: title, inserted_at: {:placeholder, :now}, updated_at: {:placeholder, :now}}
        end)

      Repo.insert_all(Post, posts, placeholders: %{now: DateTime.utc_now()})

      :ok
    end
  end

  def run do
    with_setup(&run_single/0)
    with_setup(&run_pachka/0)
  end

  defp with_setup(fun) do
    config = Repo.config()

    :ok = Repo.__adapter__().storage_up(config)
    {:ok, _} = Repo.start_link()

    Ecto.Migrator.run(Repo, [{0, Migration}], :up, all: true)

    fun.()

    Repo.stop()
    Repo.__adapter__().storage_down(config)
  end

  defp run_single do
    :timer.tc(fn ->
      for i <- 1..10_000 do
        Repo.insert!(%Post{title: "Post #{i}"})
      end

      :ok
    end)
    |> dbg()
  end

  defp run_pachka do
    {:ok, _pid} = Pachka.Server.start_link(name: Pachka, sink: Sink)

    :timer.tc(fn ->
      for i <- 1..10_000 do
        Pachka.send_message(Pachka, "Post #{i}")
      end

      Pachka.Server.stop(Pachka)
    end)
    |> dbg()
  end
end
