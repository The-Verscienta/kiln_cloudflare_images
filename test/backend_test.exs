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

  describe "check/0" do
    setup do
      settings(req_options: [plug: {Req.Test, KilnCloudflareImages.Client}, retry: false])
    end

    # Stats and the image list, answered separately.
    defp stub_api(stats_status, list_status) do
      Req.Test.stub(KilnCloudflareImages.Client, fn conn ->
        case conn.request_path do
          "/client/v4/accounts/acc123/images/v1/stats" ->
            conn
            |> Plug.Conn.put_status(stats_status)
            |> Req.Test.json(%{
              "success" => stats_status == 200,
              "result" => %{"count" => %{"current" => 1204, "allowed" => 100_000}}
            })

          "/client/v4/accounts/acc123/images/v1" ->
            assert conn.query_string == "per_page=10"

            conn
            |> Plug.Conn.put_status(list_status)
            |> Req.Test.json(%{"success" => list_status == 200, "result" => %{"images" => []}})
        end
      end)
    end

    test "reports the account's usage when the token works" do
      stub_api(200, 200)

      assert Backend.check() ==
               {:ok, [{"Stored images", "1,204 of 100,000"}, {"Account", "acc123"}]}
    end

    test "fails a token that reads the usage but not the images" do
      # A permission policy scoped to domains: stats answer, images don't.
      stub_api(200, 403)

      assert {:error, message} = Backend.check()
      assert message =~ "refused its images (403)"
      assert message =~ "on the account itself"
    end

    test "passes on a rate limit as one" do
      Req.Test.stub(KilnCloudflareImages.Client, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "30")
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"success" => false})
      end)

      assert {:error, message} = Backend.check()
      assert message =~ "try again in 30 s"
    end

    test "names the setting to fix when Cloudflare refuses the token, never the token" do
      settings(
        api_token: "tok-secret-123",
        req_options: [plug: {Req.Test, KilnCloudflareImages.Client}, retry: false]
      )

      Req.Test.stub(KilnCloudflareImages.Client, &Plug.Conn.send_resp(&1, 403, ""))

      assert {:error, message} = Backend.check()
      assert message =~ "CLOUDFLARE_IMAGES_TOKEN"
      refute message =~ "tok-secret-123"
    end

    test "names the account setting when Cloudflare doesn't know the account" do
      Req.Test.stub(KilnCloudflareImages.Client, &Plug.Conn.send_resp(&1, 404, ""))
      assert {:error, message} = Backend.check()
      assert message =~ "CLOUDFLARE_ACCOUNT_ID"
    end

    test "asks nothing of Cloudflare without its settings" do
      Application.put_env(:kiln_cms, KilnCloudflareImages, account_id: "acc123")
      assert {:error, "Settings missing: " <> _} = Backend.check()
    end
  end

  test "has a stable name" do
    assert Backend.name() == "cloudflare_images"
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
