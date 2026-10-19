defmodule UmberWeb.Desk.UploadController do
  @moduledoc "Consignment photographs, for staff only."
  use UmberWeb, :controller

  def show(conn, %{"name" => name}) do
    if Regex.match?(~r/^[0-9a-f-]{36}\.(jpg|webp)$/, name) do
      path = Path.join(UmberWeb.SellLive.uploads_dir(), name)

      if File.regular?(path) do
        conn
        |> put_resp_content_type(
          if String.ends_with?(name, ".webp"), do: "image/webp", else: "image/jpeg"
        )
        |> put_resp_header("cache-control", "private, max-age=3600")
        |> send_file(200, path)
      else
        send_resp(conn, 404, "")
      end
    else
      send_resp(conn, 404, "")
    end
  end
end
