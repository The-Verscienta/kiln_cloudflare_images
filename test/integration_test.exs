defmodule KilnCloudflareImages.IntegrationTest do
  @moduledoc """
  The plugin inside Kiln: an upload through `KilnCMS.Media.Ingest` lands in
  Cloudflare under its storage key, the variant worker records flexible-variant
  URLs, and an imported row is adopted — against a `Req.Test` stand-in for the
  Images API that keeps what it is sent.
  """
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  alias KilnCloudflareImages.{Backend, Client}
  alias KilnCMS.CMS
  alias KilnCMS.Media.{Adoption, Ingest, VariantWorker}

  setup do
    Application.put_env(:kiln_cms, KilnCloudflareImages,
      account_id: "acc123",
      api_token: "tok",
      account_hash: "HASH",
      req_options: [plug: {Req.Test, Client}, retry: false]
    )

    Application.put_env(:kiln_cms, :image_backend, Backend)

    on_exit(fn ->
      Application.delete_env(:kiln_cms, KilnCloudflareImages)
      Application.delete_env(:kiln_cms, :image_backend)
    end)

    {:ok, images} = Agent.start_link(fn -> %{} end)
    Req.Test.stub(Client, &cloudflare(&1, images))

    %{images: images}
  end

  # Upload, blob and delete — keyed by custom ID.
  defp cloudflare(conn, images) do
    case {conn.method, String.split(conn.request_path, "/images/v1", parts: 2)} do
      {"POST", [_, ""]} ->
        conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:multipart], pass: ["*/*"]))
        %{"id" => id, "file" => %Plug.Upload{path: path}} = conn.body_params
        Agent.update(images, &Map.put(&1, id, File.read!(path)))
        Req.Test.json(conn, %{"success" => true, "result" => %{"id" => id}})

      {"GET", [_, "/" <> rest]} ->
        id = rest |> String.replace_suffix("/blob", "") |> URI.decode()

        case Agent.get(images, &Map.get(&1, id)) do
          nil -> Plug.Conn.send_resp(conn, 404, "")
          bytes -> Plug.Conn.send_resp(conn, 200, bytes)
        end

      {"DELETE", [_, "/" <> id]} ->
        Agent.update(images, &Map.delete(&1, URI.decode(id)))
        Req.Test.json(conn, %{"success" => true})
    end
  end

  defp actor do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "cfi-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp png(width, height) do
    path = Path.join(System.tmp_dir!(), "cfi-#{System.unique_integer([:positive])}.png")
    {:ok, image} = Image.new(width, height, color: :green)
    {:ok, _} = Image.write(image, path)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "an upload lands in Cloudflare under its key, and its variants are flexible variants",
       %{images: images} do
    assert {:ok, item} = Ingest.store_file(png(1200, 800), "hero.png", actor: actor())

    assert item.image_backend == "cloudflare_images"
    assert item.url == "https://imagedelivery.net/HASH/#{item.storage_key}/public"
    assert Agent.get(images, &Map.has_key?(&1, item.storage_key))

    assert :ok = perform_job(VariantWorker, %{media_item_id: item.id, org_id: item.org_id})

    item = CMS.get_media_item!(item.id, authorize?: false)
    assert {item.width, item.height} == {1200, 800}

    assert item.variants["thumb.webp"]["url"] ==
             "https://imagedelivery.net/HASH/#{item.storage_key}/" <>
               "w=400,h=267,fit=scale-down,q=82,f=webp,metadata=none"

    assert item.variants["card"]["url"] =~ ",fit=cover,"
  end

  test "an imported delivery URL is adopted and derived", %{images: images} do
    bytes = File.read!(png(600, 400))
    Agent.update(images, &Map.put(&1, "directus-uuid", bytes))

    row =
      Ash.Seed.seed!(KilnCMS.CMS.MediaItem, %{
        filename: "herb.png",
        url: "https://imagedelivery.net/HASH/directus-uuid"
      })

    assert {:ok, %{adopted: 1}} = Adoption.run(KilnCMS.Accounts.default_org_id())

    adopted = CMS.get_media_item!(row.id, authorize?: false)
    assert adopted.storage_key == "directus-uuid"
    assert adopted.url == "https://imagedelivery.net/HASH/directus-uuid/public"

    assert :ok = perform_job(VariantWorker, %{media_item_id: row.id, org_id: row.org_id})
    assert CMS.get_media_item!(row.id, authorize?: false).width == 600
  end
end
