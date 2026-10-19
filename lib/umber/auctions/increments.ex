defmodule Umber.Auctions.Increments do
  @moduledoc """
  The bidding steps, in Kenya shillings. Every bid on a lot is the current bid
  plus the step for that amount.
  """

  @table [
    {50_000, 2_500},
    {100_000, 5_000},
    {200_000, 10_000},
    {500_000, 20_000},
    {1_000_000, 50_000},
    {2_000_000, 100_000},
    {5_000_000, 200_000}
  ]
  @top 500_000

  def table, do: @table ++ [{nil, @top}]

  @doc "The step that applies at a given amount."
  def step(amount) when is_integer(amount) do
    Enum.find_value(@table, @top, fn {below, step} -> if amount < below, do: step end)
  end

  @doc "The lowest acceptable next bid."
  def next(nil, opening), do: opening
  def next(current, _opening), do: current + step(current)

  @doc "One step down, for an auctioneer looking for an opening bid."
  def previous(amount) do
    down = amount - step(max(amount - 1, 0))
    max(round_down(down), step(0))
  end

  @doc "Rounds an amount down onto the step grid for its size."
  def round_down(amount) when is_integer(amount) do
    s = step(amount)
    div(amount, s) * s
  end
end
