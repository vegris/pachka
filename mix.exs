defmodule Pachka.MixProject do
  use Mix.Project

  def project do
    [
      app: :pachka,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      dialyzer: [
        flags: ~w[error_handling extra_return missing_return underspecs unmatched_returns]a
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(:bench), do: ["lib", "benchmarks"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:nimble_options, "~> 1.1"},
      {:dialyxir, "~> 1.4", only: [:dev, :test, :bench], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test, :bench], runtime: false},
      {:mox, "~> 1.1", only: :test},
      {:ecto_sql, "~> 3.12", only: :bench},
      {:ecto_sqlite3, "~> 0.18", only: :bench}
    ]
  end

  defp aliases do
    [
      check: ["format --check-formatted", "credo", "dialyzer"]
    ]
  end
end
