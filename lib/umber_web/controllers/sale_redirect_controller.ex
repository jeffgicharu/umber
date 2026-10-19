defmodule UmberWeb.SaleRedirectController do
  @moduledoc "Links that always lead to the current cycle of a running sale."
  use UmberWeb, :controller

  alias Umber.Catalogue
  alias Umber.Catalogue.Sale

  @doc "/live: the saleroom selling now, or the next live session."
  def live(conn, _params) do
    case UmberWeb.Hooks.live_now() || Catalogue.latest_cycle("modern-contemporary") do
      %Sale{} = sale -> redirect(conn, to: ~p"/sales/#{sale.number}/room")
      nil -> redirect(conn, to: ~p"/sales")
    end
  end

  @doc "/sales/current/paper-photographs and the like."
  def current(conn, %{"template" => template}) do
    case Catalogue.latest_cycle(template) do
      %Sale{} = sale -> redirect(conn, to: Sale.path(sale))
      nil -> redirect(conn, to: ~p"/sales")
    end
  end
end
