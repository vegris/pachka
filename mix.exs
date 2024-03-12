defmodule Pachka.MixProject do
  use Mix.Project

  def project do
    [
      app: :pachka,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      compilers: compilers(),
      deps: deps(),
      aliases: aliases(),
      dialyzer: [
        flags: ~w[error_handling extra_return missing_return underspecs unmatched_returns]a
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp compilers do
    if Mix.env() == :dev do
      [:leex, :yecc] ++ Mix.compilers()
    else
      Mix.compilers()
    end
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      check: ["format --check-formatted", "credo", "dialyzer"]
    ]
  end
end
