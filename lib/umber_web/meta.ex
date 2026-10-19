defmodule UmberWeb.Meta do
  @moduledoc """
  Each page's title, description, canonical address, sharing picture and
  structured data, rendered into the head by the root layout.
  """

  @host "https://umber.jeffgicharu.com"
  @default_description "Umber is an auction house in Nairobi for modern and contemporary East African art and collectable design, with live sales from the rostrum and online sales that close lot by lot."

  def host, do: Application.get_env(:umber, :public_url, @host)
  def default_description, do: @default_description

  @doc "Puts the page's metadata on a socket or conn."
  def put(socket_or_conn, opts) do
    meta = %{
      title: Keyword.fetch!(opts, :title),
      description: Keyword.get(opts, :description, @default_description),
      path: Keyword.get(opts, :path, "/"),
      image: Keyword.get(opts, :image),
      image_alt: Keyword.get(opts, :image_alt),
      type: Keyword.get(opts, :type, "website"),
      json_ld: Keyword.get(opts, :json_ld, [])
    }

    case socket_or_conn do
      %Phoenix.LiveView.Socket{} = s ->
        Phoenix.Component.assign(s, page_title: meta.title, meta: meta)

      %Plug.Conn{} = c ->
        Plug.Conn.merge_assigns(c, page_title: meta.title, meta: meta)
    end
  end

  def url(path), do: host() <> path

  @doc "The sharing picture: a work's 1600 px JPEG, or the house picture."
  def image_url(nil), do: url("/images/share/umber-share.jpg")
  def image_url("/" <> _ = path), do: url(path)
  def image_url(work_image), do: url("/images/works/#{work_image}-1600.jpg")

  @doc "The house, as search engines read it."
  def organization do
    %{
      "@context" => "https://schema.org",
      "@type" => "Organization",
      "@id" => url("/#organization"),
      "name" => "Umber",
      "description" => @default_description,
      "url" => url("/"),
      "logo" => url("/images/brand/umber-mark-512.png"),
      "address" => %{
        "@type" => "PostalAddress",
        "streetAddress" => "Umber House, Lenana Road",
        "addressLocality" => "Nairobi",
        "addressCountry" => "KE"
      }
    }
  end

  def json(data), do: data |> Jason.encode!() |> String.replace("</", "<\\/")
end
