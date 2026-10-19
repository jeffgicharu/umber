defmodule UmberWeb.Desk.DashboardLive do
  use UmberWeb, :live_view

  import Ecto.Query
  alias Umber.{Repo, Catalogue, Desk, Events, Auctions}
  alias Umber.Catalogue.{Sale, Lot}
  alias Umber.Auctions.Bid
  alias Umber.Accounts.User

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Events.subscribe("desk")
      Events.subscribe("market")
      :timer.send_interval(10_000, :refresh)
    end

    {:ok, socket |> assign(page_title: "Today") |> load()}
  end

  defp load(socket) do
    hour_ago = DateTime.add(DateTime.utc_now(), -3600, :second)
    five_min = DateTime.add(DateTime.utc_now(), -300, :second)

    assign(socket,
      sales: Catalogue.current_sales(),
      closing: Catalogue.closing_soon(5),
      bids_hour: Repo.aggregate(from(b in Bid, where: b.inserted_at > ^hour_ago), :count),
      online:
        Repo.aggregate(
          from(u in User, where: u.kind == "bidder" and u.last_seen_at > ^five_min),
          :count
        ),
      limits: Desk.list_pending_limits(),
      consignments: Desk.list_consignments("new") |> Enum.take(5),
      invoices: Auctions.list_invoices(limit: 5),
      now: DateTime.utc_now()
    )
  end

  @impl true
  def handle_event("decide", %{"id" => id, "decision" => decision}, socket) do
    req = Desk.get_limit_request!(id)

    case Desk.decide_limit(req, socket.assigns.current_user, decision) do
      {:ok, _} ->
        verb =
          if decision == "approved",
            do: "raised to #{Format.money(req.amount)}",
            else: "left as it is"

        {:noreply, socket |> put_flash(:info, "#{req.user.name}'s limit #{verb}.") |> load()}

      {:error, :not_allowed} ->
        {:noreply, put_flash(socket, :error, "Deciding limits needs the client services role.")}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, "That request was already decided.") |> load()}
    end
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, load(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.desk flash={@flash} current_user={@current_user} active={:dashboard}>
      <header class="desk-head">
        <div>
          <p class="label">{Format.date(@now)}</p>
          <h1>Today</h1>
        </div>
      </header>

      <dl class="desk-stats">
        <div>
          <dt class="label">Sales running</dt><dd class="serif num">{length(@sales)}</dd>
        </div>
        <div>
          <dt class="label">Bids, last hour</dt><dd class="serif num">{@bids_hour}</dd>
        </div>
        <div>
          <dt class="label">Bidders online</dt><dd class="serif num">{@online}</dd>
        </div>
        <div>
          <dt class="label">Limit requests</dt><dd class={["serif num", @limits != [] && "attention"]}>
            {length(@limits)}
          </dd>
        </div>
        <div>
          <dt class="label">New consignments</dt><dd class="serif num">{length(@consignments)}</dd>
        </div>
      </dl>

      <div class="desk-grid">
        <section class="desk-card" aria-labelledby="d-sales">
          <h2 id="d-sales" class="desk-card-title">Sales now</h2>
          <ul class="desk-list">
            <li :for={s <- @sales}>
              <div>
                <span class={["chip", sale_chip(s)]}>{sale_status(s)}</span>
                <strong>{s.number}</strong> {s.title}
                <p class="muted">{sale_when(s, @now)}</p>
              </div>
              <div class="desk-list-actions">
                <a :if={Sale.live?(s)} class="btn small" href={~p"/desk/rostrum/#{s.number}"}>Rostrum</a>
                <a class="btn ghost small" href={~p"/desk/sales/#{s.number}"}>Open</a>
              </div>
            </li>
          </ul>
        </section>

        <section class="desk-card" aria-labelledby="d-closing">
          <h2 id="d-closing" class="desk-card-title">Closing next</h2>
          <p :if={@closing == []} class="muted">No online lots are open just now.</p>
          <ul class="desk-list">
            <li :for={l <- @closing}>
              <div>
                <strong>{l.sale.number} · lot {l.number}</strong>
                <em class="serif">{l.work.title}</em>
                <p class="muted">
                  {Format.money(l.current_bid || l.opening_bid)} · {Format.count(
                    l.bid_count,
                    "bid",
                    "bids"
                  )} · reserve {Format.money(l.reserve)} {if Lot.reserve_met?(l),
                    do: "met",
                    else: "not met"}
                </p>
              </div>
              <.countdown id={"dcd-#{l.id}"} at={l.closes_at} now={@now} />
            </li>
          </ul>
        </section>

        <section class="desk-card wide" aria-labelledby="d-limits">
          <h2 id="d-limits" class="desk-card-title">Limit requests</h2>
          <p :if={@limits == []} class="muted">None waiting.</p>
          <div :if={@limits != []} class="table-scroll">
            <table class="table">
              <thead>
                <tr>
                  <th>Bidder</th><th class="num">Now</th><th class="num">Asked for</th><th>Note</th><th>
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr :for={r <- @limits}>
                  <td>
                    <strong>{r.user.name}</strong><br /><span class="muted">Paddle {r.user.paddle} · {r.user.country}</span>
                  </td>
                  <td class="num">{Format.money(r.user.bid_limit)}</td>
                  <td class="num">{Format.money(r.amount)}</td>
                  <td>{r.reason || "—"}</td>
                  <td class="desk-row-actions">
                    <button
                      class="btn small"
                      phx-click="decide"
                      phx-value-id={r.id}
                      phx-value-decision="approved"
                    >Approve</button>
                    <button
                      class="btn ghost small"
                      phx-click="decide"
                      phx-value-id={r.id}
                      phx-value-decision="declined"
                    >Decline</button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section class="desk-card" aria-labelledby="d-cons">
          <h2 id="d-cons" class="desk-card-title">New consignments</h2>
          <p :if={@consignments == []} class="muted">Nothing new.</p>
          <ul class="desk-list">
            <li :for={c <- @consignments}>
              <div>
                <strong>{c.artist_name}</strong>{if c.title, do: ", #{c.title}"}
                <p class="muted">{c.name} · {Format.short_datetime(c.inserted_at)}</p>
              </div>
              <a class="btn ghost small" href={~p"/desk/consignments?#{[open: c.id]}"}>Review</a>
            </li>
          </ul>
        </section>

        <section class="desk-card" aria-labelledby="d-inv">
          <h2 id="d-inv" class="desk-card-title">Latest invoices</h2>
          <p :if={@invoices == []} class="muted">No invoices yet.</p>
          <ul class="desk-list">
            <li :for={i <- @invoices}>
              <div>
                <strong>{i.number}</strong>
                <em class="serif">{i.lot.work.title}</em><p class="muted">
                  {i.user.name} · {Format.money(i.total)}
                </p>
              </div>
              <span class={["chip", i.status == "paid" && "leading", i.status == "due" && "outbid"]}>{String.capitalize(
                i.status
              )}</span>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.desk>
    """
  end
end
