defmodule UmberWeb.PagesTest do
  use UmberWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Umber.Fixtures
  import Ecto.Query, only: [from: 2]
  alias Umber.{Catalogue, Repo}
  alias Umber.Catalogue.Sale

  setup do
    {:ok, :ok} = Catalogue.import!()
    templates = Map.new(Catalogue.templates(), &{&1["key"], &1})
    now = DateTime.utc_now()

    {:ok, live} =
      Catalogue.create_cycle(templates["modern-contemporary"], %{
        starts_at: DateTime.add(now, 900, :second)
      })

    {:ok, timed} =
      Catalogue.create_cycle(templates["paper-photographs"], %{
        opens_at: DateTime.add(now, -60, :second),
        first_close_at: DateTime.add(now, 1800, :second),
        lot_interval: 120
      })

    timed = timed |> Ecto.Changeset.change(status: "open") |> Repo.update!()

    Repo.update_all(from(l in Umber.Catalogue.Lot, where: l.sale_id == ^timed.id),
      set: [status: "open"]
    )

    {:ok, live: live, timed: timed}
  end

  describe "every public page" do
    test "answers with its own title, a description, a canonical address and noindex", %{
      conn: conn,
      live: live,
      timed: timed
    } do
      paths = [
        {"/", "Modern and contemporary East African art at auction"},
        {"/sales", "Current sales"},
        {"/results", "Results"},
        {"/artists", "Artists and makers"},
        {"/artists/juma-mwakalinga", "Juma Mwakalinga, painter"},
        {Sale.path(live), "Modern &amp; Contemporary East African Art, sale #{live.number}"},
        {Sale.path(timed), "Works on Paper &amp; Photographs, sale #{timed.number}"},
        {"/sales/#{live.number}/lots/8", "Fishermen Mending Nets by Juma Mwakalinga, lot 8"},
        {"/sales/#{live.number}/room", "The saleroom, live"},
        {"/sell", "Sell with us"},
        {"/register", "Register to bid"},
        {"/signin", "Sign in"},
        {"/buy", "How to buy at Umber"},
        {"/about", "About Umber"},
        {"/visit", "Visit and contact"},
        {"/conditions", "Conditions of sale"},
        {"/privacy", "Privacy"},
        {"/terms", "Terms of use"}
      ]

      for {path, title} <- paths do
        html = conn |> get(path) |> html_response(200)
        assert html =~ "<title", path
        assert html =~ title, "#{path} should have the title #{title}"
        assert html =~ ~s(<meta name="robots" content="noindex, nofollow">), path

        assert html =~
                 ~s(<link rel="canonical" href="https://umber.jeffgicharu.com#{if path == "/", do: "/", else: path}">),
               path

        assert html =~ ~s(property="og:image"), path
        assert html =~ "application/ld+json", path
      end
    end

    test "an unknown lot, sale or artist is Umber's own 404", %{conn: conn, live: live} do
      for path <- ["/sales/999999", "/sales/#{live.number}/lots/99", "/artists/nobody"] do
        assert_error_sent 404, fn -> get(conn, path) end
      end

      html = Phoenix.Template.render_to_string(UmberWeb.ErrorHTML, "404", "html", [])
      assert html =~ "withdrawn from sale"
    end
  end

  describe "search engines and the deploy check" do
    test "robots.txt points at the sitemap and keeps the desk out", %{conn: conn} do
      body = conn |> get("/robots.txt") |> response(200)
      assert body =~ "Disallow: /desk/"
      assert body =~ "Sitemap: https://umber.jeffgicharu.com/sitemap.xml"
    end

    test "the sitemap lists sales, lots and artists", %{conn: conn, live: live} do
      body = conn |> get("/sitemap.xml") |> response(200)
      assert body =~ "<loc>https://umber.jeffgicharu.com/sales/#{live.number}</loc>"
      assert body =~ "/sales/#{live.number}/lots/8</loc>"
      assert body =~ "/artists/achieng-oduya</loc>"
    end

    test "the manifest and the health check answer", %{conn: conn} do
      assert conn
             |> get("/manifest.webmanifest")
             |> json_response(200)
             |> Map.fetch!("short_name") == "Umber"

      conn = get(conn, "/healthz")
      assert response(conn, 200) == "ok\n"
      assert get_resp_header(conn, "x-release") != []
    end
  end

  describe "a bidder's way through" do
    test "registers, is signed in, and bids on a timed lot", %{conn: conn, timed: timed} do
      {:ok, view, _html} = live(conn, "/register")

      form =
        form(view, "#register-form",
          user: %{
            name: "Achieng Test",
            email: "achieng@example.com",
            password: "a long password here",
            country: "Kenya",
            accept_conditions: "true"
          }
        )

      render_submit(form)
      conn = follow_trigger_action(form, conn)
      assert redirected_to(conn) == "/account"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Your paddle number is"

      conn = recycle(conn)
      {:ok, lot_view, html} = live(conn, "/sales/#{timed.number}/lots/1")
      assert html =~ "Bid KES 40,000"

      lot_view |> element("#ask-bid") |> render_click()
      assert render(lot_view) =~ "Confirm bid of KES 40,000"

      html = lot_view |> element("#confirm-bid") |> render_click()
      assert html =~ "With you"
      assert html =~ "Your bid of KES 40,000 leads."
    end

    test "a visitor who is not signed in is asked to sign in before bidding", %{
      conn: conn,
      timed: timed
    } do
      {:ok, _view, html} = live(conn, "/sales/#{timed.number}/lots/1")
      assert html =~ "Sign in to bid"
      refute html =~ "ask-bid"
    end

    test "wrong details at sign-in say so without saying which was wrong", %{conn: conn} do
      bidder(%{"email" => "known@example.com"})

      html =
        conn
        |> post("/signin", %{
          "session" => %{"email" => "known@example.com", "password" => "not the password"}
        })
        |> html_response(422)

      assert html =~ "That email and password do not match an account."
    end
  end

  describe "the desk" do
    test "is closed to visitors and bidders", %{conn: conn} do
      assert conn |> get("/desk") |> redirected_to() == "/desk/signin"
    end

    test "a guest staff link needs the right key", %{conn: conn} do
      Application.put_env(:umber, :staff_trial_key, "test-key")
      on_exit(fn -> Application.delete_env(:umber, :staff_trial_key) end)

      assert conn |> get("/desk/try?key=wrong") |> redirected_to() == "/desk/signin"
      conn = get(conn, "/desk/try?key=test-key")
      assert redirected_to(conn) == "/desk"
      {:ok, _view, html} = conn |> recycle() |> live("/desk")
      assert html =~ "Guest staff"
      assert html =~ "Today"
    end

    test "guest staff cannot publish a draft", %{conn: conn} do
      {:ok, staff} = Umber.Accounts.create_trial_staff()

      {:ok, sale} =
        Catalogue.create_draft(
          %{
            "title" => "Draft",
            "format" => "live",
            "category" => "Art",
            "summary" => "A draft.",
            "description" => "A draft sale.",
            "starts_at" => DateTime.utc_now()
          },
          staff
        )

      assert Catalogue.publish(sale, staff) == {:error, :not_head}
      _ = conn
    end
  end
end
