defmodule Browser.MixProject do
  use Mix.Project

  def project do
    [
      app: :browser,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: [],
      releases: [browser: [include_erts: false, strip_beams: false]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :wx, :inets, :ssl, :public_key],
      mod: {Browser.Application, []}
    ]
  end
end
