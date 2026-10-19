defmodule UmberWeb.UserAuth do
  @moduledoc "Signing in and out, and who may see which pages."

  use UmberWeb, :verified_routes
  import Plug.Conn
  import Phoenix.Controller

  alias Umber.Accounts
  alias Umber.Accounts.User

  @remember_cookie "_umber_remember"
  @remember_options [sign: true, max_age: 60 * 60 * 24 * 30, same_site: "Lax"]

  @doc "Signs a user in and sends them where they were going."
  def log_in_user(conn, user, return_to \\ nil) do
    token = Accounts.generate_session_token(user)

    conn
    |> renew_session()
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, "users_sessions:#{Base.url_encode64(token)}")
    |> put_resp_cookie(@remember_cookie, token, @remember_options)
    |> redirect(to: safe_return(return_to) || signed_in_path(user))
  end

  # Only paths on this site; never "//elsewhere".
  defp safe_return("//" <> _), do: nil
  defp safe_return("/" <> _ = path), do: path
  defp safe_return(_), do: nil

  def signed_in_path(%User{kind: "staff"}), do: ~p"/desk"
  def signed_in_path(_), do: ~p"/account"

  def log_out_user(conn) do
    if token = get_session(conn, :user_token), do: Accounts.delete_session_token(token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      UmberWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session()
    |> delete_resp_cookie(@remember_cookie)
    |> redirect(to: ~p"/")
  end

  defp renew_session(conn) do
    delete_csrf_token()
    conn |> configure_session(renew: true) |> clear_session()
  end

  @doc "Plug: reads the user from the session or the remember-me cookie."
  def fetch_current_user(conn, _opts) do
    {token, conn} = ensure_token(conn)
    user = token && Accounts.get_user_by_session_token(token)
    if user, do: Accounts.touch(user)
    assign(conn, :current_user, user)
  end

  defp ensure_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_cookie])

      if token = conn.cookies[@remember_cookie] do
        {token,
         conn
         |> put_session(:user_token, token)
         |> put_session(:live_socket_id, "users_sessions:#{Base.url_encode64(token)}")}
      else
        {nil, conn}
      end
    end
  end

  def require_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(:info, "Sign in to see your account.")
      |> redirect(to: ~p"/signin?#{[return_to: current_path(conn)]}")
      |> halt()
    end
  end

  def require_staff(conn, _opts) do
    if User.staff?(conn.assigns[:current_user]) do
      conn
    else
      conn |> redirect(to: ~p"/desk/signin") |> halt()
    end
  end

  def redirect_if_signed_in(conn, _opts) do
    if user = conn.assigns[:current_user] do
      conn |> redirect(to: signed_in_path(user)) |> halt()
    else
      conn
    end
  end

  ## LiveView

  def on_mount(:mount_current_user, _params, session, socket) do
    {:cont, mount_current_user(socket, session)}
  end

  def on_mount(:require_user, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if socket.assigns.current_user do
      {:cont, socket}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:info, "Sign in to see your account.")
       |> Phoenix.LiveView.redirect(to: ~p"/signin")}
    end
  end

  def on_mount(:require_staff, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if User.staff?(socket.assigns.current_user),
      do: {:cont, socket},
      else: {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/desk/signin")}
  end

  defp mount_current_user(socket, session) do
    Phoenix.Component.assign_new(socket, :current_user, fn ->
      if token = session["user_token"], do: Accounts.get_user_by_session_token(token)
    end)
  end
end
