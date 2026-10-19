defmodule Umber.Auctions.ProxyTest do
  use ExUnit.Case, async: true

  alias Umber.Auctions.{Proxy, Increments}

  @lot %{current_bid: nil, leader_id: nil, opening_bid: 100_000, reserve: 170_000}

  defp max(user, amount, at), do: %{user_id: user, amount: amount, at: at}

  describe "increments" do
    test "steps follow the table" do
      assert Increments.step(10_000) == 2_500
      assert Increments.step(49_999) == 2_500
      assert Increments.step(50_000) == 5_000
      assert Increments.step(199_999) == 10_000
      assert Increments.step(200_000) == 20_000
      assert Increments.step(1_000_000) == 100_000
      assert Increments.step(4_999_999) == 200_000
      assert Increments.step(5_000_000) == 500_000
    end

    test "the next bid is the opening bid, then the current bid plus its step" do
      assert Increments.next(nil, 100_000) == 100_000
      assert Increments.next(100_000, 100_000) == 110_000
      assert Increments.next(480_000, 0) == 500_000
    end

    test "round_down snaps to the grid" do
      assert Increments.round_down(123_456) == 120_000
      assert Increments.round_down(1_234_567) == 1_200_000
      assert Increments.round_down(47_600) == 47_500
    end
  end

  describe "the first bid" do
    test "a one-tap bid at the opening price leads at the opening price" do
      assert {:ok, r} = Proxy.resolve(@lot, [], %{user_id: 1, amount: 100_000, at: 0, kind: :bid})
      assert r.price == 100_000
      assert r.leader_id == 1
      assert r.entries == [{1, 100_000, "bid"}]
    end

    test "a maximum below the reserve leads at the opening price" do
      assert {:ok, r} = Proxy.resolve(@lot, [], %{user_id: 1, amount: 150_000, at: 0, kind: :max})
      assert r.price == 100_000
      assert r.max.amount == 150_000
    end

    test "a maximum at or above the reserve jumps the price to the reserve" do
      assert {:ok, r} = Proxy.resolve(@lot, [], %{user_id: 1, amount: 400_000, at: 0, kind: :max})
      assert r.price == 170_000
      assert r.entries == [{1, 170_000, "proxy"}]
    end

    test "below the opening bid is refused with the lowest acceptable amount" do
      assert Proxy.resolve(@lot, [], %{user_id: 1, amount: 90_000, at: 0, kind: :max}) == {:error, {:too_low, 100_000}}
    end
  end

  describe "against a maximum" do
    setup do
      # A reserve above every maximum here, so only the maximums set the price.
      lot = %{@lot | current_bid: 100_000, leader_id: 1, reserve: 1_000_000}
      {:ok, lot: lot, maxes: [max(1, 300_000, 0)]}
    end

    test "a lower bid is answered by the leader's maximum, one step above it", %{lot: lot, maxes: maxes} do
      assert {:ok, r} = Proxy.resolve(lot, maxes, %{user_id: 2, amount: 110_000, at: 1, kind: :bid})
      assert r.leader_id == 1
      assert r.price == 120_000
      assert r.entries == [{2, 110_000, "bid"}, {1, 120_000, "proxy"}]
    end

    test "a higher maximum takes the lead at one step above the old maximum", %{lot: lot, maxes: maxes} do
      assert {:ok, r} = Proxy.resolve(lot, maxes, %{user_id: 2, amount: 500_000, at: 1, kind: :max})
      assert r.leader_id == 2
      assert r.price == 320_000
      assert r.entries == [{1, 300_000, "proxy"}, {2, 320_000, "proxy"}]
    end

    test "an equal maximum loses to the earlier one, at that amount", %{lot: lot, maxes: maxes} do
      assert {:ok, r} = Proxy.resolve(lot, maxes, %{user_id: 2, amount: 300_000, at: 1, kind: :max})
      assert r.leader_id == 1
      assert r.price == 300_000
    end

    test "a maximum just above the leader's pays its own amount, not more", %{lot: lot, maxes: maxes} do
      assert {:ok, r} = Proxy.resolve(lot, maxes, %{user_id: 2, amount: 310_000, at: 1, kind: :max})
      assert r.leader_id == 2
      assert r.price == 310_000
    end
  end

  describe "the leader" do
    test "cannot tap to bid against themselves" do
      lot = %{@lot | current_bid: 100_000, leader_id: 1}
      assert Proxy.resolve(lot, [max(1, 100_000, 0)], %{user_id: 1, amount: 110_000, at: 1, kind: :bid}) == {:error, :already_leading}
    end

    test "raising their maximum does not raise the price" do
      lot = %{@lot | current_bid: 120_000, leader_id: 1}
      maxes = [max(1, 150_000, 0), max(2, 110_000, 1)]
      assert {:ok, r} = Proxy.resolve(lot, maxes, %{user_id: 1, amount: 160_000, at: 2, kind: :max})
      assert r.price == 120_000
      assert r.entries == []
      assert r.max.amount == 160_000
    end

    test "raising their maximum past the reserve moves the price to the reserve" do
      lot = %{@lot | current_bid: 120_000, leader_id: 1}
      maxes = [max(1, 150_000, 0), max(2, 110_000, 1)]
      assert {:ok, r} = Proxy.resolve(lot, maxes, %{user_id: 1, amount: 250_000, at: 2, kind: :max})
      assert r.price == 170_000
      assert r.entries == [{1, 170_000, "proxy"}]
    end

    test "a lower maximum than their own is refused" do
      lot = %{@lot | current_bid: 120_000, leader_id: 1}
      assert Proxy.resolve(lot, [max(1, 150_000, 0)], %{user_id: 1, amount: 140_000, at: 2, kind: :max}) == {:error, {:not_higher, 150_000}}
    end
  end

  test "the price never falls, whatever the order of maximums" do
    for _ <- 1..200 do
      {_, _, price, _} =
        Enum.reduce(1..15, {@lot, [], 0, 0}, fn i, {lot, maxes, last_price, at} ->
          user = Enum.random(1..4)
          amount = Increments.round_down(Enum.random(100_000..900_000))
          new = %{user_id: user, amount: amount, at: at, kind: :max}

          case Proxy.resolve(lot, maxes, new) do
            {:ok, r} ->
              assert r.price >= last_price, "price fell at step #{i}"
              top = Enum.max_by([r.max | Enum.reject(maxes, &(&1.user_id == user))], & &1.amount)
              assert r.price <= top.amount or r.price == lot.reserve
              maxes = [r.max | Enum.reject(maxes, &(&1.user_id == user))]
              {%{lot | current_bid: r.price, leader_id: r.leader_id}, maxes, r.price, at + 1}

            {:error, _} ->
              {lot, maxes, last_price, at + 1}
          end
        end)

      assert price >= 0
    end
  end
end
