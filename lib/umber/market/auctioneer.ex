defmodule Umber.Market.Auctioneer do
  @moduledoc """
  The automatic auctioneer for one live session. It takes the lots in order,
  asks for an opening bid, lets the room and the book bid, gives fair warning
  after a few quiet seconds and brings the hammer down.

  When a member of staff holds the rostrum it only watches. If their console
  goes quiet for longer than the grace period, it picks the sale up where they
  left it.

  It decides everything from the session row, which every change rewrites, so
  a restarted auctioneer, or one on the other copy of the app after a switch,
  carries on from exactly the same place.
  """

  use GenServer, restart: :transient
  require Logger
  import Ecto.Query

  alias Umber.Repo
  alias Umber.Accounts.User
  alias Umber.Catalogue.{Lot, Sale}
  alias Umber.Auctions.{Live, Increments, Broadcasts, LiveSession}

  @registry Umber.Market.AuctioneerRegistry
  @supervisor Umber.Market.AuctioneerSupervisor
  @tick 1_000

  # Seconds of quiet before each step.
  @first_lot 4
  @room_bid 1.6
  @no_opening 7
  @warning 6
  @hammer 4
  @between_lots 5

  def start_link(sale_id),
    do: GenServer.start_link(__MODULE__, sale_id, name: {:via, Registry, {@registry, sale_id}})

  def ensure(sale_id) do
    case Registry.lookup(@registry, sale_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> DynamicSupervisor.start_child(@supervisor, {__MODULE__, sale_id})
    end
  end

  @impl true
  def init(sale_id) do
    Live.ensure(sale_id)
    send(self(), :tick)

    {:ok,
     %{
       sale_id: sale_id,
       drops: 0,
       bots: from(u in User, where: u.kind == "sample", select: u.id) |> Repo.all()
     }}
  end

  @impl true
  def handle_info(:tick, state) do
    now = DateTime.utc_now()
    session = Live.get(state.sale_id)

    state =
      try do
        if Live.staffed?(session, now),
          do: state,
          else: step(session, quiet(session, now), now, state)
      rescue
        e ->
          Logger.error(
            "auctioneer #{state.sale_id}: " <> Exception.format(:error, e, __STACKTRACE__)
          )

          state
      end

    if Live.get(state.sale_id).state == "ended" do
      {:stop, :normal, state}
    else
      Process.send_after(self(), :tick, @tick)
      {:noreply, state}
    end
  end

  defp quiet(%LiveSession{called_at: nil}, _now), do: 999
  defp quiet(%LiveSession{called_at: at}, now), do: DateTime.diff(now, at, :millisecond) / 1000

  # Waiting for the first lot: a welcome, then the first lot a few seconds later.
  defp step(%{state: "waiting", called_at: nil}, _quiet, _now, state) do
    {:ok, %{session: s}} = touch(state.sale_id, "Welcome to the sale. We begin in a moment.")
    Broadcasts.live(s)
    state
  end

  defp step(%{state: "waiting"}, quiet, now, state) when quiet >= @first_lot do
    open_next(state, now)
  end

  # A lot is on the block and taking bids.
  defp step(%{state: "open"} = s, quiet, now, state) do
    lot = Repo.get!(Lot, s.lot_id)

    cond do
      quiet >= @room_bid and Live.book_candidate(s) ->
        commit(Live.book_bid(state.sale_id), s.leader_id)
        state

      quiet >= @room_bid and s.asking <= lot.market_value and
          :rand.uniform() < room_chance(s.asking, lot.market_value) ->
        bidder = state.bots |> Enum.reject(&(&1 == s.leader_id)) |> Enum.random()
        commit(Live.floor_bid(state.sale_id, bidder), s.leader_id)
        state

      is_nil(s.current_bid) and quiet >= @no_opening and state.drops < 2 ->
        commit(Live.set_asking(state.sale_id, Increments.previous(s.asking)), nil)
        %{state | drops: state.drops + 1}

      is_nil(s.current_bid) and quiet >= @no_opening ->
        hammer(state, now)

      not is_nil(s.current_bid) and quiet >= @warning ->
        commit(Live.warn(state.sale_id), nil)
        state

      true ->
        state
    end
  end

  defp step(%{state: "warning"} = s, quiet, now, state) do
    lot = Repo.get!(Lot, s.lot_id)

    cond do
      # A last bid from the book or the room can still come during fair warning.
      quiet >= @room_bid and Live.book_candidate(s) ->
        commit(Live.book_bid(state.sale_id), s.leader_id)
        state

      quiet >= @room_bid and quiet < @hammer and s.asking <= lot.market_value and
          :rand.uniform() < room_chance(s.asking, lot.market_value) * 0.5 ->
        bidder = state.bots |> Enum.reject(&(&1 == s.leader_id)) |> Enum.random()
        commit(Live.floor_bid(state.sale_id, bidder), s.leader_id)
        state

      quiet >= @hammer ->
        hammer(state, now)

      true ->
        state
    end
  end

  defp step(%{state: st}, quiet, now, state)
       when st in ["sold", "passed"] and quiet >= @between_lots do
    open_next(state, now)
  end

  defp step(%{state: "paused"}, _quiet, _now, state) do
    commit(Live.resume(state.sale_id), nil)
    state
  end

  defp step(_session, _quiet, _now, state), do: state

  # Bidding comes quickly at first and thins out as the price nears what the room will pay.
  defp room_chance(asking, value) do
    r = asking / max(value, 1)

    cond do
      r < 0.6 -> 0.55
      r < 0.85 -> 0.38
      true -> 0.22
    end
  end

  defp open_next(state, now) do
    next =
      from(l in Lot,
        where: l.sale_id == ^state.sale_id and l.status == "pending",
        order_by: l.number,
        limit: 1
      )
      |> Repo.one()

    case next do
      nil ->
        {:ok, %{session: s}} = Live.finish_sale(state.sale_id)

        from(x in Sale, where: x.id == ^state.sale_id)
        |> Repo.update_all(set: [status: "closed", ended_at: now, updated_at: now])

        Broadcasts.live(s)
        Umber.Events.broadcast("sale:#{state.sale_id}", :sale_changed)
        Umber.Events.broadcast("market", :sales_changed)
        state

      lot ->
        commit(Live.open_lot(state.sale_id, lot.id, lot.opening_bid), nil)
        %{state | drops: 0}
    end
  end

  defp hammer(state, _now) do
    case Live.hammer(state.sale_id) do
      {:ok, %{session: s, result: result}} ->
        Broadcasts.live(s)
        Broadcasts.live_lot(result.lot)
        Broadcasts.won(result)

      {:error, _} ->
        :ok
    end

    state
  end

  defp commit({:ok, %{session: s}}, previous_leader) do
    Broadcasts.live(s)
    if s.lot_id, do: Broadcasts.live_lot(Repo.get!(Lot, s.lot_id), previous_leader)
  end

  defp commit({:error, _}, _), do: :ok

  defp touch(sale_id, call) do
    Repo.transaction(fn ->
      s = from(x in LiveSession, where: x.sale_id == ^sale_id, lock: "FOR UPDATE") |> Repo.one!()
      now = DateTime.utc_now()

      %{
        session:
          s
          |> Ecto.Changeset.change(
            call: call,
            called_at: now,
            version: s.version + 1,
            updated_at: now
          )
          |> Repo.update!()
      }
    end)
  end
end
