defmodule UmberWeb.Router do
  use UmberWeb, :router

  import UmberWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {UmberWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "referrer-policy" => "strict-origin-when-cross-origin",
      "x-robots-tag" => "noindex, nofollow"
    }

    plug :fetch_current_user
  end

  pipeline :plain do
    plug :accepts, ["xml", "json", "txt", "text"]
  end

  # Search engines, sharing previews and the deploy check.
  scope "/", UmberWeb do
    pipe_through :plain

    get "/healthz", MetaController, :healthz
    get "/healthz/engine", MetaController, :engine
    get "/robots.txt", MetaController, :robots
    get "/sitemap.xml", MetaController, :sitemap
    get "/manifest.webmanifest", MetaController, :manifest
  end

  scope "/", UmberWeb do
    pipe_through :browser

    get "/buy", PageController, :buy
    get "/about", PageController, :about
    get "/visit", PageController, :visit
    get "/conditions", PageController, :conditions
    get "/privacy", PageController, :privacy
    get "/terms", PageController, :terms

    # Stable links to whichever cycle of a running sale is current.
    get "/live", SaleRedirectController, :live
    get "/sales/current/:template", SaleRedirectController, :current

    get "/signin", SessionController, :new
    post "/signin", SessionController, :create
    post "/signin/welcome", SessionController, :welcome
    delete "/signout", SessionController, :delete

    live_session :public, on_mount: [{UmberWeb.UserAuth, :mount_current_user}, UmberWeb.Hooks] do
      live "/", HomeLive, :index
      live "/sales", SalesLive, :index
      live "/results", ResultsLive, :index
      live "/sales/:number", SaleLive, :show
      live "/sales/:number/lots/:lot", LotLive, :show
      live "/sales/:number/room", RoomLive, :show
      live "/artists", ArtistsLive, :index
      live "/artists/:slug", ArtistLive, :show
      live "/sell", SellLive, :index
      live "/register", RegisterLive, :new
    end

    live_session :account, on_mount: [{UmberWeb.UserAuth, :require_user}, UmberWeb.Hooks] do
      live "/account", AccountLive, :bids
      live "/account/watchlist", AccountLive, :watchlist
      live "/account/purchases", AccountLive, :purchases
      live "/account/limit", AccountLive, :limit
      live "/account/settings", AccountLive, :settings
      live "/account/invoices/:number", InvoiceLive, :show
    end
  end

  pipeline :staff do
    plug :require_staff
  end

  scope "/desk", UmberWeb.Desk, as: :desk do
    pipe_through [:browser, :staff]

    get "/uploads/:name", UploadController, :show
  end

  scope "/desk", UmberWeb.Desk, as: :desk do
    pipe_through :browser

    get "/signin", SessionController, :new
    post "/signin", SessionController, :create
    get "/try", SessionController, :try

    live_session :desk, on_mount: [{UmberWeb.UserAuth, :require_staff}] do
      live "/", DashboardLive, :index
      live "/sales", SalesLive, :index
      live "/sales/new", SaleEditLive, :new
      live "/sales/:number", SaleEditLive, :edit
      live "/rostrum/:number", RostrumLive, :show
      live "/bidders", BiddersLive, :index
      live "/invoices", InvoicesLive, :index
      live "/consignments", ConsignmentsLive, :index
    end
  end
end
