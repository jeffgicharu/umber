defmodule Umber.Market.Schedule do
  @moduledoc """
  When each running sale's cycles happen. East Africa Time is UTC+3 all year,
  so the minutes past the hour are the same in both.

    * Live sale: a session at a quarter past and a quarter to every hour.
    * Works on Paper & Photographs: opens on the hour; lots close from half
      past, one every two minutes.
    * Design: opens at half past; lots close from the hour, one every two minutes.
  """

  @live_minutes [15, 45]
  @timed %{"paper-photographs" => 0, "design-objects" => 30}
  @closing_after 30 * 60
  @interval 120

  def interval, do: @interval

  @doc "The next live session at or after `now`, on the quarter hour."
  def next_live(%DateTime{} = now) do
    base = %{now | minute: 0, second: 0, microsecond: {0, 6}}

    Enum.find_value([0, 1], fn h ->
      Enum.find_value(@live_minutes, fn m ->
        t = DateTime.add(base, h * 3600 + m * 60, :second)
        if DateTime.compare(t, now) == :gt, do: t
      end)
    end)
  end

  @doc """
  The times for the next cycle of a timed sale when none is open: the current
  hour's opening if it was less than ten minutes ago, otherwise the next one.
  """
  def next_timed(template, %DateTime{} = now) do
    minute = Map.fetch!(@timed, template)
    base = %{now | minute: minute, second: 0, microsecond: {0, 6}}
    latest = if DateTime.compare(base, now) == :gt, do: DateTime.add(base, -3600, :second), else: base

    opens =
      if DateTime.diff(now, latest, :second) < 600, do: latest, else: DateTime.add(latest, 3600, :second)

    %{opens_at: opens, first_close_at: DateTime.add(opens, @closing_after, :second), lot_interval: @interval}
  end

  def timed_templates, do: Map.keys(@timed)
end
