defmodule KilnCloudflareImages.Client do
  @moduledoc """
  The Cloudflare Images API v1 calls the backend needs, over `Req`: upload
  under a custom ID, download the original, delete, and the account's usage
  for Kiln's connection check.

  The host is fixed (`api.cloudflare.com`), never taken from data, so these
  calls don't go through `KilnCMS.SafeFetch`.
  """

  require Logger

  alias KilnCloudflareImages.{Config, FetchBudget}

  @api "https://api.cloudflare.com/client/v4"
  @timeout 30_000

  # The longest this client sleeps before a retry, whatever Cloudflare's
  # `Retry-After` says. Uploads run inside an editor's request.
  @max_retry_delay 5_000

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

  @doc """
  The original image's bytes. `{:error, {:rate_limited, retry_after_ms}}`
  when this node's `KilnCloudflareImages.FetchBudget` is spent (without
  calling Cloudflare) or Cloudflare answers 429.
  """
  @spec fetch(String.t()) :: {:ok, binary()} | {:error, term()}
  def fetch(id) do
    with :ok <- FetchBudget.take() do
      case request(:get, "/#{segment(id)}/blob", decode_body: false) do
        {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
        {:ok, %{status: 404}} -> {:error, :not_found}
        other -> failure("fetch #{id}", other)
      end
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
  Cheap, but not proof the token can reach the images: a token whose Images
  permissions sit on specific domains instead of the account gets this and
  is refused everything else (`read_images/0`).
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

  @doc """
  Whether the token may read the account's images: lists one page
  (`GET …/images/v1`), which needs Images Read on the account. The read
  Kiln's downloads depend on, made without naming an image.
  """
  @spec read_images() :: :ok | {:error, term()}
  def read_images do
    case request(:get, "", params: [per_page: 10], retry: false) do
      {:ok, %{status: 200, body: %{"success" => true}}} -> :ok
      other -> failure("list images", other)
    end
  end

  defp request(method, path, opts) do
    [
      method: method,
      url: "#{@api}/accounts/#{Config.account_id()}/images/v1#{path}",
      auth: {:bearer, Config.api_token()},
      receive_timeout: @timeout,
      retry: &retry/2,
      max_retries: 2
    ]
    |> Keyword.merge(opts)
    |> Keyword.merge(Config.req_options())
    |> Req.request()
  end

  # Req's `:transient` (every method, as an upload or delete that landed is
  # recognised on the retry), except that a 429 or 503 never sleeps longer
  # than `@max_retry_delay`. Req would otherwise wait out any `Retry-After`;
  # Cloudflare's account-wide rate limit answers with five minutes. A 429
  # without a usable `Retry-After` isn't retried: it's that limit, and an
  # early retry only spends a call.
  defp retry(request, %Req.Response{status: status} = response) when status in [429, 503] do
    case retry_after(response) do
      delay when is_integer(delay) and delay <= @max_retry_delay -> {:delay, delay}
      nil when status == 503 -> {:delay, backoff(request)}
      _too_long_or_unknown -> false
    end
  end

  defp retry(_request, %Req.Response{status: status}), do: status in [408, 500, 502, 504]

  defp retry(_request, %Req.TransportError{reason: reason}),
    do: reason in [:timeout, :econnrefused, :closed]

  defp retry(_request, %Req.HTTPError{protocol: :http2, reason: reason}),
    do: reason in [:unprocessed, :pool_not_available]

  defp retry(_request, _exception), do: false

  # Seconds only, which is what Cloudflare sends. Req's own parser raises on a
  # malformed HTTP date and on a repeated header.
  defp retry_after(response) do
    with [value] <- Req.Response.get_header(response, "retry-after"),
         {seconds, ""} when seconds >= 0 <- Integer.parse(String.trim(value)) do
      seconds * 1000
    else
      _ -> nil
    end
  end

  # 1s, 2s, … — Req's backoff, which `{:delay, _}` replaces.
  defp backoff(request),
    do:
      min(
        1000 * Integer.pow(2, Req.Request.get_private(request, :req_retry_count, 0)),
        @max_retry_delay
      )

  # Kiln's keys are flat (no `/`), but an adopted ID came from somewhere else.
  defp segment(id), do: URI.encode(id, &URI.char_unreserved?/1)

  # Cloudflare's own rate limit, in the shape Kiln's budgets use, so a job can
  # snooze until it lifts. Without a usable Retry-After, five minutes: the
  # account-wide limit's block.
  defp failure(what, {:ok, %{status: 429, body: body} = response}) do
    Logger.warning("Cloudflare Images #{what} rate-limited (429): #{inspect(errors(body))}")
    {:error, {:rate_limited, retry_after(response) || 300_000}}
  end

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
