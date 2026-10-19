defmodule Umber.Auctions.Proxy do
  @moduledoc """
  Resolves a new bid against the maximums already left on a lot. Pure: no
  database, no clock. The caller passes the lot's state and every maximum.

  The rules:

    * The highest maximum leads. If two maximums are equal, the earlier one leads.
    * The leader pays one step above the second-highest maximum, never more than
      their own maximum.
    * With only one bidder, the price is the opening bid, unless their maximum
      reaches the reserve, in which case the price goes straight to the reserve.
    * A one-tap bid is a maximum equal to the bid.
  """

  alias Umber.Auctions.Increments

  @type max :: %{user_id: integer(), amount: integer(), at: integer()}

  @doc """
  `lot` has `:current_bid`, `:leader_id`, `:opening_bid` and `:reserve`.
  `new` has `:user_id`, `:amount`, `:at` (a sortable integer) and `:kind`
  (`:bid` or `:max`).

  Returns `{:ok, result}` with the new `:price`, `:leader_id`, the history
  `:entries` to record (in order) and the bidder's `:max`; or `{:error, reason}`.
  """
  def resolve(lot, maxes, new) do
    next = Increments.next(lot.current_bid, lot.opening_bid)
    leading? = lot.leader_id == new.user_id
    own = Enum.find(maxes, &(&1.user_id == new.user_id))

    cond do
      leading? and new.kind == :bid ->
        {:error, :already_leading}

      leading? and own && new.amount <= own.amount ->
        {:error, {:not_higher, own.amount}}

      not leading? and new.amount < next ->
        {:error, {:too_low, next}}

      true ->
        {:ok, settle(lot, maxes, new, own, leading?)}
    end
  end

  defp settle(lot, maxes, new, own, leading?) do
    mine = %{
      user_id: new.user_id,
      amount: max(new.amount, (own && own.amount) || 0),
      # A raised maximum keeps its place in the queue for ties.
      at: if(own, do: own.at, else: new.at)
    }

    maxes = [mine | Enum.reject(maxes, &(&1.user_id == new.user_id))]
    [top | rest] = Enum.sort_by(maxes, &{-&1.amount, &1.at})
    second = List.first(rest)

    price =
      cond do
        # Raising your own maximum never makes you bid against yourself.
        leading? -> lot.current_bid
        is_nil(second) -> lot.opening_bid
        second.amount == top.amount -> second.amount
        true -> min(top.amount, second.amount + Increments.step(second.amount))
      end

    price = if top.amount >= lot.reserve and price < lot.reserve, do: lot.reserve, else: price
    price = max(price, lot.current_bid || 0)

    entries = entries(lot, new, top, second, price, leading?)

    %{price: price, leader_id: top.user_id, entries: entries, max: mine}
  end

  # The bids a catalogue's bid history shows for this change, oldest first.
  defp entries(lot, new, top, second, price, leading?) do
    kind = if new.kind == :bid, do: "bid", else: "proxy"

    cond do
      # Raising your own maximum moves the price only if it now meets the reserve.
      leading? ->
        if price > (lot.current_bid || 0), do: [{new.user_id, price, "proxy"}], else: []

      # The first bid on the lot.
      is_nil(lot.leader_id) ->
        if top.user_id == new.user_id,
          do: [{new.user_id, price, kind}],
          else: [{new.user_id, new.amount, kind}, {top.user_id, price, "proxy"}]

      # The new bidder takes the lead. The leader before them is shown going
      # to their maximum first, if they had one above the price.
      top.user_id == new.user_id ->
        before = if second && second.amount > (lot.current_bid || 0), do: [{second.user_id, second.amount, "proxy"}], else: []
        before ++ [{new.user_id, price, kind}]

      # The leader's maximum answers the new bid.
      true ->
        [{new.user_id, new.amount, kind}, {top.user_id, price, "proxy"}]
    end
  end
end
