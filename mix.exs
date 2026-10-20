defmodule Browser.MixProject do
  use Mix.Project

  def project do
    [
      app: :browser,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: [],
      # The corpus files and the runner of the JS oracles are loaded by the tests that use
      # them.
      test_ignore_filters: [
        &String.ends_with?(&1, "_corpus.ex"),
        &String.ends_with?(&1, "_oracle.ex")
      ],
      releases: [browser: [include_erts: true, strip_beams: true]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :wx, :inets, :ssl, :public_key, :crypto],
      mod: {Browser.Application, []}
    ]
  end
end
