defmodule Umber.Auctions.LiveTest do
  use Umber.DataCase, async: true

  import Umber.Fixtures
  alias Umber.Auctions.{Live, Invoice}
  alias Umber.Repo

  setup do
    sale = sale(%{format: "live", status: "live", starts_at: DateTime.utc_now()})

    lot =
      lot(%{
        sale: sale,
        status: "pending",
        reserve: 150_000,
        opening_bid: 100_000,
        closes_at: nil
      })

    Live.ensure(sale.id)
    {:ok, sale: sale, lot: lot}
  end

  test "a lot opens at its asking price and takes an online bid", %{sale: sale, lot: lot} do
    assert {:ok, %{session: s}} = Live.open_lot(sale.id, lot.id, 100_000)
    assert s.state == "open"
    assert s.asking == 100_000

    user = bidder()
    assert {:ok, %{session: s}} = Live.bid(sale.id, user, 100_000)
    assert s.current_bid == 100_000
    assert s.leader_id == user.id
    assert s.leader_source == "online"
    assert s.asking == 110_000
    assert s.call == "KES 100,000, online."
  end

  test "a bid at an asking price that has moved is refused with the new one", %{
    sale: sale,
    lot: lot
  } do
    {:ok, _} = Live.open_lot(sale.id, lot.id, 100_000)
    {:ok, _} = Live.floor_bid(sale.id, sample_bidder().id)
    assert Live.bid(sale.id, bidder(), 100_000) == {:error, {:asking_moved, 110_000}}
  end

  test "the leader cannot bid against themselves, and staff cannot bid", %{sale: sale, lot: lot} do
    {:ok, _} = Live.open_lot(sale.id, lot.id, 100_000)
    user = bidder()
    {:ok, _} = Live.bid(sale.id, user, 100_000)
    assert Live.bid(sale.id, user, 110_000) == {:error, :already_leading}
    assert Live.bid(sale.id, staff(), 110_000) == {:error, :staff}
  end

  test "absentee maximums are bid from the book while they last", %{sale: sale, lot: lot} do
    absentee = bidder()
    assert {:ok, _} = Live.leave_absentee(lot, absentee, 130_000)
    {:ok, _} = Live.open_lot(sale.id, lot.id, 100_000)

    assert {:ok, %{session: s}} = Live.book_bid(sale.id)
    assert s.leader_id == absentee.id and s.leader_source == "absentee"

    {:ok, _} = Live.floor_bid(sale.id, sample_bidder().id)
    assert {:ok, %{session: s}} = Live.book_bid(sale.id)
    assert s.current_bid == 120_000

    {:ok, _} = Live.floor_bid(sale.id, sample_bidder().id)
    # The asking price is now above the absentee's maximum.
    assert Live.book_bid(sale.id) == {:error, :no_book_bid}
  end

  test "the hammer sells above the reserve and invoices a real bidder", %{sale: sale, lot: lot} do
    {:ok, _} = Live.open_lot(sale.id, lot.id, 150_000)
    user = bidder()
    {:ok, _} = Live.bid(sale.id, user, 150_000)
    {:ok, _} = Live.warn(sale.id)

    assert {:ok, %{session: s, result: %{lot: sold, invoice: %Invoice{}}}} = Live.hammer(sale.id)
    assert s.state == "sold"
    assert s.call == "Sold, for KES 150,000, online."
    assert sold.status == "sold" and sold.buyer_id == user.id
  end

  test "below the reserve the lot is passed", %{sale: sale, lot: lot} do
    {:ok, _} = Live.open_lot(sale.id, lot.id, 100_000)
    {:ok, _} = Live.bid(sale.id, bidder(), 100_000)

    assert {:ok, %{session: %{state: "passed", call: "Passed, at KES 100,000."}}} =
             Live.hammer(sale.id)

    assert Repo.aggregate(Invoice, :count) == 0
  end

  test "only one member of staff holds the rostrum at a time", %{sale: sale} do
    a = staff()
    b = staff()
    assert {:ok, _} = Live.take_rostrum(sale.id, a)
    assert Live.take_rostrum(sale.id, b) == {:error, :rostrum_taken}
    assert {:ok, _} = Live.leave_rostrum(sale.id, a)
    assert {:ok, %{session: s}} = Live.take_rostrum(sale.id, b)
    assert Live.staffed?(s, DateTime.utc_now())
  end

  test "a rostrum left quiet past the grace period counts as unstaffed", %{sale: sale} do
    a = staff()
    {:ok, %{session: s}} = Live.take_rostrum(sale.id, a)
    later = DateTime.add(DateTime.utc_now(), Live.rostrum_grace() + 1, :second)
    refute Live.staffed?(s, later)
    assert {:ok, _} = Live.take_rostrum(sale.id, staff(), later)
  end
end
