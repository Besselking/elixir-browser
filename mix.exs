defmodule Browser.MixProject do
  use Mix.Project

  def project do
    [
      app: :browser,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: [],
      releases: [browser: [include_erts: true, strip_beams: true]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :wx, :inets, :ssl, :public_key],
      mod: {Browser.Application, []}
    ]
  end
end
