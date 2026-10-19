defmodule Umber.Fixtures do
  @moduledoc "Small builders for tests."

  alias Umber.Repo
  alias Umber.Accounts
  alias Umber.Accounts.User
  alias Umber.Catalogue.{Artist, Work, Sale, Lot}

  def unique, do: System.unique_integer([:positive])

  def artist(attrs \\ %{}) do
    n = unique()

    Repo.insert!(
      struct(
        %Artist{slug: "artist-#{n}", name: "Artist #{n}", born: 1970, nationality: "Kenyan", based: "Nairobi", discipline: "Painter", bio: "A painter."},
        attrs
      )
    )
  end

  def work(attrs \\ %{}) do
    n = unique()
    artist = attrs[:artist] || artist()

    Repo.insert!(
      struct(
        %Work{
          slug: "work-#{n}",
          image: "lot-test-#{n}",
          artist_id: artist.id,
          title: "Work #{n}",
          year: "2020",
          medium: "Oil on canvas",
          height_cm: Decimal.new(100),
          width_cm: Decimal.new(120),
          description: "A painting.",
          condition: "Very good.",
          provenance: "The artist.",
          image_width: 2400,
          image_height: 2000,
          category: "Art"
        },
        Map.delete(attrs, :artist)
      )
    )
  end

  def sale(attrs \\ %{}) do
    now = DateTime.utc_now()

    Repo.insert!(
      struct(
        %Sale{
          number: 5000 + rem(unique(), 4000),
          title: "Test sale",
          format: "timed",
          category: "Art",
          summary: "A sale.",
          description: "A sale for tests.",
          status: "open",
          opens_at: DateTime.add(now, -3600, :second),
          first_close_at: DateTime.add(now, 3600, :second),
          lot_interval: 120
        },
        attrs
      )
    )
  end

  def lot(attrs \\ %{}) do
    sale = attrs[:sale] || sale()
    work = attrs[:work] || work()

    lot =
      Repo.insert!(
        struct(
          %Lot{
            sale_id: sale.id,
            work_id: work.id,
            number: rem(unique(), 900) + 1,
            estimate_low: 200_000,
            estimate_high: 300_000,
            reserve: 170_000,
            opening_bid: 100_000,
            status: "open",
            market_value: 250_000,
            closes_at: DateTime.add(DateTime.utc_now(), 3600, :second)
          },
          attrs |> Map.delete(:sale) |> Map.delete(:work)
        )
      )

    %{lot | sale: sale}
  end

  def bidder(attrs \\ %{}) do
    n = unique()

    {:ok, user} =
      Accounts.register_bidder(
        Map.merge(
          %{"name" => "Bidder #{n}", "email" => "bidder#{n}@example.com", "password" => "a long password", "country" => "Kenya", "accept_conditions" => "true"},
          attrs
        )
      )

    user
  end

  def staff(roles \\ ~w(specialist head_of_sale auctioneer client_services)) do
    n = unique()

    {:ok, user} =
      %User{kind: "staff", name: "Staff #{n}", email: "staff#{n}@example.com", roles: roles, bid_limit: 0}
      |> Ecto.Changeset.change()
      |> Accounts.insert_with_paddle("staff")

    user
  end

  def sample_bidder do
    n = unique()

    {:ok, user} =
      %User{kind: "sample", name: "Sample #{n}", email: "sample#{n}@sample.invalid", bid_limit: 50_000_000}
      |> Ecto.Changeset.change()
      |> Accounts.insert_with_paddle("sample")

    user
  end
end
