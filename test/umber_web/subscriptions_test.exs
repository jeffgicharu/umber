defmodule UmberWeb.SubscriptionsTest do
  # The home page reloads on every live broadcast. It used to subscribe again
  # on each reload, so every event doubled its mailbox until the app ran out
  # of memory during a live sale.
  use UmberWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Umber.{Catalogue, Events}

  setup do
    {:ok, :ok} = Catalogue.import!()
    template = Enum.find(Catalogue.templates(), &(&1["key"] == "modern-contemporary"))
    {:ok, sale} = Catalogue.create_cycle(template, %{starts_at: DateTime.utc_now()})
    sale = sale |> Ecto.Changeset.change(status: "live") |> Umber.Repo.update!()
    Umber.Auctions.Live.ensure(sale.id)
    {:ok, sale: sale}
  end

  test "subscribing twice from one process registers once" do
    Events.subscribe("check:once")
    Events.subscribe("check:once")
    assert Enum.count(Registry.keys(Umber.PubSub, self()), &(&1 == "check:once")) == 1
  end

  test "the home page keeps one subscription per topic through many live events", %{
    conn: conn,
    sale: sale
  } do
    {:ok, view, _html} = live(conn, "/")

    for _ <- 1..12 do
      send(view.pid, {:live, %{sale_id: sale.id, version: 0}})
      send(view.pid, :sales_changed)
    end

    _ = render(view)
    keys = Registry.keys(Umber.PubSub, view.pid)
    assert Enum.count(keys, &(&1 == "live:#{sale.id}")) == 1
    assert Enum.count(keys, &(&1 == "sale:#{sale.id}")) == 1
    {:message_queue_len, queued} = Process.info(view.pid, :message_queue_len)
    assert queued < 5
  end

  test "the sales page keeps one subscription per sale", %{conn: conn, sale: sale} do
    {:ok, view, _html} = live(conn, "/sales")
    for _ <- 1..12, do: send(view.pid, :sales_changed)
    _ = render(view)
    assert Enum.count(Registry.keys(Umber.PubSub, view.pid), &(&1 == "sale:#{sale.id}")) == 1
  end
end
