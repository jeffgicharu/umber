defmodule UmberWeb.Catalogue do
  @moduledoc "How the catalogue is set: pictures, captions, estimates, lot cards, sale covers."

  use Phoenix.Component
  use UmberWeb, :verified_routes

  alias Umber.Format
  alias Umber.Catalogue.{Artist, Work, Lot, Sale}

  @widths [480, 960, 1600]

  @doc "Image renditions built from the masters, as listed in priv/catalogue/images.json."
  def renditions do
    path = Application.app_dir(:umber, ["priv", "catalogue", "images.json"])
    # Read again whenever the list is rebuilt; in a release it never changes.
    stamp =
      case File.stat(path),
        do: (
          {:ok, %{mtime: m, size: s}} -> {m, s}
          _ -> nil
        )

    case :persistent_term.get({__MODULE__, :images}, nil) do
      {^stamp, images} ->
        images

      _ ->
        images = if stamp, do: path |> File.read!() |> Jason.decode!(), else: %{}
        :persistent_term.put({__MODULE__, :images}, {stamp, images})
        images
    end
  end

  @doc "Whether a work's picture has been built."
  def has_image?(name), do: Map.has_key?(renditions(), name)

  attr :work, Work, required: true
  attr :sizes, :string, default: "(min-width: 1024px) 33vw, 90vw"
  attr :class, :string, default: nil
  attr :loading, :string, default: "lazy"
  attr :name, :string, default: nil, doc: "a second view's file name instead of the work's own"
  attr :transition, :string, default: nil
  attr :priority, :boolean, default: false
  attr :rest, :global

  def work_image(assigns) do
    name = assigns.name || assigns.work.image
    info = renditions()[name]

    {w, h} =
      case info do
        %{"w" => w, "h" => h} -> {w, h}
        _ -> {assigns.work.image_width, assigns.work.image_height}
      end

    assigns =
      assign(assigns,
        file: name,
        info: info,
        w: w,
        h: h,
        object?: not is_nil(assigns.work.depth_cm),
        alt: alt(assigns.work, assigns.name)
      )

    ~H"""
    <div
      class={["work-image", @object? && "object", @info && @info["studio"] && "studio", @class]}
      style={"aspect-ratio: #{@w} / #{@h};" <> if(@transition, do: " view-transition-name: #{@transition};", else: "")}
      {@rest}
    >
      <picture :if={@info}>
        <source type="image/avif" srcset={srcset(@file, @info, "avif")} sizes={@sizes} />
        <img
          src={"/images/works/#{@file}-#{min_width(@info)}.webp"}
          srcset={srcset(@file, @info, "webp")}
          sizes={@sizes}
          width={@w}
          height={@h}
          alt={@alt}
          loading={@loading}
          decoding="async"
          fetchpriority={@priority && "high"}
        />
      </picture>
      <div :if={!@info} class="placeholder" role="img" aria-label={@alt}>
        <span aria-hidden="true">{initials(@work)}</span>
      </div>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :alt, :string, required: true
  attr :sizes, :string, default: "(min-width: 1024px) 50vw, 92vw"
  attr :class, :string, default: nil
  attr :loading, :string, default: "lazy"
  attr :ratio, :string, default: "3 / 2"

  @doc "A photograph of the house: the saleroom, the building, the people."
  def photo(assigns) do
    info = renditions()[assigns.name]

    assigns =
      assign(assigns, info: info, ratio: (info && "#{info["w"]} / #{info["h"]}") || assigns.ratio)

    ~H"""
    <div class={["photo", @class]} style={"aspect-ratio: #{@ratio};"}>
      <picture :if={@info}>
        <source type="image/avif" srcset={photo_srcset(@name, @info, "avif")} sizes={@sizes} />
        <img
          src={"/images/photos/#{@name}-960.webp"}
          srcset={photo_srcset(@name, @info, "webp")}
          sizes={@sizes}
          width={@info["w"]}
          height={@info["h"]}
          alt={@alt}
          loading={@loading}
          decoding="async"
        />
      </picture>
      <div :if={!@info} class="placeholder" role="img" aria-label={@alt}></div>
    </div>
    """
  end

  defp photo_srcset(name, info, ext),
    do:
      info
      |> Map.get("widths", @widths)
      |> Enum.map_join(", ", &"/images/photos/#{name}-#{&1}.#{ext} #{&1}w")

  defp srcset(file, info, ext) do
    info
    |> Map.get("widths", @widths)
    |> Enum.map_join(", ", &"/images/works/#{file}-#{&1}.#{ext} #{&1}w")
  end

  defp min_width(info), do: info |> Map.get("widths", @widths) |> Enum.at(1, 960)

  defp alt(%Work{} = w, nil), do: "#{w.title}, #{w.year}. #{w.medium}."

  defp alt(%Work{} = w, second),
    do:
      if(String.ends_with?(second, "-room"),
        do: "#{w.title}, shown in a room for scale.",
        else: "#{w.title}, detail."
      )

  defp initials(%Work{title: t}), do: t |> String.first()

  attr :work, Work, required: true
  attr :link, :boolean, default: false
  attr :size, :string, default: nil

  def caption(assigns) do
    ~H"""
    <div class={["caption", @size]}>
      <p class="artist">
        <.artist_link artist={@work.artist} link={@link} />
        <span :if={Artist.dates(@work.artist)} class="dates">({Artist.dates(@work.artist)})</span>
      </p>
      <p class="work-title"><em>{@work.title}</em>, <span class="num">{@work.year}</span></p>
      <p class="medium">{@work.medium} · <span class="num">{Work.dimensions(@work)}</span></p>
    </div>
    """
  end

  attr :artist, Artist, required: true
  attr :link, :boolean, default: false

  def artist_link(assigns) do
    ~H"""
    <a :if={@link} href={~p"/artists/#{@artist.slug}"}>{@artist.name}</a><span :if={!@link}>{@artist.name}</span>
    """
  end

  attr :lot, Lot, required: true
  attr :class, :string, default: nil

  def estimate(assigns) do
    ~H"""
    <p class={["estimate", @class]}>
      <span class="estimate-word">Estimate</span>
      <span class="estimate-amount">{Format.estimate(@lot.estimate_low, @lot.estimate_high)}</span>
    </p>
    """
  end

  attr :at, DateTime, required: true
  attr :now, DateTime, default: nil
  attr :id, :string, required: true
  attr :prefix, :string, default: nil
  attr :class, :string, default: nil

  @doc "Time left, kept running by the browser against the server's clock."
  def countdown(assigns) do
    now = assigns.now || DateTime.utc_now()
    left = max(DateTime.diff(assigns.at, now, :second), 0)
    assigns = assign(assigns, left: left, urgency: urgency(left))

    ~H"""
    <span
      id={@id}
      class={["countdown", @class]}
      phx-hook="Countdown"
      phx-update="ignore"
      data-at={DateTime.to_iso8601(@at)}
      data-now={DateTime.to_iso8601(DateTime.utc_now())}
      data-prefix={@prefix}
      data-urgency={@urgency}
    ><%= if @prefix do %>
      {@prefix}
    <% end %>
    {Format.remaining(@left)}</span>
    """
  end

  defp urgency(left) when left <= 60, do: "now"
  defp urgency(left) when left <= 300, do: "soon"
  defp urgency(_), do: "later"

  @doc "What a lot's card says about its state, for a given viewer."
  def lot_state(%Lot{} = lot, user_id) do
    cond do
      lot.status == "sold" -> {:sold, "Sold #{Format.money(lot.hammer)}"}
      lot.status == "unsold" -> {:unsold, "Not sold"}
      lot.status == "withdrawn" -> {:unsold, "Withdrawn"}
      user_id && lot.leader_id == user_id -> {:leading, "With you"}
      true -> {:open, nil}
    end
  end

  attr :lot, Lot, required: true
  attr :user, :any, default: nil
  attr :mine, :boolean, default: false, doc: "the viewer has bid on this lot"
  attr :now, DateTime, default: nil
  attr :priority, :boolean, default: false

  def lot_card(assigns) do
    sale = assigns.lot.sale
    uid = assigns.user && assigns.user.id
    {state, text} = lot_state(assigns.lot, uid)

    outbid? =
      assigns.mine and state == :open and assigns.lot.leader_id != uid and
        not is_nil(assigns.lot.leader_id)

    assigns = assign(assigns, sale: sale, state: state, state_text: text, outbid: outbid?)

    ~H"""
    <a class="lot-card" href={Lot.path(@lot)} id={"lot-card-#{@lot.id}"}>
      <div class="frame">
        <.work_image
          work={@lot.work}
          sizes="(min-width: 1200px) 22vw, (min-width: 700px) 40vw, 82vw"
          transition={"work-#{@lot.work_id}"}
          loading={if @priority, do: "eager", else: "lazy"}
        />
      </div>
      <div class="meta">
        <span class="lotno num" aria-label={"Lot #{@lot.number}"}>{@lot.number}</span>
        <div>
          <.caption work={@lot.work} />
          <.estimate lot={@lot} class="mt-8" />
        </div>
        <div class="state">
          <%= cond do %>
            <% @state in [:sold, :unsold] -> %>
              <span class={["chip", @state == :sold && "sold", @state == :unsold && "plain"]}>{@state_text}</span>
            <% @sale.status == "upcoming" and Sale.live?(@sale) -> %>
              <span class="muted">Opening bid {Format.money(@lot.opening_bid)}</span>
            <% @sale.status == "upcoming" -> %>
              <span class="muted">Bidding opens {lower_first(Format.when_(@sale.opens_at))}</span>
            <% Sale.live?(@sale) -> %>
              <span class="bid">{if @lot.current_bid,
                do: Format.money(@lot.current_bid),
                else: "On the block soon"}</span>
            <% true -> %>
              <span class="bid">
                {if @lot.current_bid,
                  do: Format.money(@lot.current_bid),
                  else: Format.money(@lot.opening_bid)}<small>{if @lot.bid_count > 0,
                  do: Format.count(@lot.bid_count, "bid", "bids"),
                  else: "to open"}</small>
              </span>
              <span :if={@state == :leading} class="chip leading">With you</span>
              <span :if={@outbid} class="chip outbid">Outbid</span>
              <.countdown
                :if={@lot.closes_at && @lot.status == "open"}
                id={"cd-#{@lot.id}"}
                at={@lot.closes_at}
                now={@now}
              />
          <% end %>
        </div>
      </div>
    </a>
    """
  end

  attr :sale, Sale, required: true
  attr :count, :integer, default: nil
  attr :now, DateTime, default: nil

  def sale_cover(assigns) do
    ~H"""
    <a class={["sale-cover", Sale.live?(@sale) && "night-cover"]} href={Sale.path(@sale)}>
      <div class="top">
        <span class={["chip", sale_chip(@sale)]}>{sale_status(@sale)}</span>
        <span class="number">Sale {@sale.number}</span>
      </div>
      <div>
        <h3>{@sale.title}</h3>
        <p class="when" style="margin-top: 10px">{sale_when(@sale, @now)}</p>
      </div>
      <span class="text-link">{if @sale.status == "live",
        do: "Enter the saleroom",
        else: "View the catalogue"} <span class="arrow" aria-hidden="true">→</span></span>
    </a>
    """
  end

  def sale_chip(%Sale{status: "live"}), do: "live"
  def sale_chip(%Sale{status: "open"}), do: "leading"
  def sale_chip(_), do: "plain"

  def sale_status(%Sale{status: "live"}), do: "Live now"
  def sale_status(%Sale{status: "open"}), do: "Open for bidding"
  def sale_status(%Sale{status: "upcoming", format: "live"}), do: "Live sale"
  def sale_status(%Sale{status: "upcoming"}), do: "Opens soon"
  def sale_status(%Sale{status: "closed"}), do: "Results"
  def sale_status(_), do: "Draft"

  def sale_when(sale, now \\ nil)

  def sale_when(%Sale{format: "live", status: "live"}, _now),
    do: "Selling now, online and in the room"

  def sale_when(%Sale{format: "live", starts_at: %DateTime{} = at, status: "upcoming"}, now),
    do: "#{Format.when_(at, now || DateTime.utc_now())} · Umber House and online"

  def sale_when(%Sale{format: "timed", status: "upcoming", opens_at: at}, now),
    do: "Bidding opens #{lower_first(Format.when_(at, now || DateTime.utc_now()))}"

  def sale_when(%Sale{format: "timed", status: "open", first_close_at: at}, now),
    do:
      "Lots close one every two minutes from #{lower_first(Format.when_(at, now || DateTime.utc_now()))}"

  def sale_when(%Sale{status: "closed", ended_at: %DateTime{} = at}, _),
    do: "Sold #{Format.date(at)}"

  def sale_when(_, _), do: nil

  # "Today at 14:30" -> "today at 14:30"; dates such as "24 Sep at 19:00" stay as they are.
  defp lower_first(<<c::utf8, rest::binary>>) when c in ?A..?Z,
    do: String.downcase(<<c::utf8>>) <> rest

  defp lower_first(s), do: s
end
