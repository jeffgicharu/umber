defmodule Umber.Catalogue do
  @moduledoc "Artists, works, sales and lots: what the house offers and what it has sold."

  import Ecto.Query
  alias Umber.Repo
  alias Umber.Catalogue.{Artist, Work, Sale, Lot}
  alias Umber.Auctions.Increments

  @catalogue_dir "catalogue"

  ## Reading

  def list_artists do
    from(a in Artist, order_by: a.name) |> Repo.all()
  end

  def get_artist_by_slug(slug), do: Repo.get_by(Artist, slug: slug)

  @doc "An artist's works with the lots they have appeared in, newest first."
  def artist_lots(%Artist{id: id}) do
    from(l in Lot,
      join: w in assoc(l, :work),
      join: s in assoc(l, :sale),
      where: w.artist_id == ^id and s.published and s.status != "draft",
      order_by: [desc: s.inserted_at, asc: l.number],
      preload: [work: w, sale: s]
    )
    |> Repo.all()
    |> dedupe_by_work()
  end

  # Running sales offer the same works every cycle; show each work once, at
  # its most recent lot.
  defp dedupe_by_work(lots), do: Enum.uniq_by(lots, & &1.work_id)

  @doc "Sales visitors can see now: live, open, upcoming; newest cycle of each running sale."
  def current_sales do
    from(s in Sale,
      where: s.published and s.status in ["upcoming", "open", "live"],
      order_by: [asc: fragment("coalesce(?, ?)", s.starts_at, s.opens_at)]
    )
    |> Repo.all()
  end

  @doc "Finished house sales with results (running cycles are not listed)."
  def past_sales do
    from(s in Sale, where: s.published and s.status == "closed" and is_nil(s.template), order_by: [desc: s.ended_at])
    |> Repo.all()
  end

  def get_sale_by_number(number) do
    case Integer.parse(to_string(number)) do
      {n, ""} -> Repo.get_by(Sale, number: n)
      _ -> nil
    end
  end

  def sale_lots(%Sale{id: id} = sale) do
    from(l in Lot, where: l.sale_id == ^id, order_by: l.number, preload: [work: :artist])
    |> Repo.all()
    |> Enum.map(&%{&1 | sale: sale})
  end

  def get_lot(%Sale{id: sale_id} = sale, number) do
    with {n, ""} <- Integer.parse(to_string(number)),
         %Lot{} = lot <- Repo.one(from l in Lot, where: l.sale_id == ^sale_id and l.number == ^n, preload: [work: :artist, leader: [], buyer: []]) do
      %{lot | sale: sale}
    else
      _ -> nil
    end
  end

  def get_lot!(id), do: Repo.get!(Lot, id) |> Repo.preload([:sale, work: :artist])

  @doc "The latest sale made from a running template, for stable links like /sales/live."
  def latest_cycle(template) do
    from(s in Sale,
      where: s.template == ^template and s.published,
      order_by: [desc: s.number],
      limit: 1
    )
    |> Repo.one()
  end

  @doc "Lots across open timed sales that close next."
  def closing_soon(limit \\ 6) do
    from(l in Lot,
      join: s in assoc(l, :sale),
      where: l.status == "open" and s.format == "timed" and s.status == "open",
      order_by: [asc: l.closes_at],
      limit: ^limit,
      preload: [sale: s, work: :artist]
    )
    |> Repo.all()
  end

  @doc "Recent results from the house's past sales, highest first."
  def notable_results(limit \\ 6) do
    from(l in Lot,
      join: s in assoc(l, :sale),
      where: s.status == "closed" and is_nil(s.template) and l.status == "sold",
      order_by: [desc: l.hammer],
      limit: ^limit,
      preload: [sale: s, work: :artist]
    )
    |> Repo.all()
  end

  def bid_history(%Lot{id: id}, limit \\ 30) do
    from(b in Umber.Auctions.Bid,
      left_join: u in assoc(b, :user),
      where: b.lot_id == ^id,
      order_by: [desc: b.inserted_at, desc: b.id],
      limit: ^limit,
      select: %{amount: b.amount, kind: b.kind, source: b.source, at: b.inserted_at, paddle: u.paddle, user_id: b.user_id}
    )
    |> Repo.all()
  end

  ## Importing the house catalogue

  @doc """
  Loads artists, works and the two past sales from priv/catalogue. Safe to run
  again: artists and works are updated in place, past sales are only created once.
  """
  def import! do
    dir = Application.app_dir(:umber, ["priv", @catalogue_dir])
    artists = read_json(dir, "artists.json")
    lots = read_json(dir, "lots.json")
    sales = read_json(dir, "sales.json")
    images = if File.exists?(Path.join(dir, "images.json")), do: read_json(dir, "images.json"), else: %{}

    Repo.transaction(fn ->
      artist_ids = Map.new(artists, fn a -> {a["id"], upsert_artist(a).id} end)
      categories = Map.new(sales, &{&1["key"], &1["category"]})

      works =
        Map.new(lots, fn l ->
          {l["file"], upsert_work(l, artist_ids[l["artist"]], categories[l["sale"]], images[l["file"]])}
        end)

      for s <- sales, not s["running"], do: ensure_past_sale(s, lots, works)
      :ok
    end)
  end

  def templates do
    dir = Application.app_dir(:umber, ["priv", @catalogue_dir])
    sales = read_json(dir, "sales.json") |> Enum.filter(& &1["running"])
    lots = read_json(dir, "lots.json")

    Enum.map(sales, fn s ->
      Map.put(s, "lots", Enum.filter(lots, &(&1["sale"] == s["key"])))
    end)
  end

  defp read_json(dir, name), do: dir |> Path.join(name) |> File.read!() |> Jason.decode!()

  defp upsert_artist(a) do
    attrs = %{
      slug: a["id"],
      name: a["name"],
      born: a["born"],
      died: a["died"],
      founded: a["founded"],
      period: a["period"],
      nationality: a["nationality"],
      based: a["based"],
      discipline: a["discipline"],
      bio: a["bio"]
    }

    upsert(Artist, :slug, attrs)
  end

  defp upsert_work(l, artist_id, category, image) do
    d = l["dimensions"]
    {w, h} = image_size(l, image)

    attrs = %{
      slug: work_slug(l),
      image: l["file"],
      artist_id: artist_id,
      title: l["title"],
      year: l["year"],
      medium: l["medium"],
      height_cm: d["h"] && Decimal.new(d["h"]),
      width_cm: d["w"] && Decimal.new(d["w"]),
      depth_cm: d["d"] && Decimal.new(d["d"]),
      dimensions_note: l["dimensions_note"],
      edition: l["edition"],
      description: l["description"],
      condition: l["condition"],
      provenance: l["provenance"],
      exhibited: l["exhibited"],
      literature: l["literature"],
      image_width: w,
      image_height: h,
      second_view: image && image["second"],
      category: category || "Art"
    }

    upsert(Work, :slug, attrs)
  end

  # The real picture's size once it exists; until then the work's own proportion.
  defp image_size(_l, %{"w" => w, "h" => h}), do: {w, h}

  defp image_size(l, _) do
    %{"h" => h, "w" => w} = l["dimensions"]
    if l["dimensions"]["d"], do: {1600, 2000}, else: {round(w * 20), round(h * 20)}
  end

  defp work_slug(l) do
    base = l["title"] |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
    "#{base}-#{String.replace(l["file"], "lot-", "")}"
  end

  defp upsert(schema, key, attrs) do
    case Repo.get_by(schema, [{key, Map.fetch!(attrs, key)}]) do
      nil -> struct(schema, attrs) |> Repo.insert!()
      row -> row |> Ecto.Changeset.change(attrs) |> Repo.update!()
    end
  end

  @past_numbers %{"design-august-2026" => 3017, "modern-contemporary-september-2026" => 3024}

  defp ensure_past_sale(s, lots, works) do
    number = Map.fetch!(@past_numbers, s["key"])

    unless Repo.get_by(Sale, number: number) do
      {:ok, held, _} = DateTime.from_iso8601(s["held_at"])
      held = %{held | microsecond: {0, 6}}

      sale =
        Repo.insert!(%Sale{
          number: number,
          title: s["title"],
          format: s["format"],
          category: s["category"],
          summary: s["summary"],
          description: s["description"],
          status: "closed",
          starts_at: if(s["format"] == "live", do: held),
          opens_at: if(s["format"] == "timed", do: DateTime.add(held, -10, :day)),
          first_close_at: if(s["format"] == "timed", do: held),
          lot_interval: if(s["format"] == "timed", do: 60),
          ended_at: held
        })

      for l <- lots, l["sale"] == s["key"] do
        [low, high] = l["estimate"]
        result = l["result"]

        Repo.insert!(%Lot{
          sale_id: sale.id,
          work_id: works[l["file"]].id,
          number: l["lot"],
          estimate_low: low,
          estimate_high: high,
          reserve: reserve(low),
          opening_bid: opening(low),
          status: if(result, do: "sold", else: "unsold"),
          current_bid: result,
          hammer: result,
          bid_count: if(result, do: 6 + rem(l["lot"] * 7, 13), else: 2),
          market_value: result || low,
          closes_at: held,
          closed_at: held
        })
      end
    end
  end

  ## Running sales: each cycle is a new sale with the template's works

  @doc "The next sale number."
  def next_number do
    (Repo.one(from s in Sale, select: max(s.number)) || 3100) |> max(3100) |> Kernel.+(1)
  end

  @doc """
  Creates one cycle of a running sale. `times` gives `:opens_at`,
  `:first_close_at` and `:lot_interval` for a timed sale, or `:starts_at` for
  a live one.
  """
  def create_cycle(template, times) do
    works = from(w in Work, where: w.image in ^Enum.map(template["lots"], & &1["file"])) |> Repo.all() |> Map.new(&{&1.image, &1})
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      sale =
        Repo.insert!(%Sale{
          number: next_number(),
          template: template["key"],
          title: template["title"],
          format: template["format"],
          category: template["category"],
          summary: template["summary"],
          description: template["description"],
          status: "upcoming",
          opens_at: times[:opens_at],
          first_close_at: times[:first_close_at],
          lot_interval: times[:lot_interval],
          starts_at: times[:starts_at]
        })

      for l <- template["lots"] do
        [low, high] = l["estimate"]

        Repo.insert!(%Lot{
          sale_id: sale.id,
          work_id: works[l["file"]].id,
          number: l["lot"],
          estimate_low: low,
          estimate_high: high,
          reserve: reserve(low),
          opening_bid: opening(low),
          market_value: market_value(low, high),
          closes_at: lot_close(times, l["lot"]),
          inserted_at: now,
          updated_at: now
        })
      end

      sale
    end)
  end

  defp lot_close(%{first_close_at: %DateTime{} = first, lot_interval: i}, n), do: DateTime.add(first, (n - 1) * i, :second)
  defp lot_close(_, _), do: nil

  @doc "The reserve: a little under the low estimate, on the step grid."
  def reserve(low), do: Increments.round_down(round(low * 0.85))

  @doc "The opening bid: about half the low estimate, on the step grid."
  def opening(low), do: Increments.round_down(round(low * 0.5))

  @doc """
  What the sample bidders will go to this time. Most lots sell within or
  around estimate; about one in seven stops below the reserve.
  """
  def market_value(low, high) do
    r = :rand.uniform()

    v =
      cond do
        r < 0.14 -> low * (0.55 + :rand.uniform() * 0.25)
        r < 0.80 -> low + (high - low) * :rand.uniform()
        true -> high * (1.0 + :rand.uniform() * 0.45)
      end

    Increments.round_down(round(v))
  end
end
