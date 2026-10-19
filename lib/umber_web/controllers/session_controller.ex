defmodule UmberWeb.SessionController do
  use UmberWeb, :controller

  alias Umber.Accounts
  alias UmberWeb.{UserAuth, Meta, RateLimit}

  plug :redirect_if_signed_in when action in [:new, :create]

  def new(conn, params) do
    conn
    |> Meta.put(
      title: "Sign in",
      description: "Sign in to bid, follow your lots and see your purchases at Umber.",
      path: "/signin"
    )
    |> render(:new,
      form: Phoenix.Component.to_form(%{"email" => ""}, as: :session),
      error: nil,
      return_to: params["return_to"]
    )
  end

  def create(conn, %{"session" => %{"email" => email, "password" => password} = p}) do
    return_to = p["return_to"]

    with :ok <- RateLimit.check({:signin, conn.remote_ip}, 10, 60),
         %Umber.Accounts.User{kind: kind} = user when kind != "sample" <-
           Accounts.get_user_by_email_and_password(email, password) do
      conn
      |> put_flash(:info, "Welcome back, #{Umber.Accounts.User.first_name(user)}.")
      |> UserAuth.log_in_user(user, return_to)
    else
      {:error, :rate_limited} ->
        render_error(
          conn,
          email,
          return_to,
          "Too many attempts. Please wait a minute and try again."
        )

      _ ->
        render_error(conn, email, return_to, "That email and password do not match an account.")
    end
  end

  @doc "The end of registration: the new bidder's first sign-in, from the token the form was given."
  def welcome(conn, %{"token" => token} = params) do
    with {:ok, raw} <- Base.url_decode64(token),
         %Umber.Accounts.User{} = user <- Accounts.get_user_by_session_token(raw) do
      Accounts.delete_session_token(raw)

      conn
      |> put_flash(:info, "Welcome to Umber. Your paddle number is #{user.paddle}.")
      |> UserAuth.log_in_user(user, params["return_to"])
    else
      _ -> conn |> put_flash(:error, "Please sign in.") |> redirect(to: ~p"/signin")
    end
  end

  def delete(conn, _params) do
    conn |> put_flash(:info, "You are signed out.") |> UserAuth.log_out_user()
  end

  defp render_error(conn, email, return_to, message) do
    conn
    |> put_status(422)
    |> Meta.put(title: "Sign in", path: "/signin")
    |> render(:new,
      form: Phoenix.Component.to_form(%{"email" => email}, as: :session),
      error: message,
      return_to: return_to
    )
  end

  defp redirect_if_signed_in(conn, _), do: UserAuth.redirect_if_signed_in(conn, [])
end

defmodule UmberWeb.SessionHTML do
  use UmberWeb, :html

  def new(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="wrap auth">
        <div class="auth-side" aria-hidden="true">
          <p class="label">Paddle</p>
          <p class="auth-paddle serif num">1043</p>
          <p class="auth-side-text">
            One account, one paddle number, for every sale: live from the rostrum and online.
          </p>
        </div>
        <div class="auth-main">
          <p class="label">Your account</p>
          <h1>Sign in</h1>
          <p :if={@error} class="error-text" role="alert">{@error}</p>
          <.form for={@form} action={~p"/signin"} class="auth-form" id="signin-form">
            <input :if={@return_to} type="hidden" name="session[return_to]" value={@return_to} />
            <.input field={@form[:email]} type="email" label="Email" autocomplete="email" required />
            <.input
              field={@form[:password]}
              type="password"
              label="Password"
              autocomplete="current-password"
              required
            />
            <button type="submit" class="btn block">Sign in
            <span class="arrow" aria-hidden="true">→</span></button>
          </.form>
          <p class="auth-alt">
            New to Umber? <a href={
              ~p"/register?#{if @return_to, do: [return_to: @return_to], else: []}"
            }>Register to bid</a>, it takes a minute.
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
