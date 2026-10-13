defmodule KilnCloudflareImages.BackendTest do
  @moduledoc """
  The backend's URL grammar against Cloudflare's: delivery URLs, flexible-variant
  options for every spec shape Kiln plans, and recognising its own URLs for
  adoption.
  """
  # async: false — settings live in the global app env.
  use ExUnit.Case, async: false

  alias KilnCloudflareImages.Backend

  @settings [account_id: "acc123", api_token: "token", account_hash: "HASH"]

  setup do
    Application.put_env(:kiln_cms, KilnCloudflareImages, @settings)
    on_exit(fn -> Application.delete_env(:kiln_cms, KilnCloudflareImages) end)
  end

  defp settings(extra),
    do: Application.put_env(:kiln_cms, KilnCloudflareImages, Keyword.merge(@settings, extra))

  defp spec(overrides) do
    Map.merge(
      %{source: {1200, 800}, crop: nil, width: 400, height: 267, format: :webp, quality: 82},
      Map.new(overrides)
    )
  end

  test "is a Kiln image backend with a stable name" do
    assert Kiln.ImageBackend.Registry.backend?(Backend)
    assert Backend.name() == "cloudflare_images"
  end

  # What `mix kiln.plugins.doctor` checks once a deployment lists the plugin —
  # the test env's plugin list is Kiln's own fixture, so it's asked directly.
  test "passes the plugin doctor's image-backend checks, selected" do
    assert Mix.Tasks.Kiln.Plugins.Doctor.image_backend_problems(
             [KilnCloudflareImages.Plugin],
             Backend
           ) == []
  end

  describe "configured?/0" do
    test "needs the account, the token and the hash" do
      assert Backend.configured?()

      for missing <- [:account_id, :api_token, :account_hash] do
        Application.put_env(:kiln_cms, KilnCloudflareImages, Keyword.delete(@settings, missing))
        refute Backend.configured?(), "configured without #{missing}"
      end
    end
  end

  describe "accepts?/1" do
    test "the raster types Cloudflare takes, up to its 10 MB ceiling" do
      for type <- ~w(image/jpeg image/png image/gif image/webp) do
        assert Backend.accepts?(%{content_type: type, byte_size: 1_000})
      end

      refute Backend.accepts?(%{content_type: "image/jpeg", byte_size: 10 * 1024 * 1024 + 1})
      refute Backend.accepts?(%{content_type: "image/avif", byte_size: 1_000})
      refute Backend.accepts?(%{content_type: "application/pdf", byte_size: 1_000})
    end
  end

  describe "url/1" do
    test "the named variant under the account hash" do
      assert Backend.url("abc.png") == "https://imagedelivery.net/HASH/abc.png/public"

      settings(variant: "full", delivery_base: "https://example.com/cdn-cgi/imagedelivery/HASH/")

      assert Backend.url("abc.png") ==
               "https://example.com/cdn-cgi/imagedelivery/HASH/abc.png/full"
    end

    test "an adopted ID keeps its subpaths and escapes what would break the path" do
      assert Backend.url("blog/hero.jpg") == "https://imagedelivery.net/HASH/blog/hero.jpg/public"

      assert Backend.url("a b?c#d%e") ==
               "https://imagedelivery.net/HASH/a%20b%3Fc%23d%25e/public"
    end
  end

  describe "render_url/2" do
    test "a responsive size: scale down, never enlarge" do
      assert {:ok, url} = Backend.render_url("abc.png", spec([]))

      assert url ==
               "https://imagedelivery.net/HASH/abc.png/" <>
                 "w=400,h=267,fit=scale-down,q=82,f=webp,metadata=none"
    end

    test "a crop window trims top;right;bottom;left in source pixels, then covers" do
      # The card crop of a 1200x800 source around a focal point.
      assert {:ok, url} =
               Backend.render_url(
                 "abc.png",
                 spec(crop: {100, 50, 800, 450}, width: 800, height: 450, format: :jpg)
               )

      assert url =~ "/abc.png/trim=50;300;300;100,w=800,h=450,fit=cover,q=82,f=jpeg,"
    end

    test "PNG and GIF keep the source format; lossless has no quality" do
      assert {:ok, url} = Backend.render_url("abc.png", spec(format: :png, quality: nil))
      assert url =~ "/abc.png/w=400,h=267,fit=scale-down,metadata=none"
      refute url =~ "f="
    end

    test "is unsupported without flexible variants, so Kiln encodes" do
      settings(flexible_variants: false)
      assert Backend.render_url("abc.png", spec([])) == :unsupported
    end
  end

  describe "key_for_url/1" do
    test "recognises its own delivery URLs, with or without a variant" do
      assert Backend.key_for_url("https://imagedelivery.net/HASH/abc-123/public") ==
               {:ok, "abc-123"}

      assert Backend.key_for_url("https://imagedelivery.net/HASH/abc-123/w=400") ==
               {:ok, "abc-123"}

      # What Directus's offload stored, which Cloudflare refuses to serve.
      assert Backend.key_for_url("https://imagedelivery.net/HASH/abc-123") == {:ok, "abc-123"}

      assert Backend.key_for_url("https://imagedelivery.net/HASH/abc-123/public?x=1") ==
               {:ok, "abc-123"}
    end

    test "an ID with subpaths is everything before the variant" do
      assert Backend.key_for_url("https://imagedelivery.net/HASH/blog/2024/hero.jpg/public") ==
               {:ok, "blog/2024/hero.jpg"}
    end

    test "round-trips the URLs it builds" do
      for key <- ["abc.png", "blog/hero.jpg", "a b?c#d%e"] do
        assert Backend.key_for_url(Backend.url(key)) == {:ok, key}
        assert {:ok, url} = Backend.render_url(key, spec([]))
        assert Backend.key_for_url(url) == {:ok, key}
      end
    end

    test "still recognises imagedelivery.net URLs after a switch to a custom domain" do
      settings(delivery_base: "https://example.com/cdn-cgi/imagedelivery/HASH")

      assert Backend.key_for_url("https://imagedelivery.net/HASH/abc-123/public") ==
               {:ok, "abc-123"}

      custom = "https://example.com/cdn-cgi/imagedelivery/HASH/abc-123/public"
      assert Backend.key_for_url(custom) == {:ok, "abc-123"}

      assert Backend.key_for_url("https://imagedelivery.net/OTHER/abc-123/public") == :error
    end

    test "a malformed escape is not ours, rather than an error" do
      assert Backend.key_for_url("https://imagedelivery.net/HASH/abc%zz/public") == :error
      assert Backend.key_for_url("https://imagedelivery.net/HASH/abc%2") == :error
    end

    test "another account's, another host's, or a malformed URL is not ours" do
      assert Backend.key_for_url("https://imagedelivery.net/OTHER/abc-123/public") == :error
      assert Backend.key_for_url("https://cdn.example.com/HASH/abc-123/public") == :error
      assert Backend.key_for_url("https://imagedelivery.net/HASH/") == :error
      assert Backend.key_for_url(nil) == :error
    end

    test "recognises nothing while unconfigured" do
      Application.put_env(:kiln_cms, KilnCloudflareImages, Keyword.delete(@settings, :api_token))
      assert Backend.key_for_url("https://imagedelivery.net/HASH/abc-123/public") == :error
    end
  end

  test "csp_hosts/0 is the delivery origin" do
    assert Backend.csp_hosts() == ["https://imagedelivery.net"]

    settings(delivery_base: "https://img.example.com:8443/cdn-cgi/imagedelivery/HASH")
    assert Backend.csp_hosts() == ["https://img.example.com:8443"]
  end
end
