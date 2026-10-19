defmodule Umber.Market.CleanupTest do
  use Umber.DataCase, async: true

  import Umber.Fixtures
  alias Umber.Repo
  alias Umber.Accounts.User
  alias Umber.Catalogue.Sale
  alias Umber.Auctions.Timed
  alias Umber.Market.Cleanup

  test "old cycles go, the house's past sales and cycles with a visitor's purchase stay" do
    now = DateTime.utc_now()
    long_ago = DateTime.add(now, -7 * 3600, :second)

    old = sale(%{template: "paper-photographs", status: "closed", ended_at: long_ago})

    recent =
      sale(%{
        template: "paper-photographs",
        status: "closed",
        ended_at: DateTime.add(now, -600, :second)
      })

    house =
      sale(%{template: nil, status: "closed", ended_at: DateTime.add(now, -30 * 86_400, :second)})

    won = sale(%{template: "design-objects", status: "open"})
    lot = lot(%{sale: won, closes_at: DateTime.add(now, 60, :second)})
    {:ok, _} = Timed.place(lot.id, bidder(), :max, 200_000)
    # The bid fell in the last two minutes, so the close moved to two minutes after it.
    {:ok, %{invoice: %{}}} = Timed.close(lot.id, DateTime.add(now, 180, :second))
    won |> Ecto.Changeset.change(status: "closed", ended_at: long_ago) |> Repo.update!()

    Cleanup.run(now)

    refute Repo.get(Sale, old.id)
    assert Repo.get(Sale, recent.id)
    assert Repo.get(Sale, house.id)
    assert Repo.get(Sale, won.id), "a cycle with an invoice stays for eight days"
  end

  test "idle visitors and expired guest staff go; sample bidders and active visitors stay" do
    now = DateTime.utc_now()
    idle = bidder()

    idle
    |> Ecto.Changeset.change(last_seen_at: DateTime.add(now, -8 * 86_400, :second))
    |> Repo.update!()

    active = bidder()

    active
    |> Ecto.Changeset.change(last_seen_at: DateTime.add(now, -86_400, :second))
    |> Repo.update!()

    bot = sample_bidder()
    {:ok, guest} = Umber.Accounts.create_trial_staff()
    guest |> Ecto.Changeset.change(expires_at: DateTime.add(now, -60, :second)) |> Repo.update!()

    Cleanup.run(now)

    refute Repo.get(User, idle.id)
    assert Repo.get(User, active.id)
    assert Repo.get(User, bot.id)
    refute Repo.get(User, guest.id)
  end
end
