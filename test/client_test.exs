defmodule KilnCloudflareImages.ClientTest do
  @moduledoc """
  The Images API calls, against a `Req.Test` stub standing in for
  `api.cloudflare.com`.
  """
  use ExUnit.Case, async: false

  alias KilnCloudflareImages.Client

  setup do
    Application.put_env(:kiln_cms, KilnCloudflareImages,
      account_id: "acc123",
      api_token: "tok-secret",
      account_hash: "HASH",
      req_options: [plug: {Req.Test, Client}, retry: false]
    )

    on_exit(fn -> Application.delete_env(:kiln_cms, KilnCloudflareImages) end)

    path = Path.join(System.tmp_dir!(), "cfi-#{System.unique_integer([:positive])}.png")
    File.write!(path, "png-bytes")
    on_exit(fn -> File.rm(path) end)

    %{path: path}
  end

  test "upload posts the file under its custom ID, with the token", %{path: path} do
    test = self()

    Req.Test.stub(Client, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        test,
        {:request, conn.method, conn.request_path,
         Plug.Conn.get_req_header(conn, "authorization"), body}
      )

      Req.Test.json(conn, %{"success" => true, "result" => %{"id" => "k.png"}})
    end)

    assert Client.upload("k.png", path) == {:ok, "k.png"}

    assert_received {:request, "POST", "/client/v4/accounts/acc123/images/v1",
                     ["Bearer tok-secret"], body}

    assert body =~ ~s(name="id")
    assert body =~ "k.png"
    assert body =~ "png-bytes"
  end

  test "an ID Cloudflare already has is an earlier attempt that landed", %{path: path} do
    Req.Test.stub(Client, fn conn ->
      conn
      |> Plug.Conn.put_status(409)
      |> Req.Test.json(%{"success" => false, "errors" => [%{"code" => 5409}]})
    end)

    assert Client.upload("k.png", path) == {:ok, "k.png"}
  end

  test "a refused upload is an error that never logs the token", %{path: path} do
    Req.Test.stub(Client, fn conn ->
      conn
      |> Plug.Conn.put_status(403)
      |> Req.Test.json(%{
        "success" => false,
        "errors" => [%{"code" => 10_000, "message" => "Authentication error"}]
      })
    end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert Client.upload("k.png", path) == {:error, {:http_status, 403}}
      end)

    assert log =~ "Authentication error"
    refute log =~ "tok-secret"
  end

  test "fetch downloads the original" do
    Req.Test.stub(Client, fn conn ->
      assert conn.request_path == "/client/v4/accounts/acc123/images/v1/k.png/blob"

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, "png-bytes")
    end)

    assert Client.fetch("k.png") == {:ok, "png-bytes"}
  end

  test "fetch of a missing image is not_found" do
    Req.Test.stub(Client, &Plug.Conn.send_resp(&1, 404, ""))
    assert Client.fetch("gone.png") == {:error, :not_found}
  end

  test "delete succeeds, and so does deleting what's already gone" do
    Req.Test.stub(Client, fn conn ->
      assert conn.method == "DELETE"
      Req.Test.json(conn, %{"success" => true})
    end)

    assert Client.delete("k.png") == :ok

    Req.Test.stub(Client, &Plug.Conn.send_resp(&1, 404, ""))
    assert Client.delete("k.png") == :ok
  end

  test "an ID with reserved characters is encoded into one path segment" do
    Req.Test.stub(Client, fn conn ->
      assert conn.request_path == "/client/v4/accounts/acc123/images/v1/a%2Fb%25c"
      Req.Test.json(conn, %{"success" => true})
    end)

    assert Client.delete("a/b%c") == :ok
  end

  test "stats reads the account's count and allowance" do
    Req.Test.stub(Client, fn conn ->
      assert {conn.method, conn.request_path} ==
               {"GET", "/client/v4/accounts/acc123/images/v1/stats"}

      Req.Test.json(conn, %{
        "success" => true,
        "result" => %{"count" => %{"current" => 1204, "allowed" => 100_000}}
      })
    end)

    assert Client.stats() == {:ok, %{current: 1204, allowed: 100_000}}
  end

  test "stats passes on a refusal as its status" do
    Req.Test.stub(Client, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"success" => false, "errors" => [%{"code" => 10_000}]})
    end)

    assert Client.stats() == {:error, {:http_status, 401}}
  end
end
