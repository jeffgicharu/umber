defmodule UmberWeb.HomeLive do
  use UmberWeb, :live_view

  alias Umber.{Catalogue, Events, Auctions}
  alias Umber.Catalogue.Sale
  alias UmberWeb.Meta

  @feature_artist "achieng-oduya"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, 30_000)

    {:ok,
     socket
     |> Meta.put(
       title: "Modern and contemporary East African art at auction",
       description: Meta.default_description(),
       path: "/",
       image: "/images/share/umber-share.jpg"
     )
     |> load()}
  end

  defp load(socket) do
    sales = Catalogue.current_sales()
    live = Enum.find(sales, &(&1.format == "live" and &1.status == "live"))

    next_live =
      sales
      |> Enum.filter(&(&1.format == "live" and &1.status == "upcoming"))
      |> Enum.min_by(& &1.starts_at, DateTime, fn -> nil end)

    show_live = live || next_live
    lots = if show_live, do: Catalogue.sale_lots(show_live), else: []
    featured = Enum.max_by(lots, & &1.estimate_high, fn -> nil end)
    session = live && Auctions.live_session(live)
    on_block = session && session.lot_id && Enum.find(lots, &(&1.id == session.lot_id))
    closing = Catalogue.closing_soon(8)

    if connected?(socket) do
      for s <- sales, do: Events.subscribe("sale:#{s.id}")
      if live, do: Events.subscribe("live:#{live.id}")
    end

    artist = Catalogue.get_artist_by_slug(@feature_artist)

    assign(socket,
      now: DateTime.utc_now(),
      sales: sales,
      live: live,
      next_live: next_live,
      featured: featured,
      session: session,
      on_block: on_block,
      closing: closing,
      results: Catalogue.notable_results(6),
      artist: artist,
      artist_lot:
        artist && artist |> Catalogue.artist_lots() |> Enum.find(&(&1.work.image == "lot-001")),
      watched: Auctions.watched_ids(socket.assigns.current_user)
    )
  end

  @impl true
  def handle_info({:lot, _event}, socket),
    do: {:noreply, assign(socket, closing: Catalogue.closing_soon(8), now: DateTime.utc_now())}

  def handle_info({:live, _event}, socket) do
    {:noreply, load(socket)}
  end

  def handle_info(msg, socket) when msg in [:sales_changed, :sale_changed],
    do: {:noreply, load(socket)}

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 30_000)
    {:noreply, assign(socket, now: DateTime.utc_now())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} live_now={@live_now} notices={@notices}>
      <section class="hero wrap" aria-labelledby="hero-title">
        <div class="hero-text">
          <p class="label hero-kicker">
            <%= if @live do %>
              <span class="chip live">Live now</span> Sale {@live.number} · {@live.title}
            <% else %>
              Live sales from the rostrum, twice an hour, online and in the room
            <% end %>
          </p>
          <h1 id="hero-title" class="hero-title">
            <span class="line"><span>Bid in</span></span>
            <span class="line"><span>the room,</span></span>
            <span class="line"><span><em>from anywhere.</em></span></span>
          </h1>
          <p class="hero-lede">
            Umber sells modern and contemporary East African art and collectable design: live from the rostrum in Nairobi, and online in sales that close lot by lot. Register in a minute and bid from your phone.
          </p>
          <div class="hero-actions">
            <%= cond do %>
              <% @live -> %>
                <a class="btn" href={~p"/sales/#{@live.number}/room"}>Enter the saleroom
                <span class="arrow" aria-hidden="true">→</span></a>
              <% @next_live -> %>
                <a class="btn" href={Sale.path(@next_live)}>See the next live sale
                <span class="arrow" aria-hidden="true">→</span></a>
              <% true -> %>
                <a class="btn" href={~p"/sales"}>See current sales
                <span class="arrow" aria-hidden="true">→</span></a>
            <% end %>
            <a :if={!@current_user} class="btn ghost" href={~p"/register"}>Register to bid</a>
            <a :if={@current_user} class="btn ghost" href={~p"/account"}>Your bids</a>
          </div>

          <div :if={@next_live && !@live} class="hero-next">
            <p class="label">Next live session</p>
            <p class="hero-next-time">
              <span class="serif num">{Format.clock(@next_live.starts_at)}</span>
              <.countdown
                id="hero-next"
                at={@next_live.starts_at}
                now={@now}
                prefix="in"
                class="hero-next-count"
              />
            </p>
          </div>
          <div :if={@live && @session} class="hero-next">
            <p class="label">On the block</p>
            <p class="hero-next-time">
              <span class="serif num">Lot {(@on_block && @on_block.number) || "—"}</span>
              <span class="hero-next-count">{@session.call}</span>
            </p>
          </div>
        </div>

        <figure :if={@featured} class="hero-lot">
          <span class="hero-lotno num" aria-hidden="true">{@featured.number}</span>
          <a class="hero-frame" href={Umber.Catalogue.Lot.path(@featured)}>
            <.work_image
              work={@featured.work}
              sizes="(min-width: 1024px) 46vw, 92vw"
              loading="eager"
              priority
              transition={"work-#{@featured.work_id}"}
            />
          </a>
          <figcaption class="hero-caption">
            <p class="label">Lot {@featured.number} · {@featured.sale.title}</p>
            <.caption work={@featured.work} link />
            <.estimate lot={@featured} />
          </figcaption>
        </figure>
      </section>

      <section :if={@closing != []} class="section closing" aria-labelledby="closing-title">
        <div class="wrap">
          <div class="section-head">
            <p class="label">Online sales</p>
            <h2 id="closing-title">Closing <em>now</em></h2>
            <a class="text-link" href={~p"/sales"}>All sales
            <span class="arrow" aria-hidden="true">→</span></a>
          </div>
        </div>
        <div class="rail" tabindex="0" aria-label="Lots closing soonest">
          <div class="rail-track">
            <div :for={lot <- @closing} class="rail-item">
              <.lot_card lot={lot} user={@current_user} now={@now} />
            </div>
          </div>
        </div>
      </section>

      <section class="section" aria-labelledby="sales-title">
        <div class="wrap">
          <div class="section-head">
            <p class="label">On view and on sale</p>
            <h2 id="sales-title">Current sales</h2>
            <a class="text-link" href={~p"/results"}>Past results
            <span class="arrow" aria-hidden="true">→</span></a>
          </div>
          <div class="cover-grid">
            <.sale_cover :for={s <- @sales} sale={s} now={@now} />
          </div>
        </div>
      </section>

      <section class="night-band night" aria-labelledby="room-title">
        <div class="wrap night-band-inner">
          <div>
            <p class="label">The saleroom</p>
            <h2 id="room-title">A lot every minute, and every bid in the open.</h2>
            <p class="night-band-text">
              In a live sale the auctioneer takes bids from the room, the telephones, the book and online at once. You see the asking price, the bid in hand and the auctioneer's call as it happens, and you bid with one tap.
            </p>
            <a :if={@live} class="btn brass" href={~p"/sales/#{@live.number}/room"}>Enter the saleroom
            <span class="arrow" aria-hidden="true">→</span></a>
            <a :if={!@live && @next_live} class="btn brass" href={Sale.path(@next_live)}>Leave an absentee bid
            <span class="arrow" aria-hidden="true">→</span></a>
          </div>
          <div class="night-band-stage" aria-hidden="true">
            <div class="spot"></div>
            <div :if={@on_block || @featured} class="stage-work">
              <.work_image work={(@on_block || @featured).work} sizes="40vw" />
            </div>
            <p class="stage-bid num">
              <span class="label">{if @session && @session.current_bid,
                do: "Bid in hand",
                else: "Estimate"}</span>
              <span class="serif">{(@session && @session.current_bid &&
                                      Format.money(@session.current_bid)) ||
                (@featured && Format.short_money(@featured.estimate_low))}</span>
            </p>
          </div>
        </div>
      </section>

      <section
        :if={@artist && @artist_lot}
        class="section feature wrap"
        aria-labelledby="feature-title"
      >
        <div class="feature-image">
          <.work_image work={@artist_lot.work} sizes="(min-width: 1024px) 55vw, 92vw" />
        </div>
        <div class="feature-text">
          <p class="label">Artist in focus</p>
          <h2 id="feature-title">{@artist.name}: twenty years of one lake</h2>
          <p class="feature-lede">{@artist.bio}</p>
          <p class="pull">
            <span class="serif">“The lake is never the same colour twice, so I never run out of it.”</span>
          </p>
          <a class="text-link" href={~p"/artists/#{@artist.slug}"}>Works by {@artist.name}
          <span class="arrow" aria-hidden="true">→</span></a>
        </div>
      </section>

      <section :if={@results != []} class="section wrap" aria-labelledby="results-title">
        <div class="section-head">
          <p class="label">Results</p>
          <h2 id="results-title">Recently sold</h2>
          <a class="text-link" href={~p"/results"}>All results
          <span class="arrow" aria-hidden="true">→</span></a>
        </div>
        <ol class="results-list">
          <li :for={lot <- @results}>
            <a href={Umber.Catalogue.Lot.path(lot)}>
              <span class="r-image"><.work_image work={lot.work} sizes="120px" /></span>
              <span class="r-caption">
                <span class="caption">
                  <span class="artist">{lot.work.artist.name}</span>
                  <span class="work-title"><em>{lot.work.title}</em></span>
                </span>
                <span class="label">Sale {lot.sale.number} · Lot {lot.number} · Estimate {Format.estimate(
                  lot.estimate_low,
                  lot.estimate_high
                )}</span>
              </span>
              <span class="r-price num serif">{Format.money(lot.hammer)}</span>
            </a>
          </li>
        </ol>
      </section>

      <section class="section wrap split" aria-labelledby="sell-title">
        <div class="split-image">
          <.photo
            name="photo-valuation"
            alt="A specialist and a client look together at a small bronze head across a timber table."
          />
        </div>
        <div class="split-text">
          <p class="label">Selling with Umber</p>
          <h2 id="sell-title">Tell us about a work you would like to sell.</h2>
          <p>
            Send us photographs and what you know of a painting, a sculpture or a piece of design, and a specialist will tell you what it might fetch and which sale suits it. Our commission is agreed with you before anything is catalogued.
          </p>
          <a class="btn" href={~p"/sell"}>Ask for a valuation
          <span class="arrow" aria-hidden="true">→</span></a>
        </div>
      </section>

      <section class="section wrap split reverse" aria-labelledby="visit-title">
        <div class="split-image">
          <.photo
            name="photo-house"
            alt="Umber House: a single-storey 1960s house with a deep concrete roof and a breeze-block screen, in a garden."
          />
        </div>
        <div class="split-text">
          <p class="label">Visit</p>
          <h2 id="visit-title">Umber House, Lenana Road</h2>
          <p>
            Every lot can be seen at Umber House before it is sold. Viewing is open Tuesday to Sunday, 10:00 to 18:00, and our specialists are there to take a work off the wall for you.
          </p>
          <a class="text-link" href={~p"/visit"}>Opening hours and directions
          <span class="arrow" aria-hidden="true">→</span></a>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
