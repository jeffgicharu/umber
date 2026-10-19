defmodule Umber.Auctions.Broadcasts do
  @moduledoc """
  What the screens hear after a change is committed: the lot's new state on
  `lot:<id>` and `sale:<id>`, the live room on `live:<sale id>`, and personal
  notices on `user:<id>`.
  """

  import Ecto.Query
  alias Umber.{Repo, Events}
  alias Umber.Accounts.User
  alias Umber.Catalogue.{Lot, Work}

  @doc "The public state of a lot, small enough for every screen to receive."
  def lot_event(%Lot{} = lot, last \\ []) do
    %{
      id: lot.id,
      sale_id: lot.sale_id,
      number: lot.number,
      status: lot.status,
      current_bid: lot.current_bid,
      leader_id: lot.leader_id,
      leader_paddle: paddle(lot.leader_id),
      bid_count: lot.bid_count,
      closes_at: lot.closes_at,
      extensions: lot.extensions,
      hammer: lot.hammer,
      reserve_met: Lot.reserve_met?(lot),
      version: lot.version,
      last: last,
      now: DateTime.utc_now()
    }
  end

  def timed_bid(%{lot: lot} = change) do
    paddles = paddles(Enum.map(change.entries, &elem(&1, 0)))

    last =
      Enum.map(change.entries, fn {uid, amount, kind} ->
        %{amount: amount, paddle: paddles[uid], user_id: uid, kind: kind, source: "online"}
      end)

    event = lot_event(lot, last)
    notices = outbid_notice(lot, change.previous_leader_id)

    Events.broadcast_many([{"lot:#{lot.id}", {:lot, event}}, {"sale:#{lot.sale_id}", {:lot, event}} | notices])
  end

  def timed_close(%{lot: lot, invoice: invoice}) do
    event = lot_event(lot)
    won = if invoice, do: [{"user:#{invoice.user_id}", {:notice, notice(lot, "won", lot.hammer)}}], else: []
    Events.broadcast_many([{"lot:#{lot.id}", {:lot, event}}, {"sale:#{lot.sale_id}", {:lot, event}} | won])
  end

  @doc "A live sale's state, for the live room, the rostrum and the catalogue."
  def live(%Umber.Auctions.LiveSession{} = s, extra \\ %{}) do
    event =
      Map.merge(
        %{
          sale_id: s.sale_id,
          state: s.state,
          lot_id: s.lot_id,
          asking: s.asking,
          current_bid: s.current_bid,
          leader_id: s.leader_id,
          leader_paddle: paddle(s.leader_id),
          leader_source: s.leader_source,
          call: s.call,
          called_at: s.called_at,
          auctioneer_id: s.auctioneer_id,
          version: s.version,
          now: DateTime.utc_now()
        },
        extra
      )

    Events.broadcast("live:#{s.sale_id}", {:live, event})
  end

  def live_lot(%Lot{} = lot, previous_leader_id \\ nil) do
    event = lot_event(lot)
    notices = if previous_leader_id, do: outbid_notice(lot, previous_leader_id), else: []
    Events.broadcast_many([{"lot:#{lot.id}", {:lot, event}}, {"sale:#{lot.sale_id}", {:lot, event}} | notices])
  end

  def won(%{lot: lot, invoice: %{user_id: uid}}), do: Events.broadcast("user:#{uid}", {:notice, notice(lot, "won", lot.hammer)})
  def won(_), do: :ok

  def notice_user(user_id, kind, lot, amount), do: Events.broadcast("user:#{user_id}", {:notice, notice(lot, kind, amount)})

  defp outbid_notice(%Lot{leader_id: leader} = lot, previous) when is_integer(previous) and previous != leader do
    if bidder?(previous), do: [{"user:#{previous}", {:notice, notice(lot, "outbid", lot.current_bid)}}], else: []
  end

  defp outbid_notice(_, _), do: []

  @doc "A notice about a lot for one bidder."
  def notice(%Lot{} = lot, kind, amount) do
    %{title: title, sale_number: sale_number} = lot_names(lot)

    %{
      id: System.unique_integer([:positive]),
      kind: kind,
      lot_id: lot.id,
      title: title,
      lot_number: lot.number,
      amount: amount,
      path: "/sales/#{sale_number}/lots/#{lot.number}"
    }
  end

  defp lot_names(lot) do
    from(l in Lot, join: w in Work, on: w.id == l.work_id, join: s in assoc(l, :sale), where: l.id == ^lot.id, select: %{title: w.title, sale_number: s.number})
    |> Repo.one!()
  end

  defp bidder?(user_id), do: Repo.exists?(from u in User, where: u.id == ^user_id and u.kind == "bidder")

  defp paddle(nil), do: nil
  defp paddle(user_id), do: Repo.one(from u in User, where: u.id == ^user_id, select: u.paddle)

  defp paddles(ids), do: from(u in User, where: u.id in ^Enum.uniq(ids), select: {u.id, u.paddle}) |> Repo.all() |> Map.new()
end
