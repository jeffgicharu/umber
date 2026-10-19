defmodule UmberWeb.SaleLive do
  use UmberWeb, :live_view

  import Ecto.Query
  alias Umber.{Catalogue, Events, Repo}
  alias Umber.Catalogue.{Sale, Lot}
  alias UmberWeb.Meta

  @sorts [
    {"Lot number", "number"},
    {"Closing soonest", "closing"},
    {"Estimate, low to high", "estimate-asc"},
    {"Estimate, high to low", "estimate-desc"},
    {"Current bid, high to low", "bid-desc"}
  ]

  @impl true
  def mount(%{"number" => number}, _session, socket) do
    case Catalogue.get_sale_by_number(number) do
      %Sale{published: true} = sale ->
        if connected?(socket), do: Events.subscribe("sale:#{sale.id}")
        lots = Catalogue.sale_lots(sale)

        {:ok,
         socket
         |> assign(
           sale: sale,
           lots: lots,
           now: DateTime.utc_now(),
           mine: mine(socket.assigns.current_user, sale)
         )
         |> assign(
           artists:
             lots
             |> Enum.map(& &1.work.artist)
             |> Enum.uniq_by(& &1.id)
             |> Enum.sort_by(& &1.name)
         )
         |> Meta.put(
           title: "#{sale.title}, sale #{sale.number}",
           description: "#{sale.summary} #{Format.count(length(lots), "lot", "lots")}.",
           path: Sale.path(sale),
           image:
             lots
             |> Enum.max_by(& &1.estimate_high, fn -> nil end)
             |> then(&(&1 && &1.work.image)),
           json_ld: sale_json(sale, lots)
         )}

      _ ->
        raise UmberWeb.NotFound
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    sort = if params["sort"] in Enum.map(@sorts, &elem(&1, 1)), do: params["sort"], else: "number"
    artist = params["artist"]
    view = if params["view"] == "list", do: "list", else: "grid"
    {:noreply, assign(socket, sort: sort, artist: artist, view: view)}
  end

  @impl true
  def handle_event("filter", params, socket) do
    query =
      %{"sort" => params["sort"], "artist" => params["artist"], "view" => socket.assigns.view}
      |> Enum.reject(fn {k, v} ->
        v in [nil, ""] or (k == "sort" and v == "number") or (k == "view" and v == "grid")
      end)

    {:noreply,
     push_patch(socket, to: ~p"/sales/#{socket.assigns.sale.number}?#{query}", replace: true)}
  end

  @impl true
  def handle_info({:lot, event}, socket) do
    lots =
      Enum.map(socket.assigns.lots, fn lot ->
        if lot.id == event.id and event.version >= lot.version,
          do: apply_event(lot, event),
          else: lot
      end)

    mine =
      case socket.assigns.current_user do
        %{id: uid} ->
          if Enum.any?(event.last, &(&1.user_id == uid)),
            do: MapSet.put(socket.assigns.mine, event.id),
            else: socket.assigns.mine

        _ ->
          socket.assigns.mine
      end

    {:noreply, assign(socket, lots: lots, mine: mine, now: DateTime.utc_now())}
  end

  def handle_info(:sale_changed, socket) do
    sale = Repo.get!(Sale, socket.assigns.sale.id)

    {:noreply,
     assign(socket, sale: sale, lots: Catalogue.sale_lots(sale), now: DateTime.utc_now())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @doc false
  def apply_event(%Lot{} = lot, e) do
    %{
      lot
      | status: e.status,
        current_bid: e.current_bid,
        leader_id: e.leader_id,
        bid_count: e.bid_count,
        closes_at: e.closes_at,
        extensions: e.extensions,
        hammer: e.hammer,
        buyer_id: Map.get(e, :buyer_id),
        closed_at: Map.get(e, :closed_at),
        version: e.version
    }
  end

  defp mine(nil, _sale), do: MapSet.new()

  defp mine(user, sale) do
    from(b in Umber.Auctions.Bid,
      join: l in assoc(b, :lot),
      where: l.sale_id == ^sale.id and b.user_id == ^user.id,
      distinct: true,
      select: b.lot_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp visible(lots, sort, artist) do
    lots
    |> Enum.filter(fn l -> artist in [nil, ""] or l.work.artist.slug == artist end)
    |> Enum.sort_by(fn l ->
      case sort do
        "closing" ->
          {if(Lot.finished?(l), do: 1, else: 0), l.closes_at && DateTime.to_unix(l.closes_at),
           l.number}

        "estimate-asc" ->
          l.estimate_low

        "estimate-desc" ->
          -l.estimate_high

        "bid-desc" ->
          -(l.current_bid || l.hammer || 0)

        _ ->
          l.number
      end
    end)
  end

  defp sale_json(sale, lots) do
    start = sale.starts_at || sale.opens_at || sale.ended_at

    %{
      "@context" => "https://schema.org",
      "@type" => "SaleEvent",
      "name" => "#{sale.title} (sale #{sale.number})",
      "description" => sale.description,
      "url" => Meta.url(Sale.path(sale)),
      "startDate" => start && DateTime.to_iso8601(start),
      "eventAttendanceMode" =>
        if(sale.format == "live",
          do: "https://schema.org/MixedEventAttendanceMode",
          else: "https://schema.org/OnlineEventAttendanceMode"
        ),
      "eventStatus" => "https://schema.org/EventScheduled",
      "location" =>
        if(sale.format == "live",
          do: %{
            "@type" => "Place",
            "name" => "Umber House",
            "address" => "Lenana Road, Kilimani, Nairobi, Kenya"
          },
          else: %{"@type" => "VirtualLocation", "url" => Meta.url(Sale.path(sale))}
        ),
      "organizer" => %{"@id" => Meta.url("/#organization")},
      "offers" => %{
        "@type" => "AggregateOffer",
        "priceCurrency" => "KES",
        "lowPrice" => lots |> Enum.map(& &1.estimate_low) |> Enum.min(fn -> 0 end),
        "highPrice" => lots |> Enum.map(& &1.estimate_high) |> Enum.max(fn -> 0 end),
        "offerCount" => length(lots)
      }
    }
  end

  defp sold_total(lots),
    do: lots |> Enum.filter(&(&1.status == "sold")) |> Enum.map(& &1.hammer) |> Enum.sum()

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        shown: visible(assigns.lots, assigns.sort, assigns.artist),
        sorts: @sorts,
        closed_count: Enum.count(assigns.lots, &Lot.finished?/1),
        sold_count: Enum.count(assigns.lots, &(&1.status == "sold"))
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      live_now={@live_now}
      notices={@notices}
      active={:sales}
    >
      <div class="wrap">
        <nav class="crumbs" aria-label="Breadcrumb">
          <a href={~p"/sales"}>Sales</a><span class="sep">/</span><span>Sale {@sale.number}</span>
        </nav>
      </div>

      <header class={["sale-head", Sale.live?(@sale) && "is-live"]}>
        <div class="wrap sale-head-inner">
          <div class="sale-head-number" aria-hidden="true">
            <span class="label">Sale</span>
            <span class="num serif">{@sale.number}</span>
          </div>
          <div class="sale-head-text">
            <p class="label">
              <span class={["chip", sale_chip(@sale)]}>{sale_status(@sale)}</span>
              <span>{if Sale.live?(@sale),
                do: "Live sale · Umber House and online",
                else: "Online sale"}</span>
            </p>
            <h1>{@sale.title}</h1>
            <p class="sale-when">{sale_when(@sale, @now)}</p>
            <p class="sale-desc">{@sale.description}</p>
            <div class="sale-actions">
              <a :if={@sale.status == "live"} class="btn" href={~p"/sales/#{@sale.number}/room"}>
                <span class="live-dot" aria-hidden="true"></span>
                Enter the saleroom <span class="arrow" aria-hidden="true">→</span>
              </a>
              <a
                :if={@sale.status == "upcoming" and Sale.live?(@sale)}
                class="btn ghost"
                href={~p"/sales/#{@sale.number}/room"}
              >
                See the saleroom
              </a>
              <a
                :if={!@current_user and @sale.status != "closed"}
                class="btn ghost"
                href={~p"/register?#{[return_to: Sale.path(@sale)]}"}
              >Register to bid</a>
            </div>
          </div>
          <dl class="sale-facts">
            <div>
              <dt class="label">Lots</dt>
              <dd class="num serif">{length(@lots)}</dd>
            </div>
            <div :if={@sale.status in ["open", "live"]}>
              <dt class="label">{if Sale.live?(@sale), do: "Sold so far", else: "Closed"}</dt>
              <dd class="num serif">{if Sale.live?(@sale), do: @sold_count, else: @closed_count}</dd>
            </div>
            <div :if={@sale.status == "closed"}>
              <dt class="label">Sold</dt>
              <dd class="num serif">{@sold_count}</dd>
            </div>
            <div :if={@sale.status == "closed"}>
              <dt class="label">Total, hammer</dt>
              <dd class="num serif">{Format.short_money(sold_total(@lots))}</dd>
            </div>
          </dl>
        </div>
      </header>

      <div class="wrap">
        <form class="toolbar" phx-change="filter" id="sale-filter" aria-label="Sort and filter lots">
          <div class="field">
            <label for="filter-artist">Artist or maker</label>
            <select id="filter-artist" name="artist" class="select">
              <option value="">All artists and makers</option>
              <option :for={a <- @artists} value={a.slug} selected={@artist == a.slug}>
                {a.name}
              </option>
            </select>
          </div>
          <div class="field">
            <label for="filter-sort">Sort by</label>
            <select id="filter-sort" name="sort" class="select">
              <option :for={{label, value} <- @sorts} value={value} selected={@sort == value}>
                {label}
              </option>
            </select>
          </div>
          <div class="view-toggle" role="group" aria-label="Show lots as">
            <.link
              patch={
                ~p"/sales/#{@sale.number}?#{Enum.reject([sort: @sort != "number" && @sort, artist: @artist], fn {_, v} -> !v or v == "" end)}"
              }
              aria-pressed={to_string(@view == "grid")}
            >Pictures</.link>
            <.link
              patch={
                ~p"/sales/#{@sale.number}?#{Enum.reject([sort: @sort != "number" && @sort, artist: @artist, view: "list"], fn {_, v} -> !v or v == "" end)}"
              }
              aria-pressed={to_string(@view == "list")}
            >List</.link>
          </div>
          <p class="toolbar-count muted" aria-live="polite">
            {Format.count(length(@shown), "lot", "lots")}
          </p>
        </form>

        <div :if={@shown == []} class="empty">
          <h3>No lots by that artist in this sale.</h3>
          <p>Choose another artist, or show every lot.</p>
          <.link class="btn ghost" patch={~p"/sales/#{@sale.number}"}>Show all lots</.link>
        </div>

        <div :if={@view == "grid" and @shown != []} class="lot-grid" id="lots">
          <.lot_card
            :for={{lot, i} <- Enum.with_index(@shown)}
            lot={lot}
            user={@current_user}
            mine={MapSet.member?(@mine, lot.id)}
            now={@now}
            priority={i < 4}
          />
        </div>

        <div :if={@view == "list" and @shown != []} class="table-scroll">
          <table class="table lot-table">
            <thead>
              <tr>
                <th>Lot</th>
                <th>Work</th>
                <th class="num">Estimate (KES)</th>
                <th class="num">
                  {if @sale.status == "closed", do: "Hammer (KES)", else: "Current bid (KES)"}
                </th>
                <th>
                  {if Sale.timed?(@sale) and @sale.status != "closed", do: "Closes", else: "Status"}
                </th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={lot <- @shown}
                class={@current_user && lot.leader_id == @current_user.id && "mine"}
              >
                <td class="serif num lot-table-no">{lot.number}</td>
                <td>
                  <a href={Lot.path(lot)} class="lot-table-work">
                    <span class="lot-table-thumb"><.work_image work={lot.work} sizes="64px" /></span>
                    <span><strong>{lot.work.artist.name}</strong><br /><em class="serif">{lot.work.title}</em>, {lot.work.year}</span>
                  </a>
                </td>
                <td class="num">
                  {Format.thousands(lot.estimate_low)}–{Format.thousands(lot.estimate_high)}
                </td>
                <td class="num">
                  {(lot.hammer || lot.current_bid) && Format.thousands(lot.hammer || lot.current_bid)}
                </td>
                <td>
                  <%= cond do %>
                    <% lot.status == "sold" -> %>
                      <span class="chip sold">Sold</span>
                    <% lot.status == "unsold" -> %>
                      <span class="chip plain">Not sold</span>
                    <% lot.status == "open" and lot.closes_at -> %>
                      <.countdown id={"lcd-#{lot.id}"} at={lot.closes_at} now={@now} />
                    <% lot.status == "open" -> %>
                      <span class="chip live">On the block</span>
                    <% true -> %>
                      <span class="muted">{if Sale.live?(@sale),
                        do: "To come",
                        else: "Opens #{Format.clock(@sale.opens_at)}"}</span>
                  <% end %>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
