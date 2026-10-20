defmodule UmberWeb.ResultsLive do
  use UmberWeb, :live_view

  alias Umber.Catalogue
  alias Umber.Catalogue.{Sale, Lot}
  alias UmberWeb.Meta

  @impl true
  def mount(_params, _session, socket) do
    past = Catalogue.past_sales()
    lots = Map.new(past, &{&1.id, Catalogue.sale_lots(&1)})

    {:ok,
     socket
     |> assign(past: past, lots: lots)
     |> Meta.put(
       title: "Results",
       description:
         "Hammer prices from Umber's past sales of modern and contemporary East African art and design.",
       path: "/results"
     )}
  end

  defp sold(lots), do: Enum.filter(lots, &(&1.status == "sold"))
  defp total(lots), do: lots |> sold() |> Enum.map(& &1.hammer) |> Enum.sum()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      live_now={@live_now}
      notices={@notices}
      active={:results}
    >
      <header class="page-head wrap">
        <p class="label">Results</p>
        <h1>What sold, and for how much</h1>
        <p class="page-lede">
          Hammer prices, in Kenya shillings, before the buyer's premium. Every lot from our past house sales, sold or not.
        </p>
      </header>

      <section
        :for={sale <- @past}
        class="wrap section-tight result-sale"
        aria-labelledby={"sale-#{sale.number}"}
      >
        <div class="section-head">
          <p class="label">Sale {sale.number} · {sale_when(sale)}</p>
          <h2 id={"sale-#{sale.number}"}>{sale.title}</h2>
          <p class="result-totals">
            <span><span class="serif num">{length(sold(@lots[sale.id]))}</span>
            of {length(@lots[sale.id])} sold</span>
            <span><span class="serif num">{Format.short_money(total(@lots[sale.id]))}</span> in total</span>
          </p>
        </div>
        <div class="table-scroll">
          <table class="table result-table">
            <thead>
              <tr>
                <th>Lot</th>
                <th>Work</th>
                <th class="num">Estimate (KES)</th>
                <th class="num">Hammer (KES)</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={lot <- @lots[sale.id]}>
                <td class="serif num lot-table-no">{lot.number}</td>
                <td>
                  <a href={Lot.path(lot)} class="lot-table-work">
                    <span class="lot-table-thumb"><.work_image work={lot.work} sizes="64px" /></span>
                    <span><strong>{lot.work.artist.name}</strong><br /><em class="serif">{lot.work.title}</em>, {lot.work.year}</span>
                  </a>
                </td>
                <td class="num" data-label="Estimate">
                  {Format.thousands(lot.estimate_low)}–{Format.thousands(lot.estimate_high)}
                </td>
                <td class="num" data-label="Hammer">
                  <span
                    :if={lot.status == "sold"}
                    class={["hammer", lot.hammer > lot.estimate_high && "above"]}
                  >{Format.thousands(lot.hammer)}</span>
                  <span :if={lot.status != "sold"} class="muted">Not sold</span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <a class="text-link" href={Sale.path(sale)} style="margin-top: 20px">The catalogue, with pictures
        <span class="arrow" aria-hidden="true">→</span></a>
      </section>
    </Layouts.app>
    """
  end
end
