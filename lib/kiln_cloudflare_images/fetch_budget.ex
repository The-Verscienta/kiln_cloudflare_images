defmodule KilnCloudflareImages.FetchBudget do
  @moduledoc """
  How many originals (`GET …/images/v1/<id>/blob`) this node may download
  from the Images API.

  The API allows 1,200 calls per five minutes across the whole Cloudflare
  account, and going over blocks every call for five minutes, including
  other apps' uploads on the same account. Kiln fetches an original for
  every anonymous `/media/:id/download`, every rotation, and every variant
  job (one per image after an adoption), so without a cap a scraper or a
  large adoption could take the account's whole allowance.

  The budget (`KilnCloudflareImages.Config.fetch_budget/0`, per five minutes)
  is spent a fifth per minute, so it can't be used up in one burst; any five
  minutes overlap at most six minutes' shares, 1.2× the budget. Over budget, a
  fetch fails with `{:error, {:rate_limited, retry_after_ms}}` (the shape
  Kiln's own budgets use) without calling Cloudflare: a download is a 404,
  and a variant job snoozes until the next minute. Uploads and deletes
  aren't counted: each follows a write in Kiln, not a read anyone can repeat.

  Per node and approximate: concurrent callers at a window boundary can let a
  few extra through.
  """

  require Logger

  alias KilnCloudflareImages.Config

  @window_seconds 60
  @windows_per_budget 5
  @key {__MODULE__, :counter}

  @doc """
  Spend one fetch, or `{:error, {:rate_limited, retry_after_ms}}` when this
  minute's share is gone, with the time left until the next minute.
  """
  @spec take(integer()) :: :ok | {:error, {:rate_limited, pos_integer()}}
  def take(now \\ System.system_time(:second)) do
    limit = per_window(Config.fetch_budget())
    counter = counter()
    window = div(now, @window_seconds)
    roll(counter, window)
    limited = {:error, {:rate_limited, ((window + 1) * @window_seconds - now) * 1000}}

    case :atomics.add_get(counter, 2, 1) do
      count when count <= limit ->
        :ok

      count when count == limit + 1 ->
        Logger.warning(
          "Cloudflare Images fetch budget spent (#{limit}/min); " <>
            "originals are refused until the next minute"
        )

        limited

      _over ->
        limited
    end
  end

  # Rounded up, so a small budget still allows something each minute; 0 is off.
  defp per_window(budget), do: div(budget + @windows_per_budget - 1, @windows_per_budget)

  # Slot 1 is the current window, slot 2 its count. Whoever moves the window
  # on resets the count.
  defp roll(counter, window) do
    case :atomics.get(counter, 1) do
      ^window ->
        :ok

      seen ->
        if :atomics.compare_exchange(counter, 1, seen, window) == :ok,
          do: :atomics.put(counter, 2, 0)

        :ok
    end
  end

  # Made on first use. Two first callers racing can each make one; the loser's
  # count is lost, once per node.
  defp counter do
    case :persistent_term.get(@key, nil) do
      nil ->
        counter = :atomics.new(2, signed: true)
        :persistent_term.put(@key, counter)
        counter

      counter ->
        counter
    end
  end
end
