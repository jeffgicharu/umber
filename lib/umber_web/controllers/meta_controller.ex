defmodule UmberWeb.MetaController do
  @moduledoc "robots.txt, the sitemap, the web manifest and the health check."
  use UmberWeb, :controller

  import Ecto.Query
  alias Umber.{Repo, Catalogue}
  alias Umber.Catalogue.{Sale, Lot}
  alias UmberWeb.Meta

  @doc """
  The deploy check reads this. It answers only when the database answers,
  and names the release in a header.
  """
  def healthz(conn, _params) do
    case Repo.query("SELECT 1") do
      {:ok, _} ->
        conn
        |> put_resp_header("x-release", Application.get_env(:umber, :release, "dev"))
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_content_type("text/plain")
        |> send_resp(200, "ok\n")

      _ ->
        conn |> put_resp_content_type("text/plain") |> send_resp(503, "database unavailable\n")
    end
  end

  # Crawlers may fetch pages, so they can read each page's noindex.
  def robots(conn, _params) do
    body = """
    User-agent: *
    Disallow: /desk/
    Disallow: /account/
    Allow: /

    Sitemap: #{Meta.url("/sitemap.xml")}
    """

    conn |> put_resp_content_type("text/plain") |> send_resp(200, body)
  end

  def sitemap(conn, _params) do
    static = ~w(/ /sales /results /artists /buy /sell /about /visit /conditions /privacy /terms)

    sales =
      from(s in Sale,
        where: s.published and (s.status in ["upcoming", "open", "live"] or is_nil(s.template))
      )
      |> Repo.all()

    lots = Enum.flat_map(sales, &Catalogue.sale_lots/1)
    artists = Catalogue.list_artists()

    urls =
      Enum.map(static, &{&1, nil}) ++
        Enum.map(sales, &{Sale.path(&1), &1.updated_at}) ++
        Enum.map(lots, &{Lot.path(&1), &1.updated_at}) ++
        Enum.map(artists, &{"/artists/#{&1.slug}", &1.updated_at})

    body = [
      ~s(<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n),
      Enum.map(urls, fn {path, at} ->
        lastmod =
          if at, do: "<lastmod>#{Date.to_iso8601(DateTime.to_date(at))}</lastmod>", else: ""

        "  <url><loc>#{Meta.url(path)}</loc>#{lastmod}</url>\n"
      end),
      "</urlset>\n"
    ]

    conn |> put_resp_content_type("application/xml") |> send_resp(200, body)
  end

  def manifest(conn, _params) do
    manifest = %{
      name: "Umber Auctioneers",
      short_name: "Umber",
      description: Meta.default_description(),
      start_url: "/",
      scope: "/",
      display: "standalone",
      background_color: "#f2ede4",
      theme_color: "#120d0a",
      icons: [
        %{src: "/images/brand/icon-192.png", sizes: "192x192", type: "image/png"},
        %{src: "/images/brand/icon-512.png", sizes: "512x512", type: "image/png"},
        %{
          src: "/images/brand/icon-maskable-512.png",
          sizes: "512x512",
          type: "image/png",
          purpose: "maskable"
        }
      ]
    }

    conn
    |> put_resp_content_type("application/manifest+json")
    |> send_resp(200, Jason.encode!(manifest))
  end
end
