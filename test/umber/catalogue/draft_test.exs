defmodule Umber.Catalogue.DraftTest do
  use Umber.DataCase, async: true

  import Umber.Fixtures
  alias Umber.Catalogue

  defp draft do
    {:ok, sale} =
      Catalogue.create_draft(
        %{
          "title" => "Contemporary Ceramics",
          "format" => "live",
          "category" => "Design",
          "summary" => "Stoneware and porcelain.",
          "description" => "Vessels and bowls.",
          "starts_at" => DateTime.add(DateTime.utc_now(), 86_400, :second)
        },
        staff()
      )

    sale
  end

  test "a work can be added to a draft sale once" do
    sale = draft()
    w = work()

    assert {:ok, lot} = Catalogue.add_lot(sale, w.id, 90_000, 140_000)
    assert lot.number == 1
    assert Catalogue.add_lot(sale, w.id, 90_000, 140_000) == {:error, :already_in_sale}
  end

  test "another work becomes the next lot" do
    sale = draft()
    assert {:ok, _} = Catalogue.add_lot(sale, work().id, 90_000, 140_000)
    assert {:ok, second} = Catalogue.add_lot(sale, work().id, 50_000, 80_000)
    assert second.number == 2
  end
end
