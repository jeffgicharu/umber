defmodule UmberWeb.Desk.RostrumLive do
  use UmberWeb, :live_view

  alias Umber.{Catalogue, Events, Auctions, Repo}
  alias Umber.Accounts.User
  alias Umber.Catalogue.{Sale, Lot}
  alias Umber.Auctions.{Live, LiveSession, Increments}
  alias UmberWeb.{Presence, SaleLive}

  @impl true
  def mount(%{"number" => number}, _session, socket) do
    case Catalogue.get_sale_by_number(number) do
      %Sale{format: "live"} = sale ->
        if connected?(socket) do
          Events.subscribe("live:#{sale.id}")
          Events.subscribe("sale:#{sale.id}")
          Phoenix.PubSub.subscribe(Umber.PubSub, "room:#{sale.id}")
        end

        {:ok,
         socket
         |> assign(
           page_title: "Rostrum, sale #{sale.number}",
           sale: sale,
           lots: Catalogue.sale_lots(sale),
           paddle: "",
           error: nil
         )
         |> assign(
           session:
             Live.get(sale.id) || (sale.status in ~w(upcoming live) && Live.ensure(sale.id)) ||
               nil
         )
         |> refresh()}

      %Sale{} = sale ->
        {:ok,
         socket
         |> put_flash(:error, "Sale #{sale.number} is an online sale; it has no rostrum.")
         |> push_navigate(to: ~p"/desk/sales/#{sale.number}")}

      nil ->
        raise UmberWeb.NotFound
    end
  end

  defp refresh(socket) do
    s = socket.assigns.session
    lot = s && s.lot_id && Enum.find(socket.assigns.lots, &(&1.id == s.lot_id))

    assign(socket,
      lot: lot,
      book: s && Live.book_candidate(s),
      feed: (lot && Catalogue.bid_history(lot, 12)) || [],
      watchers: "room:#{socket.assigns.sale.id}" |> Presence.list() |> map_size(),
      next_lot: Enum.find(socket.assigns.lots, &(&1.status == "pending")),
      mine: s && s.auctioneer_id == socket.assigns.current_user.id,
      staffed_by_other:
        s && s.auctioneer_id && s.auctioneer_id != socket.assigns.current_user.id &&
          Live.staffed?(s, DateTime.utc_now())
    )
  end

  ## Commands

  @impl true
  def handle_event("heartbeat", _params, socket) do
    if socket.assigns.mine,
      do: Live.rostrum_heartbeat(socket.assigns.sale.id, socket.assigns.current_user)

    {:noreply, socket}
  end

  def handle_event("take", _p, socket),
    do:
      command(
        socket,
        :take,
        "You hold the rostrum. The automatic auctioneer waits while this page is open."
      )

  def handle_event("leave", _p, socket),
    do: command(socket, :leave, "You left the rostrum. The automatic auctioneer carries on.")

  def handle_event("open", _p, socket),
    do: command(socket, {:open, socket.assigns.next_lot.id, socket.assigns.next_lot.opening_bid})

  def handle_event("asking", %{"dir" => "up"}, socket),
    do:
      command(
        socket,
        {:asking, socket.assigns.session.asking + Increments.step(socket.assigns.session.asking)}
      )

  def handle_event("asking", %{"dir" => "down"}, socket),
    do: command(socket, {:asking, Increments.previous(socket.assigns.session.asking)})

  def handle_event("book", _p, socket), do: command(socket, :book)
  def handle_event("warn", _p, socket), do: command(socket, :warn)
  def handle_event("hammer", _p, socket), do: command(socket, :hammer)
  def handle_event("pause", _p, socket), do: command(socket, :pause)
  def handle_event("resume", _p, socket), do: command(socket, :resume)

  def handle_event("floor", %{"paddle" => paddle}, socket) do
    paddle =
      case Integer.parse(String.trim(paddle || "")) do
        {n, ""} -> n
        _ -> nil
      end

    command(assign(socket, paddle: ""), {:floor, paddle})
  end

  defp command(socket, cmd, ok_message \\ nil) do
    case Auctions.rostrum(socket.assigns.sale.id, socket.assigns.current_user, cmd) do
      {:ok, %{session: s}} ->
        socket = socket |> assign(session: s, error: nil) |> reload_lots() |> refresh()
        {:noreply, if(ok_message, do: put_flash(socket, :info, ok_message), else: socket)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(error: error_text(reason), session: Live.get(socket.assigns.sale.id))
         |> refresh()}
    end
  end

  defp error_text(:not_auctioneer), do: "Taking the rostrum needs the auctioneer role."
  defp error_text(:rostrum_taken), do: "Another member of staff holds the rostrum."
  defp error_text(:not_holding), do: "Take the rostrum first."
  defp error_text(:not_taking_bids), do: "No lot is taking bids."
  defp error_text(:already_leading), do: "That paddle already holds the bid."
  defp error_text(:unknown_paddle), do: "No bidder has that paddle number."
  defp error_text(:no_book_bid), do: "The book has nothing at this price."
  defp error_text(:no_bid), do: "There is no bid to warn on yet."
  defp error_text(:not_open), do: "Fair warning is given while the lot is open."

  defp error_text({:too_low, floor}),
    do: "The asking price cannot go below #{Format.money(floor)}."

  defp error_text(:lot_not_pending), do: "That lot has already been offered."
  defp error_text(other), do: "Not done: #{inspect(other)}"

  defp reload_lots(socket), do: assign(socket, lots: Catalogue.sale_lots(socket.assigns.sale))

  ## Updates from the room

  @impl true
  def handle_info({:live, e}, socket) do
    if is_nil(socket.assigns.session) or e.version >= socket.assigns.session.version,
      do: {:noreply, socket |> assign(session: Live.get(socket.assigns.sale.id)) |> refresh()},
      else: {:noreply, socket}
  end

  def handle_info({:lot, e}, socket) do
    lots =
      Enum.map(
        socket.assigns.lots,
        &if(&1.id == e.id and e.version >= &1.version, do: SaleLive.apply_event(&1, e), else: &1)
      )

    {:noreply, socket |> assign(lots: lots) |> refresh()}
  end

  def handle_info(:sale_changed, socket) do
    sale = Repo.get!(Sale, socket.assigns.sale.id)
    {:noreply, socket |> assign(sale: sale) |> reload_lots() |> refresh()}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket),
    do: {:noreply, refresh(socket)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp source(%{source: "room"}), do: "Room"
  defp source(%{source: "absentee"}), do: "Book"
  defp source(_), do: "Online"

  @impl true
  def render(assigns) do
    s = assigns.session

    assigns =
      assign(assigns,
        state: (s && s.state) || "waiting",
        taking: s && LiveSession.taking_bids?(s),
        auctioneer: User.role?(assigns.current_user, "auctioneer")
      )

    ~H"""
    <Layouts.desk flash={@flash} current_user={@current_user} active={:sales} wide>
      <div class="rostrum night" id="rostrum" phx-hook="Rostrum" data-mine={to_string(@mine == true)}>
        <header class="rostrum-head">
          <div>
            <p class="label">Rostrum · Sale {@sale.number}</p>
            <h1>{@sale.title}</h1>
          </div>
          <div class="rostrum-who">
            <span class="label"><span class="num">{@watchers}</span> in the online room</span>
            <%= cond do %>
              <% @mine -> %>
                <span class="chip leading">You hold the rostrum</span>
                <button class="btn ghost small" phx-click="leave">Leave the rostrum</button>
              <% @staffed_by_other -> %>
                <span class="chip outbid">Another member of staff holds the rostrum</span>
              <% @sale.status in ["upcoming", "live"] and @auctioneer -> %>
                <span class="chip plain">Automatic auctioneer</span>
                <button class="btn brass small" phx-click="take" id="take-rostrum">Take the rostrum</button>
              <% true -> %>
                <span class="chip plain">{if @sale.status == "closed",
                  do: "Sale ended",
                  else: "Watching"}</span>
            <% end %>
          </div>
        </header>

        <p :if={@error} class="error-text rostrum-error" role="alert">{@error}</p>

        <div class="rostrum-grid">
          <section class="rostrum-lot" aria-label="On the block">
            <%= if @lot do %>
              <div class="rostrum-image"><.work_image work={@lot.work} sizes="360px" /></div>
              <div>
                <p class="label">Lot {@lot.number} of {length(@lots)} · {@state}</p>
                <p class="rostrum-title serif"><em>{@lot.work.title}</em></p>
                <p class="muted">{@lot.work.artist.name}</p>
                <dl class="rostrum-facts">
                  <div>
                    <dt class="label">Estimate</dt><dd class="num">
                      {Format.estimate(@lot.estimate_low, @lot.estimate_high)}
                    </dd>
                  </div>
                  <div>
                    <dt class="label">Reserve</dt><dd class="num">
                      {Format.money(@lot.reserve)}{if Lot.reserve_met?(@lot), do: " · met"}
                    </dd>
                  </div>
                  <div>
                    <dt class="label">Opening</dt><dd class="num">
                      {Format.money(@lot.opening_bid)}
                    </dd>
                  </div>
                </dl>
              </div>
            <% else %>
              <p class="muted">
                {if @next_lot,
                  do: "Next: lot #{@next_lot.number}, #{@next_lot.work.title}.",
                  else: "Every lot has been offered."}
              </p>
            <% end %>
          </section>

          <section class="rostrum-price" aria-label="The bidding" aria-live="polite">
            <p class="label">Bid in hand</p>
            <p class="rostrum-amount serif num">{Format.money(@session && @session.current_bid)}</p>
            <p class="rostrum-leader">
              <%= if @session && @session.leader_id do %>
                {%{"online" => "Online", "room" => "In the room", "absentee" => "On the book"}[
                  @session.leader_source
                ]} · paddle {Repo.get(User, @session.leader_id).paddle}
              <% else %>
                No bid yet
              <% end %>
            </p>
            <p class="label" style="margin-top: 18px">Asking</p>
            <div class="rostrum-asking">
              <button
                class="btn ghost"
                phx-click="asking"
                phx-value-dir="down"
                disabled={!(@mine && @taking)}
                aria-label="Lower the asking price"
              >−</button>
              <span class="serif num">{Format.money(@session && @session.asking)}</span>
              <button
                class="btn ghost"
                phx-click="asking"
                phx-value-dir="up"
                disabled={!(@mine && @taking)}
                aria-label="Raise the asking price"
              >+</button>
            </div>
            <p class="rostrum-call serif">{@session && @session.call}</p>
          </section>

          <section class="rostrum-controls" aria-label="Controls">
            <button
              class="btn brass block"
              phx-click="open"
              disabled={!(@mine && @next_lot && @state in ~w(waiting sold passed))}
            >
              {if @next_lot, do: "Open lot #{@next_lot.number}", else: "No more lots"}
            </button>
            <form phx-submit="floor" class="floor-form">
              <label for="floor-paddle" class="label">Bid in the room · paddle optional</label>
              <div class="max-row">
                <input
                  id="floor-paddle"
                  name="paddle"
                  value={@paddle}
                  class="input"
                  inputmode="numeric"
                  placeholder="Paddle"
                  autocomplete="off"
                  disabled={!(@mine && @taking)}
                />
                <button class="btn" type="submit" disabled={!(@mine && @taking)}>Take the bid</button>
              </div>
            </form>
            <button class="btn ghost block" phx-click="book" disabled={!(@mine && @taking && @book)}>
              {if @book,
                do: "Bid from the book (up to #{Format.money(@book.amount)})",
                else: "Nothing on the book at this price"}
            </button>
            <div class="rostrum-pair">
              <button class="btn ghost" phx-click="warn" disabled={!(@mine && @state == "open")}>Fair warning</button>
              <button
                class="btn brass"
                phx-click="hammer"
                disabled={!(@mine && @taking)}
                id="hammer-button"
              >Hammer</button>
            </div>
            <div class="rostrum-pair">
              <button
                class="btn ghost"
                phx-click="pause"
                disabled={!(@mine && @state not in ~w(paused ended))}
              >Pause</button>
              <button class="btn ghost" phx-click="resume" disabled={!(@mine && @state == "paused")}>Resume</button>
            </div>
            <p class="hint">The hammer sells if the reserve is met and passes the lot if not.</p>
          </section>

          <section class="rostrum-feed" aria-label="Bids on this lot">
            <h2 class="label">Bids on this lot</h2>
            <p :if={@feed == []} class="muted">None yet.</p>
            <ol>
              <li :for={b <- @feed}>
                <span class="num serif">{Format.money(b.amount)}</span>
                <span>Paddle {b.paddle}</span>
                <span class="muted">{source(b)}</span>
                <span class="muted num">{Format.clock(b.at)}</span>
              </li>
            </ol>
          </section>
        </div>

        <section class="rostrum-lots" aria-label="All lots">
          <ol>
            <li :for={l <- @lots} class={["rl", l.status, @lot && l.id == @lot.id && "current"]}>
              <span class="num serif">{l.number}</span>
              <span class="rl-title"><em>{l.work.title}</em></span>
              <span class="num">{cond do
                l.status == "sold" -> Format.short_money(l.hammer)
                l.status == "unsold" -> "Passed"
                true -> Format.short_money(l.estimate_low)
              end}</span>
            </li>
          </ol>
        </section>
      </div>
    </Layouts.desk>
    """
  end
end
