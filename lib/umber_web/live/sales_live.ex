defmodule UmberWeb.SalesLive do
  use UmberWeb, :live_view

  alias Umber.{Catalogue, Events}
  alias Umber.Catalogue.Sale
  alias UmberWeb.Meta

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> Meta.put(
       title: "Current sales",
       description:
         "Live sales from the rostrum and online sales that close lot by lot, at Umber in Nairobi.",
       path: "/sales"
     )
     |> load()}
  end

  defp load(socket) do
    sales = Catalogue.current_sales()
    counts = Map.new(sales, &{&1.id, length(Catalogue.sale_lots(&1))})
    if connected?(socket), do: Enum.each(sales, &Events.subscribe("sale:#{&1.id}"))

    assign(socket,
      sales: sales,
      counts: counts,
      live: Enum.filter(sales, &Sale.live?/1),
      timed: Enum.filter(sales, &Sale.timed?/1),
      past: Catalogue.past_sales(),
      now: DateTime.utc_now()
    )
  end

  @impl true
  def handle_info(msg, socket) when msg in [:sales_changed, :sale_changed],
    do: {:noreply, load(socket)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      live_now={@live_now}
      notices={@notices}
      active={:sales}
    >
      <header class="page-head wrap">
        <p class="label">Sales calendar</p>
        <h1>Current sales</h1>
        <p class="page-lede">
          Live sessions of our Modern &amp; Contemporary sale run at a quarter past and a quarter to every hour. Our online sales of works on paper, photographs and design close lot by lot through the day.
        </p>
      </header>

      <section class="wrap section-tight" aria-labelledby="live-title">
        <div class="section-head">
          <p class="label">From the rostrum</p>
          <h2 id="live-title">Live sales</h2>
        </div>
        <div class="sale-rows">
          <.sale_row :for={s <- @live} sale={s} count={@counts[s.id]} now={@now} />
        </div>
      </section>

      <section class="wrap section-tight" aria-labelledby="online-title">
        <div class="section-head">
          <p class="label">Online</p>
          <h2 id="online-title">Online sales</h2>
        </div>
        <div class="sale-rows">
          <.sale_row :for={s <- @timed} sale={s} count={@counts[s.id]} now={@now} />
        </div>
      </section>

      <section :if={@past != []} class="wrap section-tight" aria-labelledby="past-title">
        <div class="section-head">
          <p class="label">Results</p>
          <h2 id="past-title">Past sales</h2>
          <a class="text-link" href={~p"/results"}>All results
          <span class="arrow" aria-hidden="true">→</span></a>
        </div>
        <div class="cover-grid">
          <.sale_cover :for={s <- @past} sale={s} now={@now} />
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :sale, Sale, required: true
  attr :count, :integer, required: true
  attr :now, DateTime, required: true

  defp sale_row(assigns) do
    ~H"""
    <a
      class={["sale-row", @sale.status == "live" && "is-live"]}
      href={if @sale.status == "live", do: ~p"/sales/#{@sale.number}/room", else: Sale.path(@sale)}
    >
      <span class="sale-row-number num serif">{@sale.number}</span>
      <span class="sale-row-main">
        <span class={["chip", sale_chip(@sale)]}>{sale_status(@sale)}</span>
        <span class="sale-row-title serif">{@sale.title}</span>
        <span class="sale-row-when">{sale_when(@sale, @now)}</span>
      </span>
      <span class="sale-row-side">
        <span class="label">{Format.count(@count, "lot", "lots")}</span>
        <.countdown
          :if={@sale.status == "upcoming" && @sale.starts_at}
          id={"sc-#{@sale.id}"}
          at={@sale.starts_at}
          now={@now}
          prefix="Starts in"
        />
        <.countdown
          :if={@sale.status == "upcoming" && @sale.opens_at}
          id={"so-#{@sale.id}"}
          at={@sale.opens_at}
          now={@now}
          prefix="Opens in"
        />
        <span class="text-link">{if @sale.status == "live",
          do: "Enter the saleroom",
          else: "View the catalogue"} <span class="arrow" aria-hidden="true">→</span></span>
      </span>
    </a>
    """
  end
end
