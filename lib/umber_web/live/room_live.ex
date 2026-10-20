defmodule UmberWeb.RoomLive do
  use UmberWeb, :live_view

  alias Umber.{Catalogue, Events, Auctions, Repo}
  alias Umber.Accounts.User
  alias Umber.Catalogue.{Sale, Lot, Artist}
  alias Umber.Auctions.{Live, LiveSession}
  alias UmberWeb.{Meta, Presence, SaleLive}

  @impl true
  def mount(%{"number" => number}, _session, socket) do
    case Catalogue.get_sale_by_number(number) do
      %Sale{format: "live", published: true} = sale ->
        topic = "room:#{sale.id}"

        if connected?(socket) do
          Events.subscribe("live:#{sale.id}")
          Events.subscribe("sale:#{sale.id}")
          Phoenix.PubSub.subscribe(Umber.PubSub, topic)
          {:ok, _} = Presence.track(self(), topic, socket.id, %{})
        end

        lots = Catalogue.sale_lots(sale)

        {:ok,
         socket
         |> assign(sale: sale, lots: lots, topic: topic, error: nil, now: DateTime.utc_now())
         |> assign(session: Live.get(sale.id), watchers: watchers(topic))
         |> assign_block()
         |> Meta.put(
           title: "The saleroom, live: #{sale.title}",
           description:
             "Watch and bid in Umber's live sale #{sale.number}, #{sale.title}, from your phone.",
           path: ~p"/sales/#{sale.number}/room",
           image:
             lots
             |> Enum.max_by(& &1.estimate_high, fn -> nil end)
             |> then(&(&1 && &1.work.image))
         )}

      %Sale{published: true} = sale ->
        {:ok, push_navigate(socket, to: Sale.path(sale))}

      _ ->
        raise UmberWeb.NotFound
    end
  end

  defp watchers(topic), do: topic |> Presence.list() |> map_size()

  defp assign_block(socket) do
    s = socket.assigns.session
    lot = s && s.lot_id && Enum.find(socket.assigns.lots, &(&1.id == s.lot_id))

    last =
      socket.assigns.lots
      |> Enum.filter(&Lot.finished?/1)
      |> Enum.max_by(
        &{(&1.closed_at && DateTime.to_unix(&1.closed_at, :microsecond)) || 0, &1.number},
        fn -> nil end
      )

    assign(socket, block: lot || (s && s.state in ~w(sold passed) && last), last_sold: last)
  end

  ## Bidding

  @impl true
  def handle_event("bid", %{"asking" => asking}, socket) do
    with %User{kind: "bidder"} = user <- socket.assigns.current_user,
         {asking, ""} <- Integer.parse(asking) do
      user = Umber.Accounts.get_user!(user.id)

      case Auctions.live_bid(socket.assigns.sale.id, user, asking) do
        {:ok, %{session: s}} ->
          {:noreply,
           socket |> assign(session: s, error: nil, current_user: user) |> assign_block()}

        {:error, reason} ->
          {:noreply,
           assign(socket, error: error_text(reason), session: Live.get(socket.assigns.sale.id))}
      end
    else
      nil ->
        {:noreply,
         push_navigate(socket,
           to: ~p"/signin?#{[return_to: ~p"/sales/#{socket.assigns.sale.number}/room"]}"
         )}

      %User{} ->
        {:noreply,
         assign(socket, error: "Staff accounts cannot bid. Take the rostrum from the desk.")}

      _ ->
        {:noreply, socket}
    end
  end

  defp error_text({:asking_moved, asking}),
    do: "Another bid came in first. The auctioneer is now asking #{Format.money(asking)}."

  defp error_text(:already_leading), do: "The bid is already yours."

  defp error_text({:over_limit, limit}),
    do: "That is above your bidding limit of #{Format.money(limit)}."

  defp error_text(:not_taking_bids), do: "The auctioneer is not taking bids on this lot any more."
  defp error_text(_), do: "That bid did not reach the rostrum. Please try again."

  ## Live updates

  @impl true
  def handle_info({:live, e}, socket) do
    if is_nil(socket.assigns.session) or e.version >= socket.assigns.session.version do
      session = Live.get(socket.assigns.sale.id)

      error =
        if socket.assigns.error && e.state in ~w(sold passed), do: nil, else: socket.assigns.error

      {:noreply,
       socket |> assign(session: session, error: error, now: DateTime.utc_now()) |> assign_block()}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:lot, e}, socket) do
    lots =
      Enum.map(
        socket.assigns.lots,
        &if(&1.id == e.id and e.version >= &1.version, do: SaleLive.apply_event(&1, e), else: &1)
      )

    {:noreply, socket |> assign(lots: lots) |> assign_block()}
  end

  def handle_info(:sale_changed, socket) do
    sale = Repo.get!(Sale, socket.assigns.sale.id)

    {:noreply,
     socket
     |> assign(sale: sale, lots: Catalogue.sale_lots(sale), session: Live.get(sale.id))
     |> assign_block()}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, assign(socket, watchers: watchers(socket.assigns.topic))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## View

  defp leader_text(%LiveSession{leader_id: nil}, _user), do: nil
  defp leader_text(%LiveSession{leader_id: id}, %User{id: id}), do: {:mine, "With you"}
  defp leader_text(%LiveSession{leader_source: "room"}, _), do: {:other, "In the room"}
  defp leader_text(%LiveSession{leader_source: "absentee"}, _), do: {:other, "On the book"}
  defp leader_text(%LiveSession{leader_source: "online"}, _), do: {:other, "Online"}
  defp leader_text(_, _), do: nil

  @impl true
  def render(assigns) do
    s = assigns.session
    user = assigns.current_user
    taking = s && LiveSession.taking_bids?(s)
    lot = assigns.block

    assigns =
      assign(assigns,
        state: (s && s.state) || "waiting",
        taking: taking,
        leader: s && leader_text(s, user),
        can_bid: taking && match?(%User{kind: "bidder"}, user) && s.leader_id != user.id,
        over_limit: taking && match?(%User{kind: "bidder"}, user) && s.asking > user.bid_limit,
        lot: lot,
        upcoming: Enum.filter(assigns.lots, &(&1.status == "pending")),
        done: assigns.lots |> Enum.filter(&Lot.finished?/1) |> Enum.reverse()
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      live_now={@live_now}
      notices={@notices}
      night
    >
      <div
        class="room"
        id="room"
        phx-hook="Room"
        data-state={@state}
        data-lot={@lot && @lot.id}
        data-version={@session && @session.version}
      >
        <div class="room-top wrap">
          <p class="label">
            <span :if={@sale.status == "live"} class="chip live">Live</span>
            <span :if={@sale.status == "upcoming"} class="chip">Starts {Format.clock(@sale.starts_at)}</span>
            <span :if={@sale.status == "closed"} class="chip plain">Sale ended</span>
            Sale {@sale.number} · {@sale.title}
          </p>
          <p class="room-watchers label" aria-live="off">
            <span><span class="num">{@watchers}</span> watching here</span>
            <button type="button" class="sound-toggle" data-sound aria-pressed="false">Sound off</button>
          </p>
        </div>

        <div class="room-main">
          <div class="room-stage" data-state={@state}>
            <div class="spotlight" aria-hidden="true"></div>
            <div class="floor" aria-hidden="true"></div>
            <%= if @lot do %>
              <div class="room-work" id={"room-work-#{@lot.id}"}>
                <.work_image
                  work={@lot.work}
                  sizes="(min-width: 1024px) 50vw, 80vw"
                  loading="eager"
                  priority
                />
              </div>
              <div :if={@state == "sold"} class="stamp" id={"stamp-#{@lot.id}"} aria-hidden="true">
                <span class="stamp-word">Sold</span>
                <span class="stamp-price num">{Format.money(
                  @lot.hammer || (@session && @session.current_bid)
                )}</span>
              </div>
              <div
                :if={@state == "passed"}
                class="stamp passed"
                id={"passed-#{@lot.id}"}
                aria-hidden="true"
              >
                <span class="stamp-word">Passed</span>
              </div>
            <% else %>
              <div class="room-waiting">
                <%= cond do %>
                  <% @sale.status == "upcoming" -> %>
                    <p class="label">The sale begins</p>
                    <p class="room-wait-time serif num">{Format.clock(@sale.starts_at)}</p>
                    <.countdown id="room-start" at={@sale.starts_at} now={@now} prefix="in" />
                  <% @sale.status == "closed" or @state == "ended" -> %>
                    <p class="label">The sale has ended</p>
                    <p class="room-wait-time serif">Thank you.</p>
                  <% true -> %>
                    <p class="label">The auctioneer is at the rostrum</p>
                    <p class="room-wait-time serif">A moment, please.</p>
                <% end %>
              </div>
            <% end %>
          </div>

          <aside class="room-panel" aria-label="The lot on the block">
            <%= if @lot do %>
              <div class="room-lot">
                <p class="label">
                  Lot <span class="num">{@lot.number}</span>
                  of <span class="num">{length(@lots)}</span>
                </p>
                <p class="room-artist">
                  {@lot.work.artist.name}
                  <span :if={Artist.dates(@lot.work.artist)} class="dates">({Artist.dates(
                    @lot.work.artist
                  )})</span>
                </p>
                <h1 class="room-title">
                  <em>{@lot.work.title}</em>, <span class="num">{@lot.work.year}</span>
                </h1>
                <.estimate lot={@lot} />
              </div>

              <div class="room-bid" aria-live="polite">
                <p class="label">
                  {if @session && @session.current_bid, do: "Bid in hand", else: "Asking to open"}
                </p>
                <p class="room-amount serif">
                  <span
                    id="room-amount"
                    phx-hook="Odometer"
                    phx-update="ignore"
                    data-value={(@session && (@session.current_bid || @session.asking)) || ""}
                    data-prefix="KES "
                  >
                    {Format.money(@session && (@session.current_bid || @session.asking))}
                  </span>
                </p>
                <p :if={@leader} class="room-leader">
                  <span class={["chip", elem(@leader, 0) == :mine && "leading"]}>{elem(@leader, 1)}</span>
                </p>
              </div>

              <p :if={@session && @session.call} class="room-call" id={"call-#{@session.version}"}>
                <span class="label">Auctioneer</span>
                <span class="serif">{@session.call}</span>
              </p>

              <div class="room-actions">
                <%= cond do %>
                  <% @state in ~w(sold passed) -> %>
                    <p class="room-note">Next lot in a moment.</p>
                  <% is_nil(@current_user) and @taking -> %>
                    <a
                      class="btn brass block bid-big"
                      href={~p"/signin?#{[return_to: ~p"/sales/#{@sale.number}/room"]}"}
                    >Sign in to bid</a>
                    <a
                      class="btn ghost block"
                      href={~p"/register?#{[return_to: ~p"/sales/#{@sale.number}/room"]}"}
                    >Register, in a minute</a>
                  <% @over_limit -> %>
                    <p class="room-note">
                      The asking price is above your limit of {Format.money(@current_user.bid_limit)}.
                    </p>
                    <a class="btn ghost block" href={~p"/account/limit"}>Ask for a higher limit</a>
                  <% @can_bid -> %>
                    <button
                      type="button"
                      class={["btn brass block bid-big", @state == "warning" && "warning"]}
                      phx-click="bid"
                      phx-value-asking={@session.asking}
                      id="room-bid-button"
                    >
                      <span class="ring" aria-hidden="true"></span>
                      <span class="bid-big-label">Bid</span>
                      <span class="bid-big-amount num">{Format.money(@session.asking)}</span>
                    </button>
                    <p class="room-note">
                      {if @state == "warning",
                        do: "Fair warning. Bid now or the hammer falls.",
                        else: "One tap places the bid at the asking price."}
                    </p>
                  <% @taking and @session.leader_id == (@current_user && @current_user.id) -> %>
                    <p class="room-note mine">
                      The bid is yours. The auctioneer is asking {Format.money(@session.asking)} of the room.
                    </p>
                  <% @taking -> %>
                    <p class="room-note">Staff accounts watch only.</p>
                  <% true -> %>
                    <p class="room-note">Bidding opens when the auctioneer calls the lot.</p>
                <% end %>
                <p :if={@error} class="error-text" role="alert">{@error}</p>
              </div>
              <a class="text-link room-lot-link" href={Lot.path(@lot)}>Catalogue entry for lot {@lot.number}
              <span class="arrow" aria-hidden="true">→</span></a>
            <% else %>
              <div class="room-lot">
                <p class="label">{Format.count(length(@lots), "lot", "lots")}</p>
                <h1 class="room-title">{@sale.title}</h1>
                <p class="room-note">{@sale.summary}</p>
                <a :if={@sale.status == "upcoming"} class="btn ghost block" href={Sale.path(@sale)}>Leave absentee bids in the catalogue</a>
              </div>
            <% end %>
          </aside>
        </div>

        <section class="room-strip wrap" aria-label="Lots in this sale">
          <div :if={@upcoming != []} class="strip-group">
            <h2 class="label">To come</h2>
            <ol class="strip">
              <li :for={l <- Enum.take(@upcoming, 6)}>
                <a href={Lot.path(l)}>
                  <span class="strip-thumb"><.work_image work={l.work} sizes="80px" /></span>
                  <span class="strip-no serif num">{l.number}</span>
                  <span class="strip-text"><em>{l.work.title}</em><br /><span class="muted">{Format.short_money(
                    l.estimate_low
                  )}–{Format.short_money(l.estimate_high) |> String.replace("KES ", "")}</span></span>
                </a>
              </li>
            </ol>
          </div>
          <div :if={@done != []} class="strip-group">
            <h2 class="label">Sold and passed</h2>
            <ol class="strip">
              <li :for={l <- Enum.take(@done, 6)}>
                <a href={Lot.path(l)}>
                  <span class="strip-thumb"><.work_image work={l.work} sizes="80px" /></span>
                  <span class="strip-no serif num">{l.number}</span>
                  <span class="strip-text">
                    <em>{l.work.title}</em><br />
                    <span :if={l.status == "sold"} class="num">{Format.money(l.hammer)}</span>
                    <span :if={l.status != "sold"} class="muted">Passed</span>
                  </span>
                </a>
              </li>
            </ol>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
