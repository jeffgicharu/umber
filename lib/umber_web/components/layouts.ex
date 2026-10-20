defmodule UmberWeb.Layouts do
  @moduledoc "The frame around every page: header, notices, footer; and the desk's frame."

  use UmberWeb, :html

  alias Umber.Accounts.User

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :current_user, :any, default: nil
  attr :live_now, :any, default: nil
  attr :notices, :list, default: []
  attr :active, :atom, default: nil
  attr :night, :boolean, default: false
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class={["page", @night && "night-page"]}>
      <a class="skip-link" href="#main">Skip to content</a>
      <header class="site-header" id="site-header">
        <div class="wrap bar">
          <a class="wordmark" href={~p"/"} aria-label="Umber, home">
            <span class="name">Umber</span>
            <span class="place">Auctioneers · Nairobi</span>
          </a>
          <nav class="site-nav" aria-label="Main">
            <a href={~p"/sales"} aria-current={@active == :sales && "page"}>Sales</a>
            <a href={~p"/results"} aria-current={@active == :results && "page"}>Results</a>
            <a href={~p"/artists"} aria-current={@active == :artists && "page"}>Artists</a>
            <a href={~p"/buy"} aria-current={@active == :buy && "page"}>Buying</a>
            <a href={~p"/sell"} aria-current={@active == :sell && "page"}>Selling</a>
            <a href={~p"/visit"} aria-current={@active == :visit && "page"}>Visit</a>
          </nav>
          <div class="header-tools">
            <a :if={@live_now} class="live-pill" href={~p"/sales/#{@live_now.number}/room"}>
              <span class="live-dot" aria-hidden="true"></span><span class="live-text">Live now</span><span class="sr-only">: enter the live sale</span>
            </a>
            <%= cond do %>
              <% User.staff?(@current_user) -> %>
                <a class="account-link" href={~p"/desk"}>Desk</a>
              <% @current_user -> %>
                <a
                  class="account-link"
                  href={~p"/account"}
                  aria-label={"Your account, paddle #{@current_user.paddle}"}
                >
                  <span><span class="paddle">{@current_user.paddle}</span><span class="who">Account</span></span>
                </a>
              <% true -> %>
                <a class="account-link" href={~p"/signin"}>Sign in</a>
            <% end %>
            <button
              class="menu-button"
              type="button"
              aria-label="Menu"
              aria-expanded="false"
              aria-controls="mobile-menu"
              phx-click={toggle_menu()}
            >
              <span></span>
            </button>
          </div>
        </div>
      </header>
      <nav id="mobile-menu" class="mobile-menu" aria-label="Main">
        <a class="big" href={~p"/sales"}>Sales</a>
        <a :if={@live_now} class="big" href={~p"/sales/#{@live_now.number}/room"}>The saleroom, live</a>
        <a class="big" href={~p"/results"}>Results</a>
        <a class="big" href={~p"/artists"}>Artists</a>
        <a class="big" href={~p"/buy"}>Buying</a>
        <a class="big" href={~p"/sell"}>Selling</a>
        <a class="big" href={~p"/visit"}>Visit</a>
        <div class="small-links">
          <a :if={!@current_user} href={~p"/register"}>Register to bid</a>
          <a :if={@current_user && !User.staff?(@current_user)} href={~p"/account"}>Your account</a>
          <a href={~p"/about"}>About Umber</a>
          <a href={~p"/conditions"}>Conditions of sale</a>
        </div>
      </nav>

      <main id="main" class={@night && "night"}>
        {render_slot(@inner_block)}
      </main>

      <.footer :if={!@night} />
      <.notices notices={@notices} />
      <.flash_group flash={@flash} />
    </div>
    """
  end

  defp toggle_menu do
    JS.toggle_class("open", to: "#mobile-menu")
    |> JS.toggle_attribute({"aria-expanded", "true", "false"}, to: ".menu-button")
  end

  def footer(assigns) do
    ~H"""
    <footer class="site-footer">
      <div class="wrap top">
        <div class="lead">
          <h2>Every lot can be seen before it is sold.</h2>
          <p style="margin-top: 18px; max-width: 40ch">
            Umber House, Lenana Road, Kilimani, Nairobi. Tuesday to Sunday, 10:00 to 18:00, and until the last lot on live sale days.
          </p>
        </div>
        <div class="col">
          <h3>Sales</h3>
          <ul>
            <li><a href={~p"/sales"}>Current sales</a></li>
            <li><a href={~p"/live"}>The live saleroom</a></li>
            <li><a href={~p"/results"}>Results</a></li>
            <li><a href={~p"/artists"}>Artists and makers</a></li>
          </ul>
        </div>
        <div class="col">
          <h3>Buying and selling</h3>
          <ul>
            <li><a href={~p"/buy"}>How to buy</a></li>
            <li><a href={~p"/register"}>Register to bid</a></li>
            <li><a href={~p"/sell"}>Sell with us</a></li>
            <li><a href={~p"/conditions"}>Conditions of sale</a></li>
          </ul>
        </div>
        <div class="col">
          <h3>Umber</h3>
          <ul>
            <li><a href={~p"/about"}>About the house</a></li>
            <li><a href={~p"/visit"}>Visit and contact</a></li>
            <li><a href={~p"/privacy"}>Privacy</a></li>
            <li><a href={~p"/terms"}>Terms of use</a></li>
          </ul>
        </div>
      </div>
      <span class="giant" aria-hidden="true">Umber</span>
      <div class="wrap colophon">
        <span>© 2026 Umber Auctioneers Ltd, Nairobi</span>
        <span>Prices in Kenya shillings. Buyer's premium 20%, with VAT on the premium.</span>
      </div>
    </footer>
    """
  end

  attr :notices, :list, required: true

  def notices(assigns) do
    ~H"""
    <div class="notices" aria-live="polite" aria-atomic="false">
      <div :for={n <- @notices} id={"notice-#{n.id}"} class={["notice", n.kind]}>
        <span class="kind" aria-hidden="true">{notice_mark(n.kind)}</span>
        <p class="head">{notice_head(n)}</p>
        <button type="button" phx-click="dismiss-notice" phx-value-id={n.id} aria-label="Dismiss">×</button>
        <p class="body">
          Lot {n.lot_number}, <em>{n.title}</em>. <a href={n.path}>{notice_action(n.kind)}</a>
        </p>
      </div>
    </div>
    """
  end

  defp notice_mark("outbid"), do: "!"
  defp notice_mark("won"), do: "✓"
  defp notice_mark(_), do: "◷"

  defp notice_head(%{kind: "outbid", amount: a}),
    do: "You've been outbid at #{Umber.Format.money(a)}"

  defp notice_head(%{kind: "won", amount: a}), do: "You won, at #{Umber.Format.money(a)}"
  defp notice_head(%{kind: "closing"}), do: "A lot you watch closes in under five minutes"
  defp notice_head(_), do: "Update"

  defp notice_action("outbid"), do: "Bid again"
  defp notice_action("won"), do: "See the lot"
  defp notice_action(_), do: "Go to the lot"

  attr :flash, :map, required: true

  def flash_group(assigns) do
    ~H"""
    <div id="flash-group" aria-live="polite">
      <.flash_message kind={:info} flash={@flash} />
      <.flash_message kind={:error} flash={@flash} />
    </div>
    """
  end

  attr :kind, :atom, required: true
  attr :flash, :map, required: true

  defp flash_message(assigns) do
    ~H"""
    <div
      :if={msg = Phoenix.Flash.get(@flash, @kind)}
      id={"flash-#{@kind}"}
      class={["flash", @kind == :error && "error"]}
      role={if @kind == :error, do: "alert", else: "status"}
      phx-hook="FlashTimer"
    >
      <span>{msg}</span>
      <button
        type="button"
        aria-label="Dismiss"
        phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> JS.hide(to: "#flash-#{@kind}")}
      >×</button>
    </div>
    """
  end

  ## The desk

  attr :flash, :map, required: true
  attr :current_user, :any, required: true
  attr :active, :atom, default: nil
  attr :wide, :boolean, default: false
  slot :inner_block, required: true

  def desk(assigns) do
    ~H"""
    <div class="desk">
      <aside class="desk-side">
        <a class="wordmark" href={~p"/desk"}>
          <span class="name">Umber</span><span class="place">Desk</span>
        </a>
        <nav class="desk-nav" aria-label="Desk">
          <a href={~p"/desk"} aria-current={@active == :dashboard && "page"}>Today</a>
          <a href={~p"/desk/sales"} aria-current={@active == :sales && "page"}>Sales</a>
          <a href={~p"/desk/bidders"} aria-current={@active == :bidders && "page"}>Bidders</a>
          <a href={~p"/desk/invoices"} aria-current={@active == :invoices && "page"}>Invoices</a>
          <a href={~p"/desk/consignments"} aria-current={@active == :consignments && "page"}>Consignments</a>
        </nav>
        <div class="desk-who">
          <p class="name">{@current_user.name}</p>
          <p class="roles">{Enum.map_join(@current_user.roles, ", ", &role_name/1)}</p>
          <div class="desk-links">
            <a href={~p"/"}>Open the website</a>
            <.link href={~p"/signout"} method="delete">Sign out</.link>
          </div>
        </div>
      </aside>
      <main id="main" class={["desk-main", @wide && "wide"]}>
        {render_slot(@inner_block)}
      </main>
    </div>
    <.flash_group flash={@flash} />
    """
  end

  def role_name("specialist"), do: "Specialist"
  def role_name("head_of_sale"), do: "Head of sale"
  def role_name("auctioneer"), do: "Auctioneer"
  def role_name("client_services"), do: "Client services"
  def role_name(other), do: other
end
