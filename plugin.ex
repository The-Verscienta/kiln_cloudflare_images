defmodule KilnCloudflareImages.Plugin do
  @moduledoc """
  Contributes `KilnCloudflareImages.Backend` (kiln_cms#1955). Installing the
  plugin changes nothing on its own: select the backend with

      config :kiln_cms, :image_backend, KilnCloudflareImages.Backend

  and give it its settings (`KilnCloudflareImages.Config`).
  """
  use Kiln.Plugin

  @impl true
  def name, do: "cloudflare_images"

  @impl true
  def version, do: "0.1.0"

  @impl true
  def summary, do: "Stores new image uploads in Cloudflare Images and serves their sizes from it."

  @impl true
  def homepage, do: "https://github.com/The-Verscienta/kiln_cloudflare_images"

  @impl true
  def image_backends, do: [KilnCloudflareImages.Backend]
end
