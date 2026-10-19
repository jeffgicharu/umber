defmodule Umber.Format do
  @moduledoc "Numbers, money and times as the site shows them."

  @tz_offset 3 * 3600

  @doc "1250000 -> \"1,250,000\""
  def thousands(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.to_charlist()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  def money(nil), do: "—"
  def money(n), do: "KES " <> thousands(n)

  @doc "Estimate as a catalogue prints it: KES 900,000–1,400,000"
  def estimate(low, high), do: "KES #{thousands(low)}–#{thousands(high)}"

  @doc "A short form for tight spaces: KES 1.4M, KES 900K"
  def short_money(n) when n >= 1_000_000 do
    v = n / 1_000_000
    "KES " <> trim(:erlang.float_to_binary(v, decimals: if(rem(n, 100_000) == 0, do: 1, else: 2))) <> "M"
  end

  def short_money(n) when n >= 1_000, do: "KES #{div(n, 1000)}K"
  def short_money(n), do: "KES #{n}"

  defp trim(s), do: s |> String.trim_trailing("0") |> String.trim_trailing(".")

  @doc "East Africa Time (UTC+3, no daylight saving)."
  def eat(%DateTime{} = dt), do: DateTime.add(dt, @tz_offset, :second) |> Map.merge(%{time_zone: "Africa/Nairobi", zone_abbr: "EAT", utc_offset: @tz_offset})

  @doc "14:30"
  def clock(%DateTime{} = dt) do
    d = eat(dt)
    pad(d.hour) <> ":" <> pad(d.minute)
  end

  @doc "Thursday 24 September 2026"
  def date(%DateTime{} = dt) do
    d = eat(dt)
    "#{weekday(d)} #{d.day} #{month(d.month)} #{d.year}"
  end

  @doc "24 Sep 2026, 19:00"
  def short_datetime(%DateTime{} = dt) do
    d = eat(dt)
    "#{d.day} #{String.slice(month(d.month), 0, 3)} #{d.year}, #{clock(dt)}"
  end

  @doc "Today at 14:30, Tomorrow at 09:00, or 24 Sep at 19:00"
  def when_(%DateTime{} = dt, now \\ DateTime.utc_now()) do
    days = Date.diff(DateTime.to_date(eat(dt)), DateTime.to_date(eat(now)))
    d = eat(dt)

    case days do
      0 -> "Today at #{clock(dt)}"
      1 -> "Tomorrow at #{clock(dt)}"
      -1 -> "Yesterday at #{clock(dt)}"
      _ -> "#{d.day} #{String.slice(month(d.month), 0, 3)} at #{clock(dt)}"
    end
  end

  @doc "Time left as a countdown reads: 2h 14m, 4m 05s, 0:42"
  def remaining(seconds) when seconds <= 0, do: "0:00"
  def remaining(seconds) when seconds < 60, do: "0:" <> pad(seconds)
  def remaining(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m #{pad(rem(seconds, 60))}s"
  def remaining(seconds), do: "#{div(seconds, 3600)}h #{pad(div(rem(seconds, 3600), 60))}m"

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp weekday(d), do: Enum.at(~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday), Date.day_of_week(d) - 1)

  defp month(m),
    do: Enum.at(~w(January February March April May June July August September October November December), m - 1)

  @doc "1 lot, 12 lots"
  def count(1, singular, _plural), do: "1 #{singular}"
  def count(n, _singular, plural), do: "#{n} #{plural}"
end
