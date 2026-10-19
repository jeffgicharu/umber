defmodule Umber.Market.Scheduler do
  @moduledoc """
  Keeps the running sales going, every two seconds, on the copy that holds the
  market lease: creates each next cycle, opens timed sales on time, makes sure
  every open lot has its process and closing timer, starts the auctioneer for a
  live session, closes sales when their last lot is done, and tells watchers
  when a lot they follow has five minutes left.
  """

  use GenServer
  require Logger
  import Ecto.Query

  alias Umber.{Repo, Catalogue, Events}
  alias Umber.Catalogue.{Sale, Lot}
  alias Umber.Auctions.{LotServer, Broadcasts}
  alias Umber.Market.{Schedule, Auctioneer}

  @tick 2_000
  @watch_notice 300

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    send(self(), :tick)

    {:ok,
     %{
       templates: Catalogue.templates() |> Map.new(&{&1["key"], &1}),
       noticed: MapSet.new(),
       ticked: System.monotonic_time(:millisecond)
     }}
  end

  # The lease asks this on every renewal; a scheduler that cannot answer is restarted.
  @impl true
  def handle_call(:last_tick_age, _from, state),
    do: {:reply, System.monotonic_time(:millisecond) - state.ticked, state}

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick)
    now = DateTime.utc_now()

    state =
      if Umber.Market.Lease.held?() do
        try do
          ensure_cycles(state, now)
          open_due_sales(now)
          tend_open_lots()
          start_live_sessions(now)
          close_finished_sales(now)
          state = notice_watchers(state, now)
          clean_up(state, now)
        rescue
          e ->
            Logger.error("market tick failed: " <> Exception.format(:error, e, __STACKTRACE__))
            state
        end
      else
        stop_auctioneers()
        state
      end

    {:noreply, %{state | ticked: System.monotonic_time(:millisecond)}}
  end

  @clean_every 600

  defp clean_up(state, now) do
    last = Map.get(state, :cleaned)

    if is_nil(last) or DateTime.diff(now, last, :second) >= @clean_every do
      Umber.Market.Cleanup.run(now)
      Map.put(state, :cleaned, now)
    else
      state
    end
  end

  # Another copy holds the market now; its auctioneers run there.
  defp stop_auctioneers do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Umber.Market.AuctioneerSupervisor) do
      DynamicSupervisor.terminate_child(Umber.Market.AuctioneerSupervisor, pid)
    end
  end

  defp ensure_cycles(state, now) do
    for {key, t} <- state.templates do
      case t["format"] do
        "live" ->
          at = Schedule.next_live(now)

          unless Repo.exists?(from s in Sale, where: s.template == ^key and s.starts_at == ^at) do
            {:ok, sale} = Catalogue.create_cycle(t, %{starts_at: at})
            Logger.info("created live session #{sale.number} for #{Umber.Format.clock(at)}")
            Events.broadcast("market", :sales_changed)
          end

        "timed" ->
          active? =
            Repo.exists?(
              from s in Sale, where: s.template == ^key and s.status in ["upcoming", "open"]
            )

          unless active? do
            {:ok, sale} = Catalogue.create_cycle(t, Schedule.next_timed(key, now))
            Logger.info("created #{key} cycle #{sale.number}")
            Events.broadcast("market", :sales_changed)
          end
      end
    end

    state
  end

  defp open_due_sales(now) do
    due =
      from(s in Sale,
        where: s.format == "timed" and s.status == "upcoming" and s.opens_at <= ^now
      )
      |> Repo.all()

    for sale <- due do
      Repo.transaction(fn ->
        from(l in Lot, where: l.sale_id == ^sale.id and l.status == "pending")
        |> Repo.update_all(set: [status: "open", updated_at: now], inc: [version: 1])

        from(s in Sale, where: s.id == ^sale.id)
        |> Repo.update_all(set: [status: "open", updated_at: now])
      end)

      Logger.info("opened sale #{sale.number}")
      Events.broadcast("sale:#{sale.id}", :sale_changed)
      Events.broadcast("market", :sales_changed)
    end
  end

  defp tend_open_lots do
    from(l in Lot,
      join: s in assoc(l, :sale),
      where: l.status == "open" and s.format == "timed",
      select: l.id
    )
    |> Repo.all()
    |> Enum.each(fn id -> unless LotServer.running?(id), do: LotServer.ensure(id) end)
  end

  defp start_live_sessions(now) do
    due =
      from(s in Sale,
        where: s.format == "live" and s.status == "upcoming" and s.starts_at <= ^now
      )
      |> Repo.all()

    for sale <- due do
      from(s in Sale, where: s.id == ^sale.id)
      |> Repo.update_all(set: [status: "live", updated_at: now])

      Events.broadcast("sale:#{sale.id}", :sale_changed)
      Events.broadcast("market", :sales_changed)
    end

    live =
      from(s in Sale, where: s.format == "live" and s.status == "live", select: s.id)
      |> Repo.all()

    Enum.each(live, &Auctioneer.ensure/1)
  end

  defp close_finished_sales(now) do
    unfinished =
      from(l in Lot,
        where: l.sale_id == parent_as(:sale).id and l.status in ["pending", "open"],
        select: 1
      )

    finished =
      from(s in Sale,
        as: :sale,
        where: s.format == "timed" and s.status == "open",
        where: not exists(subquery(unfinished)),
        select: s.id
      )

    for id <- Repo.all(finished) do
      from(s in Sale, where: s.id == ^id)
      |> Repo.update_all(set: [status: "closed", ended_at: now, updated_at: now])

      Events.broadcast("sale:#{id}", :sale_changed)
      Events.broadcast("market", :sales_changed)
    end
  end

  defp notice_watchers(state, now) do
    soon = DateTime.add(now, @watch_notice, :second)

    rows =
      from(w in "watches",
        join: l in Lot,
        on: l.id == w.lot_id,
        where: l.status == "open" and l.closes_at <= ^soon and l.closes_at > ^now,
        select: {w.user_id, l.id}
      )
      |> Repo.all()
      |> Enum.reject(&MapSet.member?(state.noticed, &1))

    for {uid, lot_id} <- rows do
      lot = Repo.get!(Lot, lot_id)
      Broadcasts.notice_user(uid, "closing", lot, lot.current_bid)
    end

    # Forget lots that have closed, so the set stays small.
    open_ids =
      from(l in Lot, where: l.status == "open", select: l.id) |> Repo.all() |> MapSet.new()

    noticed =
      state.noticed
      |> MapSet.union(MapSet.new(rows))
      |> MapSet.filter(fn {_, lot_id} -> lot_id in open_ids end)

    %{state | noticed: noticed}
  end
end
