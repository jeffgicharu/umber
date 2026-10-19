defmodule UmberWeb.Desk.SessionController do
  use UmberWeb, :controller

  alias Umber.Accounts
  alias Umber.Accounts.User
  alias UmberWeb.{UserAuth, Meta, RateLimit}

  def new(conn, _params) do
    if User.staff?(conn.assigns.current_user) do
      redirect(conn, to: ~p"/desk")
    else
      conn
      |> Meta.put(title: "Staff sign in", path: "/desk/signin")
      |> render(:new, form: Phoenix.Component.to_form(%{"email" => ""}, as: :session), error: nil)
    end
  end

  def create(conn, %{"session" => %{"email" => email, "password" => password}}) do
    with :ok <- RateLimit.check({:desk_signin, conn.remote_ip}, 10, 60),
         %User{kind: "staff"} = user <- Accounts.get_user_by_email_and_password(email, password) do
      UserAuth.log_in_user(conn, user, ~p"/desk")
    else
      _ ->
        conn
        |> put_status(422)
        |> Meta.put(title: "Staff sign in", path: "/desk/signin")
        |> render(:new,
          form: Phoenix.Component.to_form(%{"email" => email}, as: :session),
          error: "That email and password do not match a staff account."
        )
    end
  end

  @doc """
  A temporary staff account for a visitor trying the desk, from the link that
  carries the trial key. It lasts 24 hours and cannot publish sales.
  """
  def try(conn, %{"key" => key}) do
    expected = Application.get_env(:umber, :staff_trial_key)

    with true <- is_binary(expected) and Plug.Crypto.secure_compare(key, expected),
         :ok <- RateLimit.check({:trial_staff, conn.remote_ip}, 10, 3600),
         {:ok, user} <- Accounts.create_trial_staff() do
      conn
      |> put_flash(
        :info,
        "You are signed in as #{user.name} for 24 hours: specialist, auctioneer and client services."
      )
      |> UserAuth.log_in_user(user, ~p"/desk")
    else
      {:error, :rate_limited} ->
        conn
        |> put_flash(:error, "Too many guest accounts from this connection. Try again later.")
        |> redirect(to: ~p"/desk/signin")

      _ ->
        conn |> put_flash(:error, "That link has expired.") |> redirect(to: ~p"/desk/signin")
    end
  end

  def try(conn, _params), do: redirect(conn, to: ~p"/desk/signin")
end

defmodule UmberWeb.Desk.SessionHTML do
  use UmberWeb, :html

  def new(assigns) do
    ~H"""
    <div class="desk-signin">
      <a class="wordmark" href={~p"/"}><span class="name">Umber</span><span class="place">Desk</span></a>
      <div class="form-panel">
        <h1>Staff sign in</h1>
        <p :if={@error} class="error-text" role="alert">{@error}</p>
        <.form for={@form} action={~p"/desk/signin"} id="desk-signin-form">
          <.input field={@form[:email]} type="email" label="Email" autocomplete="username" required />
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="current-password"
            required
          />
          <button type="submit" class="btn block">Sign in</button>
        </.form>
        <p class="muted" style="margin-top: 16px"><a href={~p"/"}>Back to the website</a></p>
      </div>
    </div>
    <Layouts.flash_group flash={@flash} />
    """
  end
end
