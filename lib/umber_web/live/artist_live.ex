defmodule UmberWeb.ArtistLive do
  use UmberWeb, :live_view

  alias Umber.Catalogue
  alias Umber.Catalogue.{Artist, Lot}
  alias UmberWeb.Meta

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Catalogue.get_artist_by_slug(slug) do
      %Artist{} = artist ->
        lots = Catalogue.artist_lots(artist)
        {current, past} = Enum.split_with(lots, &(&1.sale.status in ["upcoming", "open", "live"]))

        {:ok,
         socket
         |> assign(artist: artist, current: current, past: past, now: DateTime.utc_now())
         |> Meta.put(
           title: "#{artist.name}, #{String.downcase(artist.discipline)}",
           description:
             artist.bio |> String.split(". ") |> Enum.take(2) |> Enum.join(". ") |> Kernel.<>("."),
           path: ~p"/artists/#{artist.slug}",
           image: lots |> List.first() |> then(&(&1 && &1.work.image)),
           type: "profile",
           json_ld: person_json(artist)
         )}

      nil ->
        raise UmberWeb.NotFound
    end
  end

  defp person_json(a) do
    if Artist.anonymous?(a) do
      []
    else
      %{
        "@context" => "https://schema.org",
        "@type" => if(a.founded, do: "Organization", else: "Person"),
        "name" => a.name,
        "description" => a.bio,
        "url" => Meta.url("/artists/#{a.slug}"),
        "nationality" => a.nationality,
        "birthDate" => a.born && Integer.to_string(a.born),
        "deathDate" => a.died && Integer.to_string(a.died)
      }
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      live_now={@live_now}
      notices={@notices}
      active={:artists}
    >
      <div class="wrap">
        <nav class="crumbs" aria-label="Breadcrumb">
          <a href={~p"/artists"}>Artists and makers</a><span class="sep">/</span><span>{@artist.name}</span>
        </nav>
      </div>
      <header class="wrap artist-head">
        <div>
          <p class="label">{@artist.discipline} · {@artist.nationality} · {@artist.based}</p>
          <h1>{@artist.name}</h1>
          <p :if={Artist.dates(@artist)} class="artist-dates serif num">{Artist.dates(@artist)}</p>
        </div>
        <p class="artist-bio">{@artist.bio}</p>
      </header>

      <section :if={@current != []} class="wrap section-tight" aria-labelledby="now-title">
        <div class="section-head">
          <p class="label">On sale now</p>
          <h2 id="now-title">In current sales</h2>
        </div>
        <div class="lot-grid">
          <.lot_card :for={lot <- @current} lot={lot} user={@current_user} now={@now} />
        </div>
      </section>

      <section :if={@past != []} class="wrap section-tight" aria-labelledby="past-title">
        <div class="section-head">
          <p class="label">Results</p>
          <h2 id="past-title">Sold at Umber</h2>
        </div>
        <div class="lot-grid">
          <.lot_card :for={lot <- @past} lot={lot} user={@current_user} now={@now} />
        </div>
      </section>

      <div :if={@current == [] and @past == []} class="wrap">
        <div class="empty">
          <h3>No works by {@artist.name} are on sale just now.</h3>
          <p>We will offer them again in a future sale.</p>
          <a class="btn ghost" href={~p"/sales"}>See current sales</a>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @doc false
  def lot_path(lot), do: Lot.path(lot)
end
