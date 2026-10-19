defmodule UmberWeb.RateLimit do
  @moduledoc """
  A small fixed-window limiter in ETS, per copy of the app: sign-ins,
  registrations, bids and uploads. nginx limits requests per address as well.
  """

  @table __MODULE__

  def start do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    :ok
  end

  @doc "Allows `limit` hits per `window` seconds for `key`."
  def check(key, limit, window) do
    start()
    bucket = div(System.system_time(:second), window)
    k = {key, bucket}
    count = :ets.update_counter(@table, k, {2, 1}, {k, 0})

    if count == 1, do: prune(bucket, key)
    if count <= limit, do: :ok, else: {:error, :rate_limited}
  end

  defp prune(bucket, {kind, _} = _key) do
    # Old windows for this kind of key go when a new window starts.
    :ets.select_delete(@table, [{{{{kind, :_}, :"$1"}, :_}, [{:<, :"$1", bucket}], [true]}])
  end

  defp prune(_, _), do: :ok
end
