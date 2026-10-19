defmodule UmberWeb.ArtistsLive do
  use UmberWeb, :live_view

  alias Umber.Catalogue
  alias Umber.Catalogue.Artist
  alias UmberWeb.Meta

  @impl true
  def mount(_params, _session, socket) do
    artists = Catalogue.list_artists()
    people = Enum.reject(artists, &Artist.anonymous?/1)
    makers = Enum.filter(artists, &Artist.anonymous?/1)

    {:ok,
     socket
     |> assign(
       groups: people |> Enum.group_by(&group/1) |> Enum.sort_by(&elem(&1, 0)),
       makers: makers
     )
     |> Meta.put(
       title: "Artists and makers",
       description:
         "The painters, sculptors, printmakers, photographers and designers whose work Umber has offered.",
       path: "/artists"
     )}
  end

  defp group(%Artist{discipline: d}) when d in ["Painter"], do: "1 Painters"
  defp group(%Artist{discipline: d}) when d in ["Sculptor"], do: "2 Sculptors"

  defp group(%Artist{discipline: d}) when d in ["Printmaker", "Draughtsman"],
    do: "3 Printmakers and draughtsmen"

  defp group(%Artist{discipline: "Photographer"}), do: "4 Photographers"
  defp group(_), do: "5 Designers and makers"

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
      <header class="page-head wrap">
        <p class="label">Artists and makers</p>
        <h1>The hands behind the lots</h1>
        <p class="page-lede">
          Painters, sculptors, printmakers, photographers and designers from Kenya, Tanzania, Uganda, Rwanda and Ethiopia whose work has passed through Umber.
        </p>
      </header>
      <div class="wrap artist-index">
        <section :for={{key, artists} <- @groups} class="artist-group" aria-labelledby={"g-#{key}"}>
          <h2 id={"g-#{key}"} class="label">{String.slice(key, 2..-1//1)}</h2>
          <ul>
            <li :for={a <- artists}>
              <a href={~p"/artists/#{a.slug}"}>
                <span class="serif artist-name">{a.name}</span>
                <span class="muted">{a.nationality}, {Artist.dates(a)}</span>
              </a>
            </li>
            <li :for={a <- if(String.starts_with?(key, "5"), do: @makers, else: [])}>
              <a href={~p"/artists/#{a.slug}"}>
                <span class="serif artist-name">{a.name}</span>
                <span class="muted">{a.discipline}, {Artist.dates(a)}</span>
              </a>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
