defmodule KilnCloudflareImages.Client do
  @moduledoc """
  The Cloudflare Images API v1 calls the backend needs, over `Req`: upload
  under a custom ID, download the original, delete, and the account's usage
  for Kiln's connection check.

  The host is fixed (`api.cloudflare.com`), never taken from data, so these
  calls don't go through `KilnCMS.SafeFetch`.
  """

  require Logger

  alias KilnCloudflareImages.Config

  @api "https://api.cloudflare.com/client/v4"
  @timeout 30_000

  @doc """
  Upload the file at `path` with the custom ID `id`.

  Cloudflare answers a second upload of an ID it already has with a conflict.
  Kiln's keys are generated per write and never reused, so a conflict means an
  earlier attempt at this same write landed (a retry after a timeout) — success.
  """
  @spec upload(String.t(), Path.t()) :: {:ok, String.t()} | {:error, term()}
  def upload(id, path) do
    file = {File.read!(path), filename: Path.basename(path)}

    case request(:post, "", form_multipart: [id: id, file: file]) do
      {:ok, %{status: 200, body: %{"success" => true}}} ->
        {:ok, id}

      {:ok, %{status: 409}} ->
        {:ok, id}

      other ->
        failure("upload #{id}", other)
    end
  end

  @doc "The original image's bytes."
  @spec fetch(String.t()) :: {:ok, binary()} | {:error, term()}
  def fetch(id) do
    case request(:get, "/#{segment(id)}/blob", decode_body: false) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :not_found}
      other -> failure("fetch #{id}", other)
    end
  end

  @doc "Delete the image. One that is already gone is success."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(id) do
    case request(:delete, "/#{segment(id)}", []) do
      {:ok, %{status: status}} when status in [200, 404] -> :ok
      other -> failure("delete #{id}", other)
    end
  end

  @doc """
  The account's stored-image count and allowance (`GET …/images/v1/stats`).
  Needs only Images Read, so it is also the cheapest proof the token works.
  """
  @spec stats() ::
          {:ok, %{current: non_neg_integer(), allowed: non_neg_integer()}} | {:error, term()}
  def stats do
    case request(:get, "/stats", retry: false) do
      {:ok,
       %{
         status: 200,
         body: %{"result" => %{"count" => %{"current" => current, "allowed" => allowed}}}
       }}
      when is_integer(current) and is_integer(allowed) ->
        {:ok, %{current: current, allowed: allowed}}

      other ->
        failure("stats", other)
    end
  end

  defp request(method, path, opts) do
    [
      method: method,
      url: "#{@api}/accounts/#{Config.account_id()}/images/v1#{path}",
      auth: {:bearer, Config.api_token()},
      receive_timeout: @timeout,
      retry: :transient,
      max_retries: 2
    ]
    |> Keyword.merge(opts)
    |> Keyword.merge(Config.req_options())
    |> Req.request()
  end

  # Kiln's keys are flat (no `/`), but an adopted ID came from somewhere else.
  defp segment(id), do: URI.encode(id, &URI.char_unreserved?/1)

  defp failure(what, {:ok, %{status: status, body: body}}) do
    Logger.warning("Cloudflare Images #{what} failed (#{status}): #{inspect(errors(body))}")
    {:error, {:http_status, status}}
  end

  defp failure(what, {:error, reason}) do
    Logger.warning("Cloudflare Images #{what} failed: #{inspect(reason)}")
    {:error, reason}
  end

  # The API's own error list, not the whole body — never the request, which
  # carries the token.
  defp errors(%{"errors" => errors}), do: errors
  defp errors(_body), do: :no_error_detail
end
