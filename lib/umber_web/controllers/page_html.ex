defmodule UmberWeb.PageHTML do
  use UmberWeb, :html

  alias Umber.Auctions.{Increments, Invoice}

  embed_templates "page_html/*"

  def increments do
    Increments.table()
    |> Enum.scan({0, nil, nil}, fn {below, step}, {_, prev_below, _} ->
      {prev_below || 0, below, step}
    end)
  end

  def example do
    Invoice.amounts(500_000)
  end
end
