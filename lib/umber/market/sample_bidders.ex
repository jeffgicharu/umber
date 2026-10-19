defmodule Umber.Market.SampleBidders do
  @moduledoc """
  The house's sample bidders on timed lots. Each lot has a hidden market value
  chosen when its sale was made; sample bidders never go above it. They bid
  rarely while a lot has a long time to run and more often near its close,
  and they answer a visitor's bid sooner than each other's. A visitor who goes
  above the market value wins the lot.

  Their bids go through the same lot processes and rules as anyone's.
  """

  use GenServer
  require Logger
  import Ecto.Query

  alias Umber.Repo
  alias Umber.Accounts.User
  alias Umber.Catalogue.Lot
  alias Umber.Auctions.{Increments, LotServer}

  @tick 1_500

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    send(self(), :tick)
    {:ok, %{bots: nil}}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick)
    state = %{state | bots: state.bots || load_bots()}

    if state.bots != [] do
      try do
        now = DateTime.utc_now()
        Enum.each(open_lots(), &maybe_bid(&1, state.bots, now))
      rescue
        e -> Logger.error("sample bidders: " <> Exception.message(e))
      end
    end

    {:noreply, state}
  end

  defp load_bots, do: from(u in User, where: u.kind == "sample") |> Repo.all()

  defp open_lots do
    from(l in Lot,
      join: s in assoc(l, :sale),
      left_join: u in assoc(l, :leader),
      where: l.status == "open" and s.format == "timed" and s.status == "open",
      select: %{
        id: l.id,
        current: l.current_bid,
        opening: l.opening_bid,
        value: l.market_value,
        closes_at: l.closes_at,
        leader_id: l.leader_id,
        leader_kind: u.kind
      }
    )
    |> Repo.all()
  end

  defp maybe_bid(lot, bots, now) do
    next = Increments.next(lot.current, lot.opening)
    left = DateTime.diff(lot.closes_at, now, :second)

    if next <= lot.value and left > 1 and :rand.uniform() < chance(lot.leader_kind, left) do
      bot = bots |> Enum.reject(&(&1.id == lot.leader_id)) |> Enum.random()
      LotServer.bid(lot.id, bot, :bid, next)
    end
  end

  # Per tick of 1.5 seconds.
  defp chance(leader, left) do
    cond do
      left > 900 -> %{nil => 0.003, "bidder" => 0.02}[leader] || 0.001
      left > 120 -> %{nil => 0.02, "bidder" => 0.08}[leader] || 0.012
      true -> %{nil => 0.10, "bidder" => 0.30}[leader] || 0.07
    end
  end
end
