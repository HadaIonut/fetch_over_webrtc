defmodule ServerProxy.MixProject do
  use Mix.Project

  def project do
    [
      app: :server_proxy,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
      {:websockex, "~> 0.4.3"},
      {:uuid, "~> 1.1"},
      {:ex_webrtc, "~> 0.7.0"},
      {:ex_sctp, "~> 0.1.0"},
      {:typed_struct, "~> 0.1.4"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:priority_queue, "~> 1.1"}
    ]
  end
end
