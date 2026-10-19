defmodule UmberWeb.AccountLive do
  use UmberWeb, :live_view

  alias Umber.{Auctions, Desk, Events, Accounts}
  alias Umber.Catalogue.Lot
  alias Umber.Desk.LimitRequest
  alias UmberWeb.Meta

  @titles %{
    bids: "Your bids",
    watchlist: "Watchlist",
    purchases: "Purchases",
    limit: "Bidding limit",
    settings: "Settings"
  }

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if Umber.Accounts.User.staff?(user) do
      {:ok, push_navigate(socket, to: ~p"/desk")}
    else
      if connected?(socket), do: Events.subscribe("user:#{user.id}")
      {:ok, assign(socket, now: DateTime.utc_now(), subscribed: MapSet.new())}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    action = socket.assigns.live_action

    {:noreply,
     socket
     |> Meta.put(title: @titles[action], path: path(action))
     |> load(action)}
  end

  defp path(:bids), do: "/account"
  defp path(action), do: "/account/#{action}"

  defp load(socket, action) do
    user = Accounts.get_user!(socket.assigns.current_user.id)
    socket = assign(socket, current_user: user, now: DateTime.utc_now())

    case action do
      :bids ->
        active = Auctions.active_bids(user)
        follow(socket, active) |> assign(active: active, finished: Auctions.finished_bids(user))

      :watchlist ->
        lots = Auctions.watchlist(user)
        follow(socket, lots) |> assign(lots: lots)

      :purchases ->
        assign(socket,
          invoices: Auctions.invoices(user),
          consignments: Desk.user_consignments(user)
        )

      :limit ->
        assign(socket,
          pending: Desk.pending_limit_request(user),
          requests: Desk.limit_requests(user),
          form: to_form(Desk.change_limit_request(user), as: :request),
          amounts: Enum.filter(LimitRequest.amounts(), &(&1 > user.bid_limit))
        )

      :settings ->
        assign(socket,
          push_ready: Application.get_env(:umber, :vapid) != nil,
          vapid: Umber.Notify.public_key()
        )
    end
  end

  # Live updates for the lots on screen.
  defp follow(socket, lots) do
    if connected?(socket) do
      new =
        lots |> Enum.map(& &1.id) |> MapSet.new() |> MapSet.difference(socket.assigns.subscribed)

      Enum.each(new, &Events.subscribe("lot:#{&1}"))
      assign(socket, subscribed: MapSet.union(socket.assigns.subscribed, new))
    else
      socket
    end
  end

  @impl true
  def handle_event("request", %{"request" => attrs}, socket) do
    case Desk.request_limit(socket.assigns.current_user, attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Your request is with client services. You will see their answer here."
         )
         |> load(:limit)}

      {:error, :already_pending} ->
        {:noreply, put_flash(socket, :error, "You already have a request waiting.")}

      {:error, cs} ->
        {:noreply, assign(socket, form: to_form(Map.put(cs, :action, :insert), as: :request))}
    end
  end

  def handle_event("push-subscribe", sub, socket) do
    case Umber.Notify.subscribe(socket.assigns.current_user, sub) do
      {:ok, _} ->
        {:reply, %{ok: true}, put_flash(socket, :info, "Notifications are on for this device.")}

      _ ->
        {:reply, %{ok: false},
         put_flash(socket, :error, "This browser could not turn notifications on.")}
    end
  end

  def handle_event("push-unsubscribe", %{"endpoint" => endpoint}, socket) do
    Umber.Notify.unsubscribe(socket.assigns.current_user, endpoint)
    {:reply, %{ok: true}, put_flash(socket, :info, "Notifications are off for this device.")}
  end

  def handle_event("unwatch", %{"id" => id}, socket) do
    lot = Enum.find(socket.assigns.lots, &(to_string(&1.id) == id))
    if lot, do: Auctions.unwatch(socket.assigns.current_user, lot)
    {:noreply, load(socket, :watchlist)}
  end

  @impl true
  def handle_info({:lot, _e}, socket), do: {:noreply, load(socket, socket.assigns.live_action)}

  def handle_info({:limit_decided, decision, amount}, socket) do
    msg =
      if decision == "approved",
        do: "Your bidding limit is now #{Format.money(amount)}.",
        else: "Client services could not raise your limit this time."

    {:noreply,
     socket
     |> put_flash(if(decision == "approved", do: :info, else: :error), msg)
     |> load(socket.assigns.live_action)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp bid_state(lot, user) do
    cond do
      lot.status == "pending" -> {"plain", "Absentee bid left"}
      lot.leader_id == user.id -> {"leading", "With you"}
      true -> {"outbid", "Outbid"}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} live_now={@live_now} notices={@notices}>
      <header class="page-head wrap account-head">
        <div>
          <p class="label">Your account</p>
          <h1>{Umber.Accounts.User.first_name(@current_user)}'s bids</h1>
        </div>
        <div class="paddle-card" aria-label={"Paddle #{@current_user.paddle}"}>
          <span class="label">Paddle</span>
          <span class="serif num">{@current_user.paddle}</span>
          <span class="paddle-limit">Limit {Format.money(@current_user.bid_limit)}</span>
        </div>
      </header>

      <nav class="wrap tabs" aria-label="Account">
        <.link patch={~p"/account"} aria-current={@live_action == :bids && "page"}>Bids</.link>
        <.link patch={~p"/account/watchlist"} aria-current={@live_action == :watchlist && "page"}>Watchlist</.link>
        <.link patch={~p"/account/purchases"} aria-current={@live_action == :purchases && "page"}>Purchases</.link>
        <.link patch={~p"/account/limit"} aria-current={@live_action == :limit && "page"}>Bidding limit</.link>
        <.link patch={~p"/account/settings"} aria-current={@live_action == :settings && "page"}>Settings</.link>
        <.link href={~p"/signout"} method="delete" class="tabs-signout">Sign out</.link>
      </nav>

      <div class="wrap account-body">
        <%= case @live_action do %>
          <% :bids -> %>
            <section aria-labelledby="active-title">
              <h2 id="active-title" class="account-h">Bidding now</h2>
              <div :if={@active == []} class="empty">
                <h3>You are not bidding on anything just now.</h3>
                <p>Lots you bid on appear here, with whether the bid is still yours.</p>
                <a class="btn" href={~p"/sales"}>See current sales
                <span class="arrow" aria-hidden="true">→</span></a>
              </div>
              <ul :if={@active != []} class="account-lots">
                <li :for={lot <- @active}>
                  <a href={Lot.path(lot)} class="account-lot">
                    <span class="al-thumb"><.work_image work={lot.work} sizes="96px" /></span>
                    <span class="al-main">
                      <span class="label">Sale {lot.sale.number} · Lot {lot.number}</span>
                      <span class="serif al-title"><em>{lot.work.title}</em></span>
                      <span class="muted">{lot.work.artist.name}</span>
                    </span>
                    <span class="al-side">
                      <span class={["chip", elem(bid_state(lot, @current_user), 0)]}>{elem(
                        bid_state(lot, @current_user),
                        1
                      )}</span>
                      <span class="num al-bid">{Format.money(lot.current_bid || lot.opening_bid)}</span>
                      <.countdown
                        :if={lot.closes_at && lot.status == "open"}
                        id={"acd-#{lot.id}"}
                        at={lot.closes_at}
                        now={@now}
                      />
                    </span>
                  </a>
                </li>
              </ul>
            </section>
            <section :if={@finished != []} aria-labelledby="done-title" class="account-section">
              <h2 id="done-title" class="account-h">Finished</h2>
              <ul class="account-lots">
                <li :for={lot <- @finished}>
                  <a href={Lot.path(lot)} class="account-lot">
                    <span class="al-thumb"><.work_image work={lot.work} sizes="96px" /></span>
                    <span class="al-main">
                      <span class="label">Sale {lot.sale.number} · Lot {lot.number}</span>
                      <span class="serif al-title"><em>{lot.work.title}</em></span>
                      <span class="muted">{lot.work.artist.name}</span>
                    </span>
                    <span class="al-side">
                      <%= cond do %>
                        <% lot.buyer_id == @current_user.id -> %>
                          <span class="chip leading">You won</span>
                        <% lot.status == "sold" -> %>
                          <span class="chip plain">Sold to another bidder</span>
                        <% true -> %>
                          <span class="chip plain">Not sold</span>
                      <% end %>
                      <span :if={lot.hammer} class="num al-bid">{Format.money(lot.hammer)}</span>
                    </span>
                  </a>
                </li>
              </ul>
            </section>
          <% :watchlist -> %>
            <h2 class="account-h">Lots you watch</h2>
            <div :if={@lots == []} class="empty">
              <h3>Your watchlist is empty.</h3>
              <p>
                Press "Watch this lot" on any lot, and we will tell you five minutes before it closes.
              </p>
              <a class="btn" href={~p"/sales"}>See current sales
              <span class="arrow" aria-hidden="true">→</span></a>
            </div>
            <ul :if={@lots != []} class="account-lots">
              <li :for={lot <- @lots}>
                <div class="account-lot">
                  <a href={Lot.path(lot)} class="al-thumb"><.work_image work={lot.work} sizes="96px" /></a>
                  <a href={Lot.path(lot)} class="al-main">
                    <span class="label">Sale {lot.sale.number} · Lot {lot.number}</span>
                    <span class="serif al-title"><em>{lot.work.title}</em></span>
                    <span class="muted">{lot.work.artist.name}</span>
                  </a>
                  <span class="al-side">
                    <span :if={Lot.finished?(lot)} class="chip plain">{if lot.status == "sold",
                      do: "Sold #{Format.money(lot.hammer)}",
                      else: "Closed"}</span>
                    <.countdown
                      :if={lot.closes_at && lot.status == "open"}
                      id={"wcd-#{lot.id}"}
                      at={lot.closes_at}
                      now={@now}
                    />
                    <span :if={!Lot.finished?(lot)} class="num al-bid">{Format.money(
                      lot.current_bid || lot.opening_bid
                    )}</span>
                    <button
                      type="button"
                      class="btn ghost small"
                      phx-click="unwatch"
                      phx-value-id={lot.id}
                    >Stop watching</button>
                  </span>
                </div>
              </li>
            </ul>
          <% :purchases -> %>
            <h2 class="account-h">Lots you bought</h2>
            <div :if={@invoices == []} class="empty">
              <h3>Nothing yet.</h3>
              <p>When you win a lot, its invoice is here at once.</p>
            </div>
            <div :if={@invoices != []} class="table-scroll">
              <table class="table">
                <thead>
                  <tr>
                    <th>Invoice</th><th>Lot</th><th class="num">Total due (KES)</th><th>Status</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={inv <- @invoices}>
                    <td><a href={~p"/account/invoices/#{inv.number}"}>{inv.number}</a></td>
                    <td>
                      <em class="serif">{inv.lot.work.title}</em><br /><span class="muted">Sale {inv.lot.sale.number}, lot {inv.lot.number}</span>
                    </td>
                    <td class="num">{Format.thousands(inv.total)}</td>
                    <td>
                      <span class={[
                        "chip",
                        inv.status == "paid" && "leading",
                        inv.status == "due" && "outbid"
                      ]}>{if inv.status == "paid", do: "Paid", else: "Due"}</span>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
            <section :if={@consignments != []} class="account-section">
              <h2 class="account-h">Works you asked us to sell</h2>
              <ul class="plain-list">
                <li :for={c <- @consignments}>
                  <strong>{c.artist_name}</strong>{if c.title, do: ", #{c.title}"} ·
                  <span class="muted">sent {Format.short_datetime(c.inserted_at)}</span>
                  <span class="chip plain">{consignment_status(c.status)}</span>
                </li>
              </ul>
            </section>
          <% :limit -> %>
            <div class="limit-grid">
              <div>
                <h2 class="account-h">Your bidding limit</h2>
                <p class="limit-now serif num">{Format.money(@current_user.bid_limit)}</p>
                <p class="muted">
                  The most you can bid on any one lot. It covers absentee maximums too.
                </p>
              </div>
              <div>
                <%= cond do %>
                  <% @pending -> %>
                    <div class="form-panel">
                      <p class="label">Waiting for client services</p>
                      <p class="serif limit-req">{Format.money(@pending.amount)}</p>
                      <p class="muted">
                        Asked {Format.short_datetime(@pending.inserted_at)}. You will see the answer here as soon as it is given.
                      </p>
                    </div>
                  <% @amounts == [] -> %>
                    <div class="form-panel">
                      <p>
                        Your limit is already our highest. For more, speak to a specialist at Umber House.
                      </p>
                    </div>
                  <% true -> %>
                    <.form for={@form} phx-submit="request" class="form-panel" id="limit-form">
                      <h3 class="form-title">Ask for a higher limit</h3>
                      <.input
                        field={@form[:amount]}
                        type="select"
                        label="New limit"
                        options={Enum.map(@amounts, &{Format.money(&1), &1})}
                        prompt="Choose an amount"
                      />
                      <.input
                        field={@form[:reason]}
                        type="textarea"
                        label="Anything we should know (optional)"
                        rows="3"
                        placeholder="For example, which lot you have in mind."
                      />
                      <button type="submit" class="btn block">Send the request</button>
                    </.form>
                <% end %>
                <ul :if={@requests != [] and !@pending} class="plain-list" style="margin-top: 20px">
                  <li :for={r <- @requests}>
                    {Format.money(r.amount)} · {Format.short_datetime(r.inserted_at)} ·
                    <span class={[
                      "chip",
                      r.status == "approved" && "leading",
                      r.status == "declined" && "outbid"
                    ]}>{String.capitalize(r.status)}</span>
                  </li>
                </ul>
              </div>
            </div>
          <% :settings -> %>
            <div class="limit-grid">
              <div>
                <h2 class="account-h">Notices</h2>
                <p class="muted">
                  While Umber is open in your browser, we tell you on screen when you are outbid, when you win, and five minutes before a lot you watch closes.
                </p>
              </div>
              <div
                class="form-panel"
                id="push-panel"
                phx-hook="Push"
                data-key={@vapid}
                data-ready={to_string(@push_ready)}
              >
                <h3 class="form-title">On this phone or computer</h3>
                <p class="muted" data-push-text>Get the same notices even when Umber is closed.</p>
                <button type="button" class="btn block" data-push-on>Turn on notifications</button>
                <button type="button" class="btn ghost block" data-push-off hidden>Turn off notifications</button>
                <p class="hint" data-push-status></p>
              </div>
            </div>
            <section class="account-section">
              <h2 class="account-h">Your details</h2>
              <dl class="details">
                <div>
                  <dt class="label">Name</dt><dd>{@current_user.name}</dd>
                </div>
                <div>
                  <dt class="label">Email</dt><dd>{@current_user.email}</dd>
                </div>
                <div>
                  <dt class="label">Country</dt><dd>{@current_user.country}</dd>
                </div>
                <div :if={@current_user.phone}>
                  <dt class="label">Phone</dt><dd>{@current_user.phone}</dd>
                </div>
              </dl>
            </section>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp consignment_status("new"), do: "Received"
  defp consignment_status("reviewing"), do: "With a specialist"
  defp consignment_status("invited"), do: "We would like to see it"
  defp consignment_status("declined"), do: "Not for us this time"
end
