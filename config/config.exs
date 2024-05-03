import Config

if Mix.env() == :test do
  config :pachka, Pachka.Timer, implementation: Pachka.TimerMock
  config :logger, level: :none
end
