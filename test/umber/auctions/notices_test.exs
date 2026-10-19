defmodule Umber.Auctions.NoticesTest do
  use Umber.DataCase, async: false

  import Umber.Fixtures
  alias Umber.Auctions.{Timed, Broadcasts}

  test "the bidder who loses the lead is told, with the new price" do
    lot = lot(%{reserve: 1_000_000})
    first = bidder()
    second = bidder()
    Umber.Events.subscribe("user:#{first.id}")

    {:ok, change} = Timed.place(lot.id, first, :bid, 100_000)
    Broadcasts.timed_bid(change)
    refute_receive {:notice, _}, 100

    {:ok, change} = Timed.place(lot.id, second, :bid, 110_000)
    Broadcasts.timed_bid(change)
    assert_receive {:notice, %{kind: "outbid", amount: 110_000, lot_number: n}}, 500
    assert n == lot.number
  end

  test "a lot event carries its buyer, so the winner's page can show the invoice" do
    lot = lot(%{closes_at: DateTime.add(DateTime.utc_now(), 3600, :second)})
    buyer = bidder()
    {:ok, _} = Timed.place(lot.id, buyer, :max, 200_000)
    {:ok, change} = Timed.close(lot.id, DateTime.add(DateTime.utc_now(), 3601, :second))
    assert Broadcasts.lot_event(change.lot).buyer_id == buyer.id
  end
end
