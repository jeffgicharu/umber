defmodule Umber.Catalogue.WorkTest do
  use ExUnit.Case, async: true

  alias Umber.Catalogue.Work

  test "a numbered copy reads as its edition number" do
    assert Work.edition(%Work{edition: "3 of 8"}) == "Edition 3 of 8"
  end

  test "an unnumbered copy keeps the note as written" do
    assert Work.edition(%Work{edition: "From the edition of 20"}) == "From the edition of 20"
  end

  test "a unique work has no edition" do
    assert Work.edition(%Work{edition: nil}) == nil
  end
end
