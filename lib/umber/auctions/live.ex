defmodule Umber.Auctions.Live do
  @moduledoc """
  A live sale at the rostrum. One row per sale holds what the room sees: the
  lot on the block, the asking price, the bid in hand and the auctioneer's last
  call. Every change locks that row first, so bids from the room, the book and
  online are taken strictly one at a time, and each is stamped with the time it
  was decided, once the lock is held.
  """

  import Ecto.Query
  alias Umber.Repo
  alias Umber.Accounts.User
  alias Umber.Catalogue.Lot
  alias Umber.Auctions.{Bid, MaxBid, LiveSession, Increments, Timed}

  def get(sale_id), do: Repo.get(LiveSession, sale_id)

  @doc "Creates the session row for a live sale if it does not exist yet."
  def ensure(sale_id) do
    now = DateTime.utc_now()

    Repo.insert!(
      %LiveSession{sale_id: sale_id, state: "waiting", inserted_at: now, updated_at: now},
      on_conflict: :nothing,
      conflict_target: :sale_id
    )

    get(sale_id)
  end

  @doc "Absentee maximums left before the sale; the auctioneer bids them from the book."
  def leave_absentee(%Lot{} = lot, %User{} = user, amount) do
    Repo.transaction(fn ->
      lot = from(l in Lot, where: l.id == ^lot.id, lock: "FOR UPDATE") |> Repo.one!()
      now = DateTime.utc_now()

      cond do
        user.kind == "staff" ->
          Repo.rollback(:staff)

        lot.status != "pending" ->
          Repo.rollback(:closed)

        amount > user.bid_limit ->
          Repo.rollback({:over_limit, user.bid_limit})

        amount < lot.opening_bid ->
          Repo.rollback({:too_low, lot.opening_bid})

        Increments.round_down(amount) != amount ->
          Repo.rollback(:off_step)

        true ->
          Repo.insert!(%MaxBid{lot_id: lot.id, user_id: user.id, amount: amount},
            on_conflict: [set: [amount: amount, updated_at: now]],
            conflict_target: [:lot_id, :user_id]
          )

          %{lot: lot, amount: amount}
      end
    end)
  end

  @doc "Puts a lot on the block at an opening asking price."
  def open_lot(sale_id, lot_id, asking, now \\ nil) do
    change(sale_id, now, fn session, now ->
      lot =
        from(l in Lot, where: l.id == ^lot_id and l.sale_id == ^sale_id, lock: "FOR UPDATE")
        |> Repo.one!()

      if lot.status != "pending" do
        {:error, :lot_not_pending}
      else
        {1, _} =
          from(l in Lot, where: l.id == ^lot.id)
          |> Repo.update_all(
            set: [status: "open", current_bid: nil, leader_id: nil, updated_at: now],
            inc: [version: 1]
          )

        {:ok,
         %{
           lot_id: lot.id,
           state: "open",
           asking: asking,
           current_bid: nil,
           leader_id: nil,
           leader_source: nil,
           call: "Lot #{lot.number}. Who will start me at #{money(asking)}?"
         }, session}
      end
    end)
  end

  @doc """
  An online bid at the asking price the bidder saw. If the price has moved on
  since, the bid is refused with the new asking price so the bidder can decide again.
  """
  def bid(sale_id, %User{} = user, seen_asking, now \\ nil) do
    change(sale_id, now, fn session, now ->
      cond do
        not LiveSession.taking_bids?(session) -> {:error, :not_taking_bids}
        user.kind == "staff" -> {:error, :staff}
        session.leader_id == user.id -> {:error, :already_leading}
        seen_asking != session.asking -> {:error, {:asking_moved, session.asking}}
        session.asking > user.bid_limit -> {:error, {:over_limit, user.bid_limit}}
        true -> take(session, user.id, "online", "bid", now)
      end
    end)
  end

  @doc "A bid in the room, for a paddle, taken by the auctioneer."
  def floor_bid(sale_id, bidder_id, now \\ nil) do
    change(sale_id, now, fn session, now ->
      cond do
        not LiveSession.taking_bids?(session) -> {:error, :not_taking_bids}
        session.leader_id == bidder_id -> {:error, :already_leading}
        true -> take(session, bidder_id, "room", "floor", now)
      end
    end)
  end

  @doc "The auctioneer bids for an absentee bidder from the book, if their maximum allows."
  def book_bid(sale_id, now \\ nil) do
    change(sale_id, now, fn session, now ->
      with true <- LiveSession.taking_bids?(session) || {:error, :not_taking_bids},
           %MaxBid{} = m <- book_candidate(session) || {:error, :no_book_bid} do
        take(session, m.user_id, "absentee", "absentee", now)
      end
    end)
  end

  @doc "Whether the book holds a maximum that can bid at the current asking price."
  def book_candidate(%LiveSession{lot_id: nil}), do: nil

  def book_candidate(%LiveSession{} = s) do
    from(m in MaxBid,
      where: m.lot_id == ^s.lot_id and m.amount >= ^s.asking,
      order_by: [desc: m.amount, asc: m.inserted_at],
      limit: 1
    )
    |> then(fn q -> if s.leader_id, do: where(q, [m], m.user_id != ^s.leader_id), else: q end)
    |> Repo.one()
  end

  defp take(session, bidder_id, source, kind, now) do
    lot = from(l in Lot, where: l.id == ^session.lot_id, lock: "FOR UPDATE") |> Repo.one!()
    amount = session.asking

    Repo.insert!(%Bid{
      lot_id: lot.id,
      user_id: bidder_id,
      amount: amount,
      kind: kind,
      source: source,
      inserted_at: now
    })

    {1, _} =
      from(l in Lot, where: l.id == ^lot.id)
      |> Repo.update_all(
        set: [current_bid: amount, leader_id: bidder_id, updated_at: now],
        inc: [bid_count: 1, version: 1]
      )

    where = %{"online" => "online", "room" => "in the room", "absentee" => "on the book"}[source]

    {:ok,
     %{
       state: "open",
       current_bid: amount,
       leader_id: bidder_id,
       leader_source: source,
       asking: Increments.next(amount, amount),
       call: "#{money(amount)}, #{where}."
     }, session}
  end

  @doc "Sets the asking price, up or down, before or between bids."
  def set_asking(sale_id, amount, now \\ nil) do
    change(sale_id, now, fn session, _now ->
      floor =
        if session.current_bid,
          do: Increments.next(session.current_bid, session.current_bid),
          else: Increments.step(0)

      cond do
        not LiveSession.taking_bids?(session) ->
          {:error, :not_taking_bids}

        amount < floor ->
          {:error, {:too_low, floor}}

        true ->
          {:ok, %{asking: amount, state: "open", call: asking_call(session, amount)}, session}
      end
    end)
  end

  defp asking_call(%{current_bid: nil}, amount), do: "Do I see #{money(amount)}?"

  defp asking_call(%{current_bid: bid}, amount),
    do: "At #{money(bid)}. #{money(amount)}, anywhere?"

  @doc "Fair warning: the last call before the hammer."
  def warn(sale_id, now \\ nil) do
    change(sale_id, now, fn session, _now ->
      cond do
        session.state != "open" ->
          {:error, :not_open}

        is_nil(session.current_bid) ->
          {:error, :no_bid}

        true ->
          {:ok, %{state: "warning", call: "Fair warning, at #{money(session.current_bid)}."},
           session}
      end
    end)
  end

  @doc "Brings the hammer down: sold if the reserve is met, otherwise passed."
  def hammer(sale_id, now \\ nil) do
    change(sale_id, now, fn session, now ->
      if not LiveSession.taking_bids?(session) do
        {:error, :not_taking_bids}
      else
        lot =
          from(l in Lot, where: l.id == ^session.lot_id, lock: "FOR UPDATE", preload: [:sale])
          |> Repo.one!()

        result = Timed.finish(lot, now, session.current_bid)

        {state, call} =
          case result.lot.status do
            "sold" ->
              {"sold", "Sold, for #{money(result.lot.hammer)}#{sold_to(session)}."}

            _ when is_nil(session.current_bid) ->
              {"passed", "No bids. Lot #{lot.number} is passed."}

            _ ->
              {"passed", "Passed, at #{money(session.current_bid)}."}
          end

        {:ok, %{state: state, call: call}, session, result}
      end
    end)
  end

  defp sold_to(%{leader_source: "online"}), do: ", online"
  defp sold_to(%{leader_source: "room"}), do: ", in the room"
  defp sold_to(%{leader_source: "absentee"}), do: ", on the book"
  defp sold_to(_), do: ""

  def pause(sale_id, now \\ nil) do
    change(sale_id, now, fn session, _now ->
      if session.state == "ended",
        do: {:error, :ended},
        else: {:ok, %{state: "paused", call: "We'll pause for a moment."}, session}
    end)
  end

  def resume(sale_id, now \\ nil) do
    change(sale_id, now, fn session, _now ->
      cond do
        session.state != "paused" ->
          {:error, :not_paused}

        is_nil(session.lot_id) ->
          {:ok, %{state: "waiting", call: "Thank you for waiting."}, session}

        lot_open?(session.lot_id) ->
          {:ok, %{state: "open", call: asking_call(session, session.asking)}, session}

        true ->
          {:ok, %{state: "sold", call: "Thank you for waiting."}, session}
      end
    end)
  end

  defp lot_open?(lot_id),
    do: Repo.exists?(from l in Lot, where: l.id == ^lot_id and l.status == "open")

  def finish_sale(sale_id, now \\ nil) do
    change(sale_id, now, fn session, _now ->
      {:ok,
       %{
         state: "ended",
         lot_id: nil,
         asking: nil,
         call: "That concludes the sale. Thank you all."
       }, session}
    end)
  end

  @doc "Staff take or leave the rostrum. Only one person holds it at a time."
  def take_rostrum(sale_id, %User{} = staff, now \\ nil) do
    change(sale_id, now, fn session, now ->
      held_by_other? =
        session.auctioneer_id && session.auctioneer_id != staff.id &&
          fresh?(session.auctioneer_seen_at, now)

      cond do
        not User.role?(staff, "auctioneer") -> {:error, :not_auctioneer}
        held_by_other? -> {:error, :rostrum_taken}
        true -> {:ok, %{auctioneer_id: staff.id, auctioneer_seen_at: now}, session}
      end
    end)
  end

  def leave_rostrum(sale_id, %User{id: id}, now \\ nil) do
    change(sale_id, now, fn
      %{auctioneer_id: ^id} = session, _now ->
        {:ok, %{auctioneer_id: nil, auctioneer_seen_at: nil}, session}

      _, _ ->
        {:error, :not_holding}
    end)
  end

  @doc "A heartbeat from the console that holds the rostrum. Does not bump the version."
  def rostrum_heartbeat(sale_id, %User{id: id}) do
    from(s in LiveSession, where: s.sale_id == ^sale_id and s.auctioneer_id == ^id)
    |> Repo.update_all(set: [auctioneer_seen_at: DateTime.utc_now()])
  end

  # How long a console may go quiet before the automatic auctioneer takes over.
  @rostrum_grace 20
  def rostrum_grace, do: @rostrum_grace

  def fresh?(nil, _now), do: false
  def fresh?(seen, now), do: DateTime.diff(now, seen, :second) < @rostrum_grace

  def staffed?(nil, _now), do: false
  def staffed?(%LiveSession{auctioneer_id: nil}, _now), do: false
  def staffed?(%LiveSession{auctioneer_seen_at: seen}, now), do: fresh?(seen, now)

  # Locks the session row, takes the time, lets `fun` decide, and writes what it returns.
  defp change(sale_id, now, fun) do
    Repo.transaction(fn ->
      session =
        from(s in LiveSession, where: s.sale_id == ^sale_id, lock: "FOR UPDATE") |> Repo.one()

      if is_nil(session), do: Repo.rollback(:no_session)
      now = now || DateTime.utc_now()

      case fun.(session, now) do
        {:ok, attrs, session} -> %{session: write(session, attrs, now), result: nil}
        {:ok, attrs, session, result} -> %{session: write(session, attrs, now), result: result}
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp write(session, attrs, now) do
    stamp = if Map.has_key?(attrs, :call), do: %{called_at: now}, else: %{}

    session
    |> Ecto.Changeset.change(
      attrs
      |> Map.merge(stamp)
      |> Map.put(:updated_at, now)
      |> Map.put(:version, session.version + 1)
    )
    |> Repo.update!()
  end

  @doc "KES 1,250,000"
  def money(amount), do: Umber.Format.money(amount)
end
