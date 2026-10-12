defmodule KilnCloudflareImages.Backend do
  @moduledoc """
  Cloudflare Images as a Kiln image backend (`Kiln.ImageBackend`, kiln_cms#1955).

  Kiln's storage key becomes the image's **custom ID**, so the image Kiln
  stores as `5f0c…e1.png` is `https://imagedelivery.net/<hash>/5f0c…e1.png/public`.
  Variants and on-the-fly transforms are **flexible variants**: the options
  go in the URL where the variant name would be, e.g.
  `…/5f0c…e1.png/w=400,h=267,fit=scale-down,q=82,f=webp,metadata=none`.

  Settings: `KilnCloudflareImages.Config`.
  """
  use Kiln.ImageBackend

  alias KilnCloudflareImages.{Client, Config}

  # What the Images API accepts and Kiln ingests (Kiln never stores SVG).
  @types ~w(image/jpeg image/png image/gif image/webp)

  # The Images API's per-file ceiling.
  @max_bytes 10 * 1024 * 1024

  @impl true
  def name, do: "cloudflare_images"

  @impl true
  def configured?, do: Config.complete?()

  @impl true
  def accepts?(%{content_type: type, byte_size: size}),
    do: type in @types and is_integer(size) and size <= @max_bytes

  def accepts?(_candidate), do: false

  @impl true
  def store(key, path), do: Client.upload(key, path)

  @impl true
  def fetch(key), do: Client.fetch(key)

  @impl true
  def delete(key), do: Client.delete(key)

  @impl true
  def url(key), do: "#{Config.delivery_base()}/#{segment(key)}/#{Config.variant()}"

  @impl true
  def render_url(key, spec) do
    if Config.flexible_variants?() do
      {:ok, "#{Config.delivery_base()}/#{segment(key)}/#{options(spec)}"}
    else
      :unsupported
    end
  end

  @impl true
  def csp_hosts do
    case URI.parse(Config.delivery_base()) do
      %URI{scheme: scheme, host: host, port: port} when is_binary(host) ->
        [origin(scheme, host, port)]

      _ ->
        []
    end
  end

  @doc """
  The custom ID a delivery URL names, for adopting imported rows. Accepts the
  variant form (`…/<hash>/<id>/<variant or options>`) and the bare two-segment
  form an import may have stored (`…/<hash>/<id>`, which Cloudflare itself
  refuses to serve). Any other host or account hash is not ours.
  """
  @impl true
  def key_for_url(url) when is_binary(url) do
    prefix = Config.delivery_base() <> "/"

    with true <- Config.complete?(),
         true <- String.starts_with?(url, prefix),
         rest = url |> String.replace_prefix(prefix, "") |> strip_query(),
         {:ok, id} <- id_segment(String.split(rest, "/", trim: true)) do
      {:ok, URI.decode(id)}
    else
      _ -> :error
    end
  end

  def key_for_url(_url), do: :error

  defp id_segment([id]), do: {:ok, id}
  defp id_segment([id, _variant]), do: {:ok, id}
  defp id_segment(_segments), do: :error

  defp strip_query(path), do: path |> String.split(["?", "#"], parts: 2) |> hd()

  # Flexible-variant options, in Cloudflare's order of operations: trim (the
  # crop window, in source pixels) runs before the resize.
  defp options(spec) do
    [
      trim(spec),
      "w=#{spec.width}",
      "h=#{spec.height}",
      # A crop window already has the output's aspect ratio, so `cover` lands
      # exactly on the size; without one the size keeps the source's, and
      # `scale-down` never enlarges.
      if(spec.crop, do: "fit=cover", else: "fit=scale-down"),
      spec.quality && "q=#{spec.quality}",
      format(spec.format),
      # Kiln strips metadata on everything it writes (#215); so does this.
      "metadata=none"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(",")
  end

  defp trim(%{crop: nil}), do: nil

  defp trim(%{crop: {left, top, width, height}, source: {source_w, source_h}}) do
    right = max(source_w - left - width, 0)
    bottom = max(source_h - top - height, 0)

    if {top, right, bottom, left} == {0, 0, 0, 0},
      do: nil,
      else: "trim=#{top};#{right};#{bottom};#{left}"
  end

  # Cloudflare has no PNG or GIF output: leaving `f` off keeps the source's
  # format, which is what Kiln asks for when it asks for either.
  defp format(:jpg), do: "f=jpeg"
  defp format(:webp), do: "f=webp"
  defp format(:avif), do: "f=avif"
  defp format(_png_or_gif), do: nil

  # Cloudflare requires `%` in a custom ID to be sent as `%25`; Kiln's keys are
  # plain, an adopted ID may not be.
  defp segment(key), do: URI.encode(key, &(&1 != ?% and URI.char_unescaped?(&1)))

  defp origin(scheme, host, port) when {scheme, port} in [{"https", 443}, {"http", 80}],
    do: "#{scheme}://#{host}"

  defp origin(scheme, host, port), do: "#{scheme}://#{host}:#{port}"
end
