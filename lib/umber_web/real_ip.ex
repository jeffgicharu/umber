defmodule UmberWeb.RealIP do
  @moduledoc """
  Requests reach the app from nginx on this machine, which passes the
  visitor's address in X-Real-IP. Only a local connection is trusted with it.
  """
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{remote_ip: {127, 0, 0, 1}} = conn, _opts) do
    with [value | _] <- Plug.Conn.get_req_header(conn, "x-real-ip"),
         {:ok, ip} <- :inet.parse_address(String.to_charlist(String.trim(value))) do
      %{conn | remote_ip: ip}
    else
      _ -> conn
    end
  end

  def call(conn, _opts), do: conn
end
