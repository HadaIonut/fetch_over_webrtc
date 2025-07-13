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

  def application do
    [
      mod: {Server, []},
      extra_applications: [:logger, :wx, :runtime_tools, :observer]
    ]
  end

  defp deps do
    [
      {:websockex, "~> 0.4.3"},
      {:uuid, "~> 1.1"},
      {:ex_webrtc, "~> 0.14.0"},
      {:ex_sctp, "~> 0.1.0"},
      {:typed_struct, "~> 0.1.4"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:priority_queue, "~> 1.1"},
      {:multipart, "~> 0.4.0"},
      {:req, "~> 0.5.0"}
    ]
  end
end
