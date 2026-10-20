defmodule Umber.Auctions.TimedTest do
  use Umber.DataCase, async: true

  import Umber.Fixtures
  alias Umber.Repo
  alias Umber.Catalogue.Lot
  alias Umber.Auctions.{Timed, Bid, Invoice}

  describe "placing bids" do
    test "a one-tap bid at the opening price is accepted and recorded" do
      lot = lot()
      user = bidder()

      assert {:ok, change} = Timed.place(lot.id, user, :bid, 100_000)
      assert change.leading
      assert change.lot.current_bid == 100_000
      assert change.lot.leader_id == user.id
      assert change.lot.bid_count == 1
      assert change.lot.version == lot.version + 1
      assert [%Bid{amount: 100_000, kind: "bid", user_id: uid}] = Repo.all(Bid)
      assert uid == user.id
    end

    test "a bid at a price the screen no longer shows is refused" do
      lot = lot()
      assert {:ok, _} = Timed.place(lot.id, bidder(), :bid, 100_000)
      assert Timed.place(lot.id, bidder(), :bid, 100_000) == {:error, :price_moved}
    end

    test "a maximum must be on the step grid and above the next bid" do
      lot = lot()
      assert Timed.place(lot.id, bidder(), :max, 123_456) == {:error, :off_step}
      assert Timed.place(lot.id, bidder(), :max, 90_000) == {:error, {:too_low, 100_000}}
    end

    test "a bidder cannot go over their bidding limit" do
      lot = lot()
      user = bidder()
      {:ok, user} = Umber.Accounts.set_bid_limit(user, 150_000)
      assert Timed.place(lot.id, user, :max, 200_000) == {:error, {:over_limit, 150_000}}
    end

    test "staff cannot bid" do
      assert Timed.place(lot().id, staff(), :bid, 100_000) == {:error, :staff}
    end

    test "a closed, unopened or past-time lot refuses bids" do
      assert Timed.place(lot(%{status: "pending"}).id, bidder(), :bid, 100_000) ==
               {:error, :not_open}

      assert Timed.place(lot(%{status: "sold"}).id, bidder(), :bid, 100_000) == {:error, :closed}

      past = lot(%{closes_at: DateTime.add(DateTime.utc_now(), -1, :second)})
      assert Timed.place(past.id, bidder(), :bid, 100_000) == {:error, :closed}
    end

    test "the previous leader is reported so they can be told they were outbid" do
      lot = lot()
      first = bidder()
      second = bidder()
      {:ok, _} = Timed.place(lot.id, first, :bid, 100_000)
      assert {:ok, change} = Timed.place(lot.id, second, :bid, 110_000)
      assert change.previous_leader_id == first.id
      assert change.lot.leader_id == second.id
    end
  end

  describe "soft close" do
    test "a bid in the last two minutes moves the close to two minutes after it" do
      now = DateTime.utc_now()
      lot = lot(%{closes_at: DateTime.add(now, 30, :second)})

      assert {:ok, change} = Timed.place(lot.id, bidder(), :bid, 100_000, now)
      assert change.extended
      assert change.lot.extensions == 1
      assert DateTime.diff(change.lot.closes_at, now, :second) == 120
    end

    test "a bid earlier than that leaves the close alone" do
      now = DateTime.utc_now()
      closes = DateTime.add(now, 600, :second)
      lot = lot(%{closes_at: closes})

      assert {:ok, change} = Timed.place(lot.id, bidder(), :bid, 100_000, now)
      refute change.extended
      assert change.lot.closes_at == closes
    end

    test "raising your own maximum, which changes nothing, does not extend" do
      now = DateTime.utc_now()
      lot = lot(%{closes_at: DateTime.add(now, 30, :second), reserve: 1_000_000})
      user = bidder()
      {:ok, _} = Timed.place(lot.id, user, :max, 150_000, DateTime.add(now, -600, :second))
      assert {:ok, change} = Timed.place(lot.id, user, :max, 200_000, now)
      refute change.extended
    end
  end

  describe "closing" do
    test "a lot that met its reserve is sold, with an invoice for premium and VAT" do
      lot = lot(%{closes_at: DateTime.add(DateTime.utc_now(), 3600, :second)})
      user = bidder()
      {:ok, _} = Timed.place(lot.id, user, :max, 200_000)

      later = DateTime.add(DateTime.utc_now(), 3601, :second)
      assert {:ok, %{lot: closed, invoice: invoice}} = Timed.close(lot.id, later)
      assert closed.status == "sold"
      assert closed.hammer == 170_000
      assert closed.buyer_id == user.id

      assert %Invoice{hammer: 170_000, premium: 34_000, vat: 5_440, total: 209_440, status: "due"} =
               invoice
    end

    test "a lot below its reserve is unsold, with no invoice" do
      lot = lot()
      {:ok, _} = Timed.place(lot.id, bidder(), :bid, 100_000)
      later = DateTime.add(DateTime.utc_now(), 3601, :second)

      assert {:ok, %{lot: %Lot{status: "unsold", hammer: nil}, invoice: nil}} =
               Timed.close(lot.id, later)

      assert Repo.aggregate(Invoice, :count) == 0
    end

    test "closing early is refused, and closing twice closes once" do
      lot = lot()
      assert Timed.close(lot.id) == {:error, :not_due}
      later = DateTime.add(DateTime.utc_now(), 3601, :second)
      assert {:ok, %{lot: _}} = Timed.close(lot.id, later)
      assert Timed.close(lot.id, later) == {:ok, :already_closed}
    end
  end

  describe "the amounts offered for a maximum" do
    test "start at the next bid for a bidder who has not left one" do
      assert hd(Umber.Auctions.max_choices(lot(), bidder())) == 100_000
    end

    test "start above the bidder's own maximum, since a maximum can only be raised" do
      lot = lot()
      user = bidder()
      assert {:ok, _} = Timed.place(lot.id, user, :max, 150_000)

      choices = Umber.Auctions.max_choices(Repo.get!(Lot, lot.id), user)
      assert hd(choices) == 160_000
      assert Enum.all?(choices, &(&1 > 150_000))
    end
  end
end
