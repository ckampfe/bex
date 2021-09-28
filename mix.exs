defmodule Bex.MixProject do
  use Mix.Project

  def project do
    [
      app: :bex,
      version: "0.1.0",
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Bex.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bimap, "~> 1.2"},
      {:dialyxir, "~> 1.0", only: [:dev], runtime: false},
      {:httpoison, "~> 1.0"},
      {:mix_test_watch, "~> 1.0", only: :dev, runtime: false}
    ]
  end
end
