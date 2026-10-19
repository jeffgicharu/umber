defmodule Umber.Auctions.Timed do
  @moduledoc """
  Bidding on timed lots, and closing them.

  Every change is one transaction that starts by locking the lot's row, so two
  bids on a lot are always decided one after the other, whichever copy of the
  app received them. Nothing is reported as accepted until it is committed.
  """

  import Ecto.Query
  alias Umber.Repo
  alias Umber.Accounts.User
  alias Umber.Catalogue.Lot
  alias Umber.Auctions.{Bid, MaxBid, Invoice, Increments, Proxy}

  # A bid this close to the end gives the lot this long again.
  @soft_close 120

  def soft_close, do: @soft_close

  @doc """
  Places a bid (`:bid`, one tap at the next amount) or a maximum (`:max`) on a
  timed lot. Returns `{:ok, change}` or `{:error, reason}`.
  """
  def place(lot_id, %User{} = user, kind, amount, now \\ nil) when kind in [:bid, :max] do
    Repo.transaction(fn ->
      lot = lock(lot_id)
      # The time of acceptance is taken once the lock is held, so the order of
      # times is the order the bids were decided in.
      now = now || DateTime.utc_now()

      with :ok <- check_open(lot, now),
           :ok <- check_bidder(user, amount),
           :ok <- check_amount(lot, kind, amount),
           maxes = load_maxes(lot.id),
           # Later than every maximum already left, for ties.
           new = %{user_id: user.id, amount: amount, at: length(maxes), kind: kind},
           {:ok, r} <- Proxy.resolve(lot, maxes, new) do
        apply_resolution(lot, user, r, now)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp lock(lot_id) do
    from(l in Lot, where: l.id == ^lot_id, lock: "FOR UPDATE", preload: [:sale]) |> Repo.one!()
  end

  defp check_open(%Lot{status: "open", closes_at: %DateTime{} = closes}, now) do
    if DateTime.compare(now, closes) == :lt, do: :ok, else: {:error, :closed}
  end

  defp check_open(%Lot{status: "pending"}, _now), do: {:error, :not_open}
  defp check_open(%Lot{}, _now), do: {:error, :closed}

  defp check_bidder(%User{kind: "staff"}, _), do: {:error, :staff}
  defp check_bidder(%User{bid_limit: limit}, amount) when amount > limit, do: {:error, {:over_limit, limit}}
  defp check_bidder(_, _), do: :ok

  defp check_amount(lot, :bid, amount) do
    if amount == Increments.next(lot.current_bid, lot.opening_bid), do: :ok, else: {:error, :price_moved}
  end

  defp check_amount(_lot, :max, amount) do
    if amount > 0 and Increments.round_down(amount) == amount, do: :ok, else: {:error, :off_step}
  end

  defp load_maxes(lot_id) do
    from(m in MaxBid, where: m.lot_id == ^lot_id, order_by: [asc: m.inserted_at, asc: m.id])
    |> Repo.all()
    |> Enum.with_index()
    |> Enum.map(fn {m, i} -> %{user_id: m.user_id, amount: m.amount, at: i} end)
  end

  defp apply_resolution(lot, user, r, now) do
    Repo.insert!(
      %MaxBid{lot_id: lot.id, user_id: user.id, amount: r.max.amount},
      on_conflict: [set: [amount: r.max.amount, updated_at: now]],
      conflict_target: [:lot_id, :user_id]
    )

    # Entries share one transaction; microseconds keep their order.
    r.entries
    |> Enum.with_index()
    |> Enum.each(fn {{uid, amount, kind}, i} ->
      Repo.insert!(%Bid{lot_id: lot.id, user_id: uid, amount: amount, kind: kind, source: "online", inserted_at: DateTime.add(now, i, :microsecond)})
    end)

    closes = lot.closes_at
    extend? = r.entries != [] and DateTime.diff(closes, now, :second) < @soft_close
    new_close = if extend?, do: DateTime.add(now, @soft_close, :second), else: closes

    {1, [updated]} =
      from(l in Lot, where: l.id == ^lot.id and l.version == ^lot.version, select: l)
      |> Repo.update_all(
        set: [
          current_bid: r.price,
          leader_id: r.leader_id,
          closes_at: new_close,
          updated_at: now
        ],
        inc: [bid_count: length(r.entries), version: 1, extensions: if(extend?, do: 1, else: 0)]
      )

    %{
      lot: %{updated | sale: lot.sale},
      previous_leader_id: lot.leader_id,
      bidder_id: user.id,
      entries: r.entries,
      extended: extend?,
      leading: r.leader_id == user.id,
      max: r.max.amount
    }
  end

  @doc """
  Closes a timed lot whose time has come. Safe to call from any copy, any
  number of times: only the first call that finds it open and due closes it.
  Returns `{:ok, change}`, `{:ok, :already_closed}` or `{:error, :not_due}`.
  """
  def close(lot_id, now \\ nil) do
    Repo.transaction(fn ->
      lot = lock(lot_id)
      now = now || DateTime.utc_now()

      cond do
        lot.status != "open" -> :already_closed
        DateTime.compare(now, lot.closes_at) == :lt -> Repo.rollback(:not_due)
        true -> finish(lot, now)
      end
    end)
  end

  @doc false
  # Shared with live sales: records the result and, for a real bidder, the invoice.
  def finish(lot, now, hammer \\ nil) do
    hammer = hammer || lot.current_bid
    sold? = is_integer(hammer) and not is_nil(lot.leader_id) and hammer >= lot.reserve

    {1, [updated]} =
      from(l in Lot, where: l.id == ^lot.id and l.version == ^lot.version, select: l)
      |> Repo.update_all(
        set: [
          status: if(sold?, do: "sold", else: "unsold"),
          hammer: if(sold?, do: hammer),
          buyer_id: if(sold?, do: lot.leader_id),
          closed_at: now,
          updated_at: now
        ],
        inc: [version: 1]
      )

    invoice =
      if sold? do
        buyer = Repo.get!(User, lot.leader_id)
        if buyer.kind == "bidder", do: create_invoice(updated, lot.sale, buyer, hammer, now)
      end

    %{lot: %{updated | sale: lot.sale}, invoice: invoice}
  end

  defp create_invoice(lot, sale, buyer, hammer, now) do
    a = Invoice.amounts(hammer)

    Repo.insert!(%Invoice{
      number: "UMB-#{sale.number}-#{String.pad_leading(Integer.to_string(lot.number), 3, "0")}",
      lot_id: lot.id,
      user_id: buyer.id,
      hammer: a.hammer,
      premium: a.premium,
      vat: a.vat,
      total: a.total,
      status: "due",
      inserted_at: now,
      updated_at: now
    })
  end
end
