defmodule UmberWeb.LotLive do
  use UmberWeb, :live_view

  alias Umber.{Catalogue, Events, Auctions, Repo}
  alias Umber.Accounts.User
  alias Umber.Catalogue.{Sale, Lot, Work, Artist}
  alias Umber.Auctions.{Increments, Timed, Invoice}
  alias UmberWeb.{Meta, SaleLive}

  @impl true
  def mount(%{"number" => number, "lot" => lot_number}, _session, socket) do
    with %Sale{published: true} = sale <- Catalogue.get_sale_by_number(number),
         %Lot{} = lot <- Catalogue.get_lot(sale, lot_number) do
      if connected?(socket) do
        Events.subscribe("lot:#{lot.id}")
        Events.subscribe("sale:#{sale.id}")
      end

      siblings = Catalogue.sale_lots(sale)

      {:ok,
       socket
       |> assign(
         sale: sale,
         lot: lot,
         siblings: siblings,
         confirm: nil,
         error: nil,
         view: "main",
         now: DateTime.utc_now()
       )
       |> assign_bidder()
       |> assign(history: Catalogue.bid_history(lot))
       |> Meta.put(
         title: "#{lot.work.title} by #{lot.work.artist.name}, lot #{lot.number}",
         description:
           "#{lot.work.artist.name}, #{lot.work.title}, #{lot.work.year}. #{lot.work.medium}, #{Work.dimensions(lot.work)}. Estimate #{Format.estimate(lot.estimate_low, lot.estimate_high)}. #{sale.title}, sale #{sale.number}.",
         path: Lot.path(lot),
         image: lot.work.image,
         image_alt: "#{lot.work.title} by #{lot.work.artist.name}",
         type: "product",
         json_ld: lot_json(lot)
       )}
    else
      _ -> raise UmberWeb.NotFound
    end
  end

  defp assign_bidder(socket) do
    user = socket.assigns.current_user
    lot = socket.assigns.lot

    assign(socket,
      own_max: Auctions.own_max(lot, user),
      watching: Auctions.watching?(user, lot),
      choices: if(user && user.kind == "bidder", do: Auctions.max_choices(lot, user), else: []),
      next_bid: Increments.next(lot.current_bid, lot.opening_bid),
      invoice: user && lot.buyer_id == user.id && Repo.get_by(Invoice, lot_id: lot.id)
    )
  end

  ## Events

  @impl true
  def handle_event("ask", _params, socket) do
    with {:ok, user} <- bidder(socket) do
      {:noreply,
       assign(socket,
         confirm: Increments.next(socket.assigns.lot.current_bid, socket.assigns.lot.opening_bid),
         error: nil,
         current_user: user
       )}
    else
      {:error, socket} -> {:noreply, socket}
    end
  end

  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, confirm: nil)}

  def handle_event("bid", %{"amount" => amount}, socket) do
    with {:ok, user} <- bidder(socket),
         {amount, ""} <- Integer.parse(amount) do
      socket |> assign(confirm: nil) |> place(user, :bid, amount)
    else
      {:error, socket} -> {:noreply, socket}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("max", %{"max" => amount}, socket) do
    with {:ok, user} <- bidder(socket),
         {amount, ""} <- Integer.parse(amount) do
      if Sale.live?(socket.assigns.sale),
        do: absentee(socket, user, amount),
        else: place(socket, user, :max, amount)
    else
      {:error, socket} -> {:noreply, socket}
      _ -> {:noreply, assign(socket, error: "Choose an amount for your maximum.")}
    end
  end

  def handle_event("watch", _params, socket) do
    case socket.assigns.current_user do
      nil ->
        {:noreply,
         push_navigate(socket, to: ~p"/signin?#{[return_to: Lot.path(socket.assigns.lot)]}")}

      user ->
        if socket.assigns.watching,
          do: Auctions.unwatch(user, socket.assigns.lot),
          else: Auctions.watch(user, socket.assigns.lot)

        {:noreply, assign(socket, watching: !socket.assigns.watching)}
    end
  end

  def handle_event("view", %{"view" => view}, socket) when view in ["main", "second"],
    do: {:noreply, assign(socket, view: view)}

  defp bidder(socket) do
    case socket.assigns.current_user do
      nil ->
        {:error,
         push_navigate(socket, to: ~p"/signin?#{[return_to: Lot.path(socket.assigns.lot)]}")}

      %User{kind: "bidder"} = user ->
        {:ok, Umber.Accounts.get_user!(user.id)}

      _ ->
        {:error, assign(socket, error: "Staff accounts cannot bid.")}
    end
  end

  defp place(socket, user, kind, amount) do
    case Auctions.bid(socket.assigns.lot, user, kind, amount) do
      {:ok, change} ->
        lot = %{
          socket.assigns.lot
          | current_bid: change.lot.current_bid,
            leader_id: change.lot.leader_id,
            bid_count: change.lot.bid_count,
            closes_at: change.lot.closes_at,
            extensions: change.lot.extensions,
            version: change.lot.version
        }

        message =
          cond do
            change.leading and kind == :max ->
              "Your maximum of #{Format.money(amount)} is in. You lead at #{Format.money(lot.current_bid)}."

            change.leading ->
              "Your bid of #{Format.money(amount)} leads."

            true ->
              "Another bidder's maximum is higher. The bid is now #{Format.money(lot.current_bid)}."
          end

        {:noreply,
         socket
         |> assign(lot: lot, error: nil, current_user: user)
         |> assign_bidder()
         |> assign(history: Catalogue.bid_history(lot))
         |> put_flash(if(change.leading, do: :info, else: :error), message)}

      {:error, reason} ->
        lot =
          Repo.get!(Lot, socket.assigns.lot.id)
          |> then(
            &%{
              socket.assigns.lot
              | current_bid: &1.current_bid,
                leader_id: &1.leader_id,
                bid_count: &1.bid_count,
                closes_at: &1.closes_at,
                status: &1.status,
                version: &1.version
            }
          )

        {:noreply, socket |> assign(lot: lot, error: error_text(reason)) |> assign_bidder()}
    end
  end

  defp absentee(socket, user, amount) do
    case Auctions.leave_absentee(socket.assigns.lot, user, amount) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(error: nil)
         |> assign_bidder()
         |> put_flash(
           :info,
           "Your absentee maximum of #{Format.money(amount)} is with the auctioneer."
         )}

      {:error, reason} ->
        {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  def error_text(:price_moved), do: "Another bid came in first. Here is the new price."
  def error_text(:already_leading), do: "You already lead this lot."
  def error_text({:too_low, min}), do: "The lowest bid now is #{Format.money(min)}."

  def error_text({:over_limit, limit}),
    do: "That is above your bidding limit of #{Format.money(limit)}."

  def error_text({:not_higher, max}),
    do: "Your maximum is already #{Format.money(max)}. Choose a higher amount to raise it."

  def error_text(:closed), do: "Bidding on this lot has closed."
  def error_text(:not_open), do: "Bidding on this lot has not opened yet."
  def error_text(:off_step), do: "Choose one of the amounts in the list."
  def error_text(:staff), do: "Staff accounts cannot bid."
  def error_text(_), do: "That bid could not be placed. Please try again."

  ## Live updates

  @impl true
  def handle_info({:lot, %{id: id} = e}, %{assigns: %{lot: %{id: id}}} = socket) do
    if e.version >= socket.assigns.lot.version do
      lot = SaleLive.apply_event(socket.assigns.lot, e)

      {:noreply,
       socket
       |> assign(
         lot: lot,
         confirm: confirm_still_valid(socket.assigns.confirm, lot),
         now: DateTime.utc_now()
       )
       |> assign_bidder()
       |> assign(history: Catalogue.bid_history(lot))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:lot, e}, socket) do
    siblings =
      Enum.map(
        socket.assigns.siblings,
        &if(&1.id == e.id and e.version >= &1.version, do: SaleLive.apply_event(&1, e), else: &1)
      )

    {:noreply, assign(socket, siblings: siblings)}
  end

  def handle_info(:sale_changed, socket) do
    sale = Repo.get!(Sale, socket.assigns.sale.id)
    lot = Catalogue.get_lot(sale, socket.assigns.lot.number)
    {:noreply, socket |> assign(sale: sale, lot: lot) |> assign_bidder()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # A pending confirmation is dropped if the price moved under it.
  defp confirm_still_valid(nil, _lot), do: nil

  defp confirm_still_valid(amount, lot),
    do: if(amount == Increments.next(lot.current_bid, lot.opening_bid), do: amount)

  defp lot_json(lot) do
    w = lot.work

    %{
      "@context" => "https://schema.org",
      "@type" => ["VisualArtwork", "Product"],
      "name" => w.title,
      "image" => Meta.image_url(w.image),
      "description" => w.description,
      "creator" =>
        if(Artist.anonymous?(w.artist),
          do: %{"@type" => "Organization", "name" => w.artist.name},
          else: %{"@type" => "Person", "name" => w.artist.name}
        ),
      "dateCreated" => w.year,
      "artMedium" => w.medium,
      "height" =>
        w.height_cm &&
          %{
            "@type" => "QuantitativeValue",
            "value" => Decimal.to_string(w.height_cm),
            "unitCode" => "CMT"
          },
      "width" =>
        w.width_cm &&
          %{
            "@type" => "QuantitativeValue",
            "value" => Decimal.to_string(w.width_cm),
            "unitCode" => "CMT"
          },
      "offers" => %{
        "@type" => "Offer",
        "priceCurrency" => "KES",
        "price" => lot.hammer || lot.current_bid || lot.opening_bid,
        "availability" =>
          if(Lot.finished?(lot),
            do: "https://schema.org/SoldOut",
            else: "https://schema.org/InStock"
          ),
        "url" => Meta.url(Lot.path(lot)),
        "seller" => %{"@id" => Meta.url("/#organization")}
      }
    }
  end

  ## View

  defp neighbours(lot, siblings) do
    i = Enum.find_index(siblings, &(&1.id == lot.id)) || 0
    {if(i > 0, do: Enum.at(siblings, i - 1)), Enum.at(siblings, i + 1)}
  end

  defp leading?(lot, user), do: user && lot.leader_id == user.id

  defp outbid?(lot, user, history),
    do: user && lot.leader_id != user.id && Enum.any?(history, &(&1.user_id == user.id))

  defp bid_kind(%{kind: "proxy"}), do: "Maximum"
  defp bid_kind(%{source: "room"}), do: "In the room"
  defp bid_kind(%{source: "absentee"}), do: "On the book"
  defp bid_kind(_), do: "Online"

  @impl true
  def render(assigns) do
    {prev, next} = neighbours(assigns.lot, assigns.siblings)
    user = assigns.current_user

    assigns =
      assign(assigns,
        prev: prev,
        next: next,
        leading: leading?(assigns.lot, user),
        outbid: outbid?(assigns.lot, user, assigns.history),
        second: assigns.lot.work.second_view
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
          <a href={~p"/sales"}>Sales</a><span class="sep">/</span>
          <a href={Sale.path(@sale)}>Sale {@sale.number}<span class="crumb-long">, {@sale.title}</span></a><span class="sep">/</span>
          <span>Lot {@lot.number}</span>
        </nav>
      </div>

      <article class="wrap lot-page">
        <div class="lot-stage">
          <div class="lot-stage-sticky">
            <div class="lot-frame" id="lot-frame" phx-hook="ImageZoom">
              <%= if @view == "second" and @second do %>
                <.work_image
                  work={@lot.work}
                  name={@second["file"]}
                  sizes="(min-width: 1024px) 56vw, 94vw"
                  loading="eager"
                />
              <% else %>
                <.work_image
                  work={@lot.work}
                  sizes="(min-width: 1024px) 56vw, 94vw"
                  loading="eager"
                  priority
                  transition={"work-#{@lot.work_id}"}
                />
              <% end %>
              <button type="button" class="zoom-button" data-zoom aria-label="Look closer">
                <svg viewBox="0 0 20 20" aria-hidden="true"><circle
                  cx="8.5"
                  cy="8.5"
                  r="5.5"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="1.5"
                /><path d="M12.5 12.5l5 5M8.5 6v5M6 8.5h5" stroke="currentColor" stroke-width="1.5" /></svg>
                <span>Look closer</span>
              </button>
            </div>
            <div
              :if={@second && has_image?(@second["file"])}
              class="lot-views"
              role="group"
              aria-label="Views of the work"
            >
              <button
                type="button"
                phx-click="view"
                phx-value-view="main"
                aria-pressed={to_string(@view == "main")}
              >
                <.work_image work={@lot.work} sizes="96px" /><span>The work</span>
              </button>
              <button
                type="button"
                phx-click="view"
                phx-value-view="second"
                aria-pressed={to_string(@view == "second")}
              >
                <.work_image work={@lot.work} name={@second["file"]} sizes="96px" /><span>{if @second[
                                                                                                "kind"
                                                                                              ] ==
                                                                                                "room",
                                                                                              do:
                                                                                                "In a room",
                                                                                              else:
                                                                                                "Detail"}</span>
              </button>
            </div>
          </div>
        </div>

        <div class="lot-info">
          <div class="lot-number">
            <span class="label">Lot</span>
            <span class="num serif">{@lot.number}</span>
          </div>

          <header class="lot-caption">
            <p class="artist-line">
              <a href={~p"/artists/#{@lot.work.artist.slug}"}>{@lot.work.artist.name}</a>
              <span :if={Artist.dates(@lot.work.artist)} class="dates">({Artist.dates(
                @lot.work.artist
              )})</span>
            </p>
            <h1><em>{@lot.work.title}</em><span class="year">, {@lot.work.year}</span></h1>
            <p class="lot-medium">{@lot.work.medium}</p>
            <p class="lot-medium num">
              {Work.dimensions(@lot.work)}<span :if={@lot.work.edition}> · {Work.edition(@lot.work)}</span>
            </p>
            <.estimate lot={@lot} class="lot-estimate" />
          </header>

          <section
            class={["bid-panel", @leading && "is-leading", @outbid && "is-outbid"]}
            aria-labelledby="bid-title"
          >
            <h2 id="bid-title" class="sr-only">Bidding</h2>
            <%= cond do %>
              <% @lot.status == "sold" -> %>
                <div class="bid-result">
                  <p class="label">Sold</p>
                  <p class="bid-amount serif num">{Format.money(@lot.hammer)}</p>
                  <p class="muted">
                    Hammer price. Buyer's premium of {Invoice.premium_rate()}% and VAT on the premium are added.
                  </p>
                  <p :if={@invoice} class="bid-won">
                    <span class="chip leading">You bought this lot</span>
                    <a class="text-link" href={~p"/account/invoices/#{@invoice.number}"}>Your invoice
                    <span class="arrow" aria-hidden="true">→</span></a>
                  </p>
                </div>
              <% @lot.status == "unsold" -> %>
                <div class="bid-result">
                  <p class="label">Not sold</p>
                  <p class="muted">
                    Bidding stopped below the reserve. If you would like to make an offer, our specialists can put it to the seller.
                  </p>
                  <a class="text-link" href={~p"/visit"}>Contact the specialists
                  <span class="arrow" aria-hidden="true">→</span></a>
                </div>
              <% Sale.live?(@sale) -> %>
                <.live_panel
                  sale={@sale}
                  lot={@lot}
                  user={@current_user}
                  own_max={@own_max}
                  choices={@choices}
                  error={@error}
                />
              <% @sale.status == "upcoming" -> %>
                <div class="bid-result">
                  <p class="label">Bidding opens</p>
                  <p class="bid-amount serif">{Format.when_(@sale.opens_at, @now)}</p>
                  <p class="muted">
                    Opening bid {Format.money(@lot.opening_bid)}. This lot closes {Format.when_(
                      @lot.closes_at,
                      @now
                    )
                    |> String.downcase()}, unless a late bid extends it.
                  </p>
                </div>
              <% true -> %>
                <.timed_panel
                  lot={@lot}
                  user={@current_user}
                  own_max={@own_max}
                  choices={@choices}
                  next_bid={@next_bid}
                  confirm={@confirm}
                  error={@error}
                  leading={@leading}
                  outbid={@outbid}
                  now={@now}
                />
            <% end %>
            <div class="bid-panel-foot">
              <button
                type="button"
                class="watch-button"
                phx-click="watch"
                aria-pressed={to_string(@watching)}
              >
                <.ribbon filled={@watching} />{if @watching, do: "Watching", else: "Watch this lot"}
              </button>
              <a class="text-link" href={~p"/buy"}>How bidding works</a>
            </div>
          </section>

          <section :if={@history != []} class="lot-history" aria-labelledby="history-title">
            <h2 id="history-title" class="label">Bids · {@lot.bid_count}</h2>
            <ol>
              <li
                :for={b <- @history}
                class={@current_user && b.user_id == @current_user.id && "mine"}
              >
                <span class="num serif">{Format.money(b.amount)}</span>
                <span>{if @current_user && b.user_id == @current_user.id,
                  do: "You",
                  else: "Paddle #{b.paddle}"}</span>
                <span class="muted">{bid_kind(b)}</span>
                <span class="muted num">{Format.clock(b.at)}</span>
              </li>
            </ol>
          </section>

          <section class="lot-notes">
            <div class="note">
              <h2 class="label">About the work</h2>
              <p class="prose">{@lot.work.description}</p>
            </div>
            <div class="note">
              <h2 class="label">Condition</h2>
              <p>{@lot.work.condition}</p>
            </div>
            <div class="note">
              <h2 class="label">Provenance</h2>
              <p>{@lot.work.provenance}</p>
            </div>
            <div :if={@lot.work.exhibited} class="note">
              <h2 class="label">Exhibited</h2>
              <p>{@lot.work.exhibited}</p>
            </div>
            <div :if={@lot.work.literature} class="note">
              <h2 class="label">Literature</h2>
              <p>{@lot.work.literature}</p>
            </div>
            <div class="note">
              <h2 class="label">The artist</h2>
              <p>{@lot.work.artist.bio}</p>
              <a class="text-link" href={~p"/artists/#{@lot.work.artist.slug}"}>More by {@lot.work.artist.name}
              <span class="arrow" aria-hidden="true">→</span></a>
            </div>
          </section>
        </div>
      </article>

      <nav class="wrap lot-pager" aria-label="Other lots in this sale">
        <a :if={@prev} href={Lot.path(@prev)} class="pager-link prev">
          <span class="label">Lot {@prev.number}</span>
          <span class="serif"><em>{@prev.work.title}</em></span>
        </a>
        <a href={Sale.path(@sale)} class="pager-all text-link">All {length(@siblings)} lots</a>
        <a :if={@next} href={Lot.path(@next)} class="pager-link next">
          <span class="label">Lot {@next.number}</span>
          <span class="serif"><em>{@next.work.title}</em></span>
        </a>
      </nav>
    </Layouts.app>
    """
  end

  attr :lot, Lot, required: true
  attr :user, :any
  attr :own_max, :integer
  attr :choices, :list
  attr :next_bid, :integer
  attr :confirm, :integer
  attr :error, :string
  attr :leading, :boolean
  attr :outbid, :boolean
  attr :now, DateTime

  defp timed_panel(assigns) do
    ~H"""
    <div class="bid-now">
      <div class="bid-row">
        <div>
          <p class="label">{if @lot.current_bid, do: "Current bid", else: "Opening bid"}</p>
          <p class="bid-amount serif">
            <span
              id={"amount-#{@lot.id}"}
              phx-hook="Odometer"
              phx-update="ignore"
              data-value={@lot.current_bid || @lot.opening_bid}
              data-prefix="KES "
            >{Format.money(@lot.current_bid || @lot.opening_bid)}</span>
          </p>
          <p class="bid-sub muted">
            {if @lot.bid_count > 0,
              do: Format.count(@lot.bid_count, "bid", "bids"),
              else: "No bids yet"} · {if Lot.reserve_met?(@lot),
              do: "Reserve met",
              else: "Reserve not yet met"}
          </p>
        </div>
        <div class="bid-time">
          <p class="label">Time left</p>
          <p class="bid-clock">
            <.countdown id={"lot-cd-#{@lot.id}"} at={@lot.closes_at} now={@now} />
          </p>
          <p class="bid-sub muted">
            Closes {Format.clock(@lot.closes_at)}<span :if={@lot.extensions > 0}> · extended {Format.count(
              @lot.extensions,
              "time",
              "times"
            )}</span>
          </p>
        </div>
      </div>

      <p :if={@leading} class="bid-status leading">
        <span class="chip leading">With you</span>
        <span :if={@own_max && @own_max > (@lot.current_bid || 0)}>Your maximum: {Format.money(
          @own_max
        )}</span>
      </p>
      <p :if={@outbid} class="bid-status outbid">
        <span class="chip outbid">Outbid</span> Bid again to take the lead.
      </p>
      <p :if={@error} class="error-text" role="alert">{@error}</p>

      <%= cond do %>
        <% is_nil(@user) -> %>
          <div class="bid-actions">
            <a class="btn block" href={~p"/signin?#{[return_to: Lot.path(@lot)]}"}>Sign in to bid</a>
            <a class="btn ghost block" href={~p"/register?#{[return_to: Lot.path(@lot)]}"}>Register to bid, in a minute</a>
          </div>
        <% @user.kind != "bidder" -> %>
          <p class="muted">You are signed in as staff. Staff accounts cannot bid.</p>
        <% @confirm -> %>
          <div class="bid-actions confirm" role="group" aria-label="Confirm your bid">
            <button
              type="button"
              class="btn block"
              phx-click="bid"
              phx-value-amount={@confirm}
              id="confirm-bid"
            >
              Confirm bid of {Format.money(@confirm)}
            </button>
            <button type="button" class="btn ghost block" phx-click="cancel">Cancel</button>
            <p class="muted bid-note">
              If you win, you pay the hammer price, a 20% buyer's premium and VAT on the premium.
            </p>
          </div>
        <% @leading -> %>
          <.max_form choices={@choices} own_max={@own_max} label="Raise your maximum" />
        <% @next_bid > @user.bid_limit -> %>
          <div class="bid-limit">
            <p>
              The next bid, {Format.money(@next_bid)}, is above your bidding limit of {Format.money(
                @user.bid_limit
              )}.
            </p>
            <a class="btn ghost block" href={~p"/account/limit"}>Ask for a higher limit</a>
          </div>
        <% true -> %>
          <div class="bid-actions">
            <button type="button" class="btn block bid-button" phx-click="ask" id="ask-bid">
              Bid {Format.money(@next_bid)} <span class="arrow" aria-hidden="true">→</span>
            </button>
          </div>
          <.max_form choices={@choices} own_max={@own_max} label="Or leave a maximum" />
      <% end %>
      <p :if={@user && @user.kind == "bidder"} class="bid-note muted">
        Paddle {@user.paddle} · limit {Format.money(@user.bid_limit)} · A bid in the last two minutes adds two minutes.
      </p>
    </div>
    """
  end

  attr :choices, :list, required: true
  attr :own_max, :integer
  attr :label, :string, required: true
  attr :selected, :integer, default: nil, doc: "the choice shown first; the lowest when nil"

  defp max_form(assigns) do
    ~H"""
    <form :if={@choices != []} class="max-form" phx-submit="max" id="max-form">
      <label for="max-amount" class="label">{@label}</label>
      <div class="max-row">
        <select id="max-amount" name="max" class="select">
          <option :for={c <- @choices} value={c} selected={c == @selected}>{Format.money(c)}</option>
        </select>
        <button type="submit" class="btn ghost">Set maximum</button>
      </div>
      <p class="hint muted">We bid for you, one step at a time, only as high as needed.</p>
    </form>
    """
  end

  attr :sale, Sale, required: true
  attr :lot, Lot, required: true
  attr :user, :any
  attr :own_max, :integer
  attr :choices, :list
  attr :error, :string

  defp live_panel(assigns) do
    ~H"""
    <div class="bid-now">
      <%= if @sale.status == "live" do %>
        <p class="label"><span class="chip live">Live now</span></p>
        <p class="bid-live-text">
          {if @lot.status == "open",
            do: "This lot is on the block now.",
            else: "This lot is in the live sale selling now."}
        </p>
        <a class="btn block" href={~p"/sales/#{@sale.number}/room"}>Enter the saleroom
        <span class="arrow" aria-hidden="true">→</span></a>
      <% else %>
        <p class="label">Live sale</p>
        <p class="bid-amount serif">{Format.when_(@sale.starts_at)}</p>
        <p class="muted">
          The auctioneer opens this lot at {Format.money(@lot.opening_bid)}. Bid live from your phone, or leave a maximum now and the auctioneer will bid for you from the book.
        </p>
        <p :if={@own_max} class="bid-status leading">
          <span class="chip leading">On the book</span> Your maximum: {Format.money(@own_max)}
        </p>
        <p :if={@error} class="error-text" role="alert">{@error}</p>
        <%= cond do %>
          <% is_nil(@user) -> %>
            <div class="bid-actions">
              <a class="btn block" href={~p"/signin?#{[return_to: Lot.path(@lot)]}"}>Sign in to leave a bid</a>
              <a class="btn ghost block" href={~p"/register?#{[return_to: Lot.path(@lot)]}"}>Register to bid</a>
            </div>
          <% @user.kind != "bidder" -> %>
            <p class="muted">Staff accounts cannot bid.</p>
          <% true -> %>
            <.max_form
              choices={absentee_choices(@lot, @user)}
              own_max={@own_max}
              selected={@own_max}
              label={
                if @own_max, do: "Change your absentee maximum", else: "Leave an absentee maximum"
              }
            />
        <% end %>
      <% end %>
    </div>
    """
  end

  defp absentee_choices(lot, user) do
    Stream.iterate(lot.opening_bid, &(&1 + Increments.step(&1)))
    |> Enum.take(30)
    |> Enum.take_while(&(&1 <= user.bid_limit))
  end

  @doc false
  def soft_close, do: Timed.soft_close()
end
