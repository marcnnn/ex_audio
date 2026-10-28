defmodule ExAudio.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_audio,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: [licenses: ["Apache-2.0"]]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:nx, "~> 1.0"},
      sibling(:nx_fixed),
      sibling(:ex_hdl, path: "../exhdl"),
      {:stream_data, "~> 1.1", only: [:dev, :test]}
    ]
  end

  # A sibling checkout (by default ../<app>) when there is one, otherwise the
  # GitHub repository. Inside deps/ always GitHub, so that every project in a
  # dependency tree picks the same source.
  defp sibling(app, opts \\ []) do
    {path, opts} = Keyword.pop(opts, :path, "../#{app}")
    nested? = Path.basename(Path.dirname(__DIR__)) == "deps"

    if not nested? and File.dir?(Path.expand(path, __DIR__)),
      do: {app, [path: path, override: true] ++ opts},
      else: {app, [github: "marcnnn/#{app}"] ++ opts}
  end
end
