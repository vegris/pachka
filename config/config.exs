import Config

if Mix.env() == :test do
  config :pachka, Pachka.Timer, implementation: Pachka.TimerMock
end
