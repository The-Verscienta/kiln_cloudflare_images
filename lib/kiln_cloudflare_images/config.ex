defmodule KilnCloudflareImages.Config do
  @moduledoc """
  The plugin's settings: `config :kiln_cms, KilnCloudflareImages, …` first,
  then the environment, so a deployment can do either.

  | Key | Environment variable | |
  |---|---|---|
  | `:account_id` | `CLOUDFLARE_ACCOUNT_ID` | required |
  | `:api_token` | `CLOUDFLARE_IMAGES_TOKEN` | required — *Cloudflare Images: Edit* |
  | `:account_hash` | `CLOUDFLARE_IMAGES_ACCOUNT_HASH` | required — the delivery URL's hash |
  | `:variant` | `CLOUDFLARE_IMAGES_VARIANT` | named variant for the plain URL, default `public` |
  | `:delivery_base` | `CLOUDFLARE_IMAGES_DELIVERY_BASE` | default `https://imagedelivery.net/<account_hash>` |
  | `:flexible_variants` | `CLOUDFLARE_IMAGES_FLEXIBLE_VARIANTS` | default `true`; `false` keeps Kiln's encoder |
  | `:fetch_budget` | `CLOUDFLARE_IMAGES_FETCH_BUDGET` | originals fetched per 5 minutes, per node; default `300`, `0` turns fetches off |

  An empty environment variable counts as unset, so a blank line in an `.env`
  file reads as "not configured" rather than as an empty token.
  """

  @doc "Whether every required setting is present."
  @spec complete?() :: boolean()
  def complete?, do: Enum.all?([account_id(), api_token(), account_hash()], &is_binary/1)

  @spec account_id() :: String.t() | nil
  def account_id, do: get(:account_id, "CLOUDFLARE_ACCOUNT_ID")

  @spec api_token() :: String.t() | nil
  def api_token, do: get(:api_token, "CLOUDFLARE_IMAGES_TOKEN")

  @spec account_hash() :: String.t() | nil
  def account_hash, do: get(:account_hash, "CLOUDFLARE_IMAGES_ACCOUNT_HASH")

  @spec variant() :: String.t()
  def variant, do: get(:variant, "CLOUDFLARE_IMAGES_VARIANT") || "public"

  @doc "Where delivery URLs start, without a trailing slash."
  @spec delivery_base() :: String.t()
  def delivery_base do
    base =
      get(:delivery_base, "CLOUDFLARE_IMAGES_DELIVERY_BASE") ||
        "https://imagedelivery.net/#{account_hash()}"

    String.trim_trailing(base, "/")
  end

  @doc """
  Whether the account has flexible variants on (Images → Delivery →
  *Flexible variants*). Without them every rendered size is refused, so the
  plugin answers `:unsupported` and Kiln encodes variants itself.
  """
  @spec flexible_variants?() :: boolean()
  def flexible_variants? do
    case config()[:flexible_variants] do
      nil -> env("CLOUDFLARE_IMAGES_FLEXIBLE_VARIANTS") not in ["false", "0"]
      value -> value != false
    end
  end

  @default_fetch_budget 300

  @doc """
  How many originals this node may fetch from the Images API per five minutes
  (`KilnCloudflareImages.FetchBudget`). The default is a quarter of the
  account's 1,200, leaving the rest for uploads, deletes and other apps on the
  account. Anything that isn't a whole number ≥ 0 reads as the default.
  """
  @spec fetch_budget() :: non_neg_integer()
  def fetch_budget do
    case config()[:fetch_budget] || env("CLOUDFLARE_IMAGES_FETCH_BUDGET") do
      budget when is_integer(budget) and budget >= 0 ->
        budget

      budget when is_binary(budget) ->
        case Integer.parse(String.trim(budget)) do
          {budget, ""} when budget >= 0 -> budget
          _invalid -> @default_fetch_budget
        end

      _unset ->
        @default_fetch_budget
    end
  end

  @doc "Extra `Req` options — the test suite's `plug:` stub. Empty otherwise."
  @spec req_options() :: keyword()
  def req_options, do: Keyword.get(config(), :req_options, [])

  defp get(key, var) do
    case config()[key] do
      value when is_binary(value) and value != "" -> value
      _unset -> env(var)
    end
  end

  defp env(var) do
    case System.get_env(var) do
      "" -> nil
      value -> value
    end
  end

  defp config, do: Application.get_env(:kiln_cms, KilnCloudflareImages, [])
end
