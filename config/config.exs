import Config

if Mix.env() == :test do
  config :pachka, Pachka.Timer, implementation: Pachka.TimerMock
  config :logger, level: :none
end

if Mix.env() == :bench do
  config :logger, level: :info

  config :pachka, Pachka.Benchmarks.SQLite.Repo,
    database: ":memory:",
    pool_size: 1,
    log: false
end
