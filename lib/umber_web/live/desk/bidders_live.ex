defmodule UmberWeb.Desk.BiddersLive do
  use UmberWeb, :live_view

  alias Umber.{Accounts, Desk, Events}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe("desk")
    {:ok, socket |> assign(page_title: "Bidders", q: "") |> load()}
  end

  defp load(socket) do
    assign(socket,
      bidders: Accounts.list_bidders(q: socket.assigns.q),
      limits: Desk.list_pending_limits()
    )
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket),
    do: {:noreply, socket |> assign(q: q) |> load()}

  def handle_event("decide", %{"id" => id, "decision" => decision}, socket) do
    req = Desk.get_limit_request!(id)

    case Desk.decide_limit(req, socket.assigns.current_user, decision) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Limit request #{decision}.") |> load()}

      {:error, :not_allowed} ->
        {:noreply, put_flash(socket, :error, "Deciding limits needs the client services role.")}

      {:error, _} ->
        {:noreply, load(socket)}
    end
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, load(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.desk flash={@flash} current_user={@current_user} active={:bidders}>
      <header class="desk-head">
        <div>
          <p class="label">Client services</p>
          <h1>Bidders</h1>
        </div>
        <form phx-change="search" phx-submit="search" class="desk-search" role="search">
          <label for="bidder-q" class="sr-only">Search by name, email or paddle</label>
          <input
            id="bidder-q"
            name="q"
            value={@q}
            class="input"
            placeholder="Name, email or paddle"
            phx-debounce="250"
            autocomplete="off"
          />
        </form>
      </header>

      <section
        :if={@limits != []}
        class="desk-card"
        aria-labelledby="b-limits"
        style="margin-bottom: 24px"
      >
        <h2 id="b-limits" class="desk-card-title">Waiting for a decision</h2>
        <div class="table-scroll">
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
                  <strong>{r.user.name}</strong><br /><span class="muted">Paddle {r.user.paddle}</span>
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

      <div class="desk-card">
        <p :if={@bidders == []} class="muted">No bidders match "{@q}".</p>
        <div :if={@bidders != []} class="table-scroll">
          <table class="table">
            <thead>
              <tr>
                <th class="num">Paddle</th><th>Name</th><th>Email</th><th>Country</th><th class="num">
                  Limit
                </th><th>Joined</th><th>Last seen</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={u <- @bidders}>
                <td class="num serif">{u.paddle}</td>
                <td>{u.name}</td>
                <td>{u.email}</td>
                <td>{u.country}</td>
                <td class="num">{Format.money(u.bid_limit)}</td>
                <td class="muted">{Format.short_datetime(u.inserted_at)}</td>
                <td class="muted">
                  {if u.last_seen_at, do: Format.short_datetime(u.last_seen_at), else: "—"}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.desk>
    """
  end
end
