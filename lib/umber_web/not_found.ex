defmodule UmberWeb.NotFound do
  @moduledoc "Raised for a sale, lot, artist or invoice that does not exist; shown as Umber's 404 page."
  defexception message: "not found", plug_status: 404
end
