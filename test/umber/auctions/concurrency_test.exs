defmodule Umber.Auctions.ConcurrencyTest do
  # Real transactions committed from many processes at once, outside the
  # sandbox, so the row lock is what keeps order, as it is in production.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Umber.Fixtures
  alias Umber.Repo
  alias Umber.Catalogue.{Lot, Sale, Work, Artist}
  alias Umber.Accounts.User
  alias Umber.Auctions.{Timed, LotServer, MaxBid, Bid, Increments}

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
      Repo.delete_all(from(b in Bid))
      Repo.delete_all(from(m in MaxBid))
      Repo.delete_all(from(i in Umber.Auctions.Invoice))
      Repo.delete_all(from(l in Lot))
      Repo.delete_all(from(s in Sale))
      Repo.delete_all(from(w in Work))
      Repo.delete_all(from(a in Artist))
      Repo.delete_all(from(u in User))
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  test "forty bidders at once: one leader, the right price, every bid counted" do
    lot = lot(%{reserve: 150_000})
    bidders = for _ <- 1..40, do: bidder(%{})
    Enum.each(bidders, &Umber.Accounts.set_bid_limit(&1, 10_000_000))

    # Half through the lot's process, half straight to the database, as the
    # other copy of the app would during a release.
    results =
      bidders
      |> Enum.with_index()
      |> Task.async_stream(
        fn {user, i} ->
          amount = Increments.round_down(100_000 + :rand.uniform(1_500_000))

          if rem(i, 2) == 0,
            do: LotServer.bid(lot.id, user, :max, amount),
            else: Timed.place(lot.id, user, :max, amount)
        end,
        max_concurrency: 40,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    accepted = Enum.count(results, &match?({:ok, _}, &1))
    final = Repo.get!(Lot, lot.id)

    maxes =
      from(m in MaxBid,
        where: m.lot_id == ^lot.id,
        order_by: [desc: m.amount, asc: m.inserted_at, asc: m.id]
      )
      |> Repo.all()

    assert accepted >= 1
    assert final.version == lot.version + accepted
    assert final.bid_count == Repo.aggregate(from(b in Bid, where: b.lot_id == ^lot.id), :count)

    [top | rest] = maxes
    assert final.leader_id == top.user_id

    expected =
      case rest do
        [] ->
          max(lot.opening_bid, if(top.amount >= lot.reserve, do: lot.reserve, else: 0))

        [second | _] when second.amount == top.amount ->
          top.amount

        [second | _] ->
          min(top.amount, second.amount + Increments.step(second.amount))
          |> max(if(top.amount >= lot.reserve, do: lot.reserve, else: 0))
      end

    assert final.current_bid == expected

    # In the order they were recorded, bid amounts never go down.
    amounts =
      from(b in Bid,
        where: b.lot_id == ^lot.id,
        order_by: [asc: b.inserted_at, asc: b.id],
        select: b.amount
      )
      |> Repo.all()

    assert amounts == Enum.sort(amounts)
    assert List.last(amounts) == final.current_bid
  end

  test "a lot closes exactly once when every copy's timer fires together" do
    lot = lot(%{closes_at: DateTime.add(DateTime.utc_now(), 3600, :second)})
    {:ok, _} = Timed.place(lot.id, bidder(%{}), :max, 300_000)
    later = DateTime.add(DateTime.utc_now(), 3601, :second)

    results =
      1..20
      |> Task.async_stream(fn _ -> Timed.close(lot.id, later) end, max_concurrency: 20)
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.count(results, &match?({:ok, %{lot: _}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:ok, :already_closed})) == 19
    assert Repo.aggregate(Umber.Auctions.Invoice, :count) == 1
  end

  test "a crashed lot process comes back and keeps every accepted bid" do
    lot = lot()
    a = bidder(%{})
    b = bidder(%{})
    {:ok, _} = LotServer.bid(lot.id, a, :bid, 100_000)
    [{pid, _}] = Registry.lookup(Umber.Auctions.LotRegistry, lot.id)

    Process.exit(pid, :kill)

    wait_until(fn ->
      match?([{p, _}] when p != pid, Registry.lookup(Umber.Auctions.LotRegistry, lot.id))
    end)

    {:ok, change} = LotServer.bid(lot.id, b, :bid, 110_000)
    assert change.lot.current_bid == 110_000
    assert change.previous_leader_id == a.id
    assert Repo.aggregate(from(x in Bid, where: x.lot_id == ^lot.id), :count) == 2
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end
end
