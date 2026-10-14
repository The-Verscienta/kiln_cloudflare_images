defmodule KilnCloudflareImages.MixProject do
  use Mix.Project

  # Keep in step with `KilnCloudflareImages.Plugin.version/0`.
  @version "0.1.0"
  @source_url "https://github.com/The-Verscienta/kiln_cloudflare_images"

  def project do
    [
      app: :kiln_cloudflare_images,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Cloudflare Images as a KilnCMS image backend.",
      source_url: @source_url,
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => @source_url},
        files: ~w(lib mix.exs .formatter.exs README.md LICENSE)
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # kiln_plugin is the whole contract with Kiln (kiln_cms#1909): it carries
  # `Kiln.Plugin` and `Kiln.ImageBackend`, so this compiles without the core.
  # Inside a KilnCMS build the core bundles its own copy, and
  # `mix kiln.plugins.doctor` checks this requirement accepts it. Req is the
  # Images API client; the core uses it too, so the two converge.
  defp deps do
    [
      # 1.2: `Kiln.ImageBackend.check/0`.
      {:kiln_plugin, "~> 1.2"},
      {:req, "~> 0.5"},
      # Req.Test's stubs are Plug conns.
      {:plug, "~> 1.16", only: :test}
    ]
  end
end
