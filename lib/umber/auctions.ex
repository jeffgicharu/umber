defmodule Umber.Auctions do
  @moduledoc "Bidding, watching and buying, as bidders and the rostrum use them."

  import Ecto.Query
  alias Umber.Repo
  alias Umber.Accounts.User
  alias Umber.Catalogue.{Lot, Sale}
  alias Umber.Auctions.{LotServer, Live, Broadcasts, Invoice, MaxBid, Increments}

  ## Timed lots

  @doc "A one-tap bid at the next amount, or a maximum, on a timed lot."
  def bid(%Lot{id: id}, %User{} = user, kind, amount) when kind in [:bid, :max] do
    LotServer.bid(id, user, kind, amount)
  end

  @doc "The bidder's own maximum on a lot, if they left one."
  def own_max(%Lot{id: lot_id}, %User{id: uid}) do
    Repo.one(from m in MaxBid, where: m.lot_id == ^lot_id and m.user_id == ^uid, select: m.amount)
  end

  def own_max(_, _), do: nil

  @doc "The amounts a bidder can choose for a maximum: the next twelve steps."
  def max_choices(%Lot{} = lot, %User{} = user) do
    start = Increments.next(lot.current_bid, lot.opening_bid)

    Stream.iterate(start, &(&1 + Increments.step(&1)))
    |> Enum.take(24)
    |> Enum.take_while(&(&1 <= user.bid_limit))
  end

  ## Live sales

  def live_bid(sale_id, %User{} = user, seen_asking) do
    case Live.bid(sale_id, user, seen_asking) do
      {:ok, %{session: s}} = ok ->
        lot = Repo.get!(Lot, s.lot_id)
        previous = previous_leader(lot, user.id)
        Broadcasts.live(s)
        Broadcasts.live_lot(lot, previous)
        ok

      error ->
        error
    end
  end

  # The leader before this bid: the user of the second-newest bid on the lot.
  defp previous_leader(lot, uid) do
    from(b in Umber.Auctions.Bid, where: b.lot_id == ^lot.id, order_by: [desc: b.inserted_at, desc: b.id], offset: 1, limit: 1, select: b.user_id)
    |> Repo.one()
    |> then(&if(&1 == uid, do: nil, else: &1))
  end

  def leave_absentee(%Lot{} = lot, %User{} = user, amount), do: Live.leave_absentee(lot, user, amount)

  ## Rostrum

  @doc "A command from the auctioneer's console. Broadcasts the result."
  def rostrum(sale_id, %User{} = staff, command) do
    if User.role?(staff, "auctioneer") do
      result =
        case command do
          :take -> Live.take_rostrum(sale_id, staff)
          :leave -> Live.leave_rostrum(sale_id, staff)
          {:open, lot_id, asking} -> with_held(sale_id, staff, fn -> Live.open_lot(sale_id, lot_id, asking) end)
          {:asking, amount} -> with_held(sale_id, staff, fn -> Live.set_asking(sale_id, amount) end)
          {:floor, paddle} -> with_held(sale_id, staff, fn -> floor(sale_id, paddle) end)
          :book -> with_held(sale_id, staff, fn -> Live.book_bid(sale_id) end)
          :warn -> with_held(sale_id, staff, fn -> Live.warn(sale_id) end)
          :hammer -> with_held(sale_id, staff, fn -> Live.hammer(sale_id) end)
          :pause -> with_held(sale_id, staff, fn -> Live.pause(sale_id) end)
          :resume -> with_held(sale_id, staff, fn -> Live.resume(sale_id) end)
        end

      announce(result)
      result
    else
      {:error, :not_auctioneer}
    end
  end

  defp with_held(sale_id, staff, fun) do
    case Live.get(sale_id) do
      %{auctioneer_id: id} when id == staff.id -> fun.()
      _ -> {:error, :not_holding}
    end
  end

  # A floor bid for a paddle in the room, or for "a bidder in the room" if none is given.
  defp floor(sale_id, paddle) do
    bidder =
      case paddle do
        p when is_integer(p) -> Repo.one(from u in User, where: u.paddle == ^p and u.kind != "staff", select: u.id)
        _ -> Repo.one(from u in User, where: u.kind == "sample", order_by: fragment("random()"), limit: 1, select: u.id)
      end

    if bidder, do: Live.floor_bid(sale_id, bidder), else: {:error, :unknown_paddle}
  end

  defp announce({:ok, %{session: s, result: result}}) do
    Broadcasts.live(s)

    cond do
      result -> Broadcasts.live_lot(result.lot) && Broadcasts.won(result)
      s.lot_id -> Broadcasts.live_lot(Repo.get!(Lot, s.lot_id))
      true -> :ok
    end
  end

  defp announce(_), do: :ok

  ## Watching

  def watching?(%User{id: uid}, %Lot{id: lid}), do: Repo.exists?(from w in "watches", where: w.user_id == ^uid and w.lot_id == ^lid)
  def watching?(_, _), do: false

  def watch(%User{id: uid}, %Lot{id: lid}) do
    Repo.insert_all("watches", [%{user_id: uid, lot_id: lid, inserted_at: DateTime.utc_now()}], on_conflict: :nothing)
    :ok
  end

  def unwatch(%User{id: uid}, %Lot{id: lid}) do
    from(w in "watches", where: w.user_id == ^uid and w.lot_id == ^lid) |> Repo.delete_all()
    :ok
  end

  def watched_ids(%User{id: uid}), do: from(w in "watches", where: w.user_id == ^uid, select: w.lot_id) |> Repo.all() |> MapSet.new()
  def watched_ids(_), do: MapSet.new()

  def watchlist(%User{id: uid}) do
    from(l in Lot,
      join: w in "watches",
      on: w.lot_id == l.id and w.user_id == ^uid,
      join: s in assoc(l, :sale),
      order_by: [asc: fragment("? = 'open'", l.status), asc: l.closes_at],
      preload: [sale: s, work: :artist]
    )
    |> Repo.all()
  end

  ## The bidder's account

  @doc "Lots the bidder has bid on that are still open or not yet sold."
  def active_bids(%User{id: uid}) do
    from(l in Lot,
      join: s in assoc(l, :sale),
      where: l.status in ["open", "pending"],
      where: l.id in subquery(from b in Umber.Auctions.Bid, where: b.user_id == ^uid, select: b.lot_id) or
               l.id in subquery(from m in MaxBid, where: m.user_id == ^uid, select: m.lot_id),
      order_by: [asc: l.closes_at],
      preload: [sale: s, work: :artist]
    )
    |> Repo.all()
  end

  @doc "Recent lots the bidder bid on that have finished, won or not."
  def finished_bids(%User{id: uid}, limit \\ 20) do
    from(l in Lot,
      join: s in assoc(l, :sale),
      where: l.status in ["sold", "unsold"],
      where: l.id in subquery(from b in Umber.Auctions.Bid, where: b.user_id == ^uid, select: b.lot_id),
      order_by: [desc: l.closed_at],
      limit: ^limit,
      preload: [sale: s, work: :artist]
    )
    |> Repo.all()
  end

  def invoices(%User{id: uid}) do
    from(i in Invoice, where: i.user_id == ^uid, order_by: [desc: i.inserted_at], preload: [lot: [sale: [], work: :artist]])
    |> Repo.all()
  end

  def get_invoice(%User{} = user, number) do
    query = from(i in Invoice, where: i.number == ^number, preload: [:user, :paid_by, lot: [sale: [], work: :artist]])

    case Repo.one(query) do
      %Invoice{user_id: uid} = inv when uid == user.id -> inv
      %Invoice{} = inv -> if User.role?(user, "client_services"), do: inv
      nil -> nil
    end
  end

  def mark_paid(%Invoice{} = invoice, %User{} = staff) do
    if User.role?(staff, "client_services") do
      invoice
      |> Ecto.Changeset.change(status: "paid", paid_at: DateTime.utc_now(), paid_by_id: staff.id)
      |> Repo.update()
    else
      {:error, :not_allowed}
    end
  end

  def list_invoices(opts \\ []) do
    from(i in Invoice,
      order_by: [desc: i.inserted_at],
      limit: ^Keyword.get(opts, :limit, 50),
      preload: [:user, lot: [sale: [], work: :artist]]
    )
    |> then(fn q -> if s = opts[:status], do: where(q, [i], i.status == ^s), else: q end)
    |> Repo.all()
  end

  @doc "The live session of a sale, or nil before it is created."
  def live_session(%Sale{id: id}), do: Live.get(id)
end
