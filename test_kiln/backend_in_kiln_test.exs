defmodule KilnCloudflareImages.BackendInKilnTest do
  @moduledoc """
  What the core says about the backend: its registry recognises it, and the
  plugin doctor passes it selected. Runs only inside a Kiln checkout (see
  test_kiln/README.md); `test/backend_test.exs` covers the URL grammar on its
  own.
  """
  use ExUnit.Case, async: false

  alias KilnCloudflareImages.Backend

  @settings [account_id: "acc123", api_token: "token", account_hash: "HASH"]

  setup do
    Application.put_env(:kiln_cms, KilnCloudflareImages, @settings)
    on_exit(fn -> Application.delete_env(:kiln_cms, KilnCloudflareImages) end)
  end

  test "is a Kiln image backend with a stable name" do
    assert Kiln.ImageBackend.Registry.backend?(Backend)
    assert Backend.name() == "cloudflare_images"
  end

  # What `mix kiln.plugins.doctor` checks once a deployment lists the plugin —
  # the test env's plugin list is Kiln's own fixture, so it's asked directly.
  test "passes the plugin doctor's image-backend checks, selected" do
    # `mix kiln.plugins.doctor` loads every plugin before this check; called
    # directly on a fresh VM nothing has. Kiln before kiln_cms#1981 skipped an
    # unloaded plugin and reported its backend as undeclared.
    Code.ensure_loaded!(KilnCloudflareImages.Plugin)

    assert Mix.Tasks.Kiln.Plugins.Doctor.image_backend_problems(
             [KilnCloudflareImages.Plugin],
             Backend
           ) == []
  end
end
