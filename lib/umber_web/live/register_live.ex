defmodule UmberWeb.RegisterLive do
  use UmberWeb, :live_view

  alias Umber.Accounts
  alias UmberWeb.{Meta, RateLimit}

  @countries [
    "Kenya",
    "Tanzania",
    "Uganda",
    "Rwanda",
    "Ethiopia",
    "Burundi",
    "South Sudan",
    "Somalia",
    "Nigeria",
    "Ghana",
    "South Africa",
    "United Kingdom",
    "United States",
    "Germany",
    "France",
    "Netherlands",
    "Sweden",
    "United Arab Emirates",
    "India",
    "Other"
  ]

  @impl true
  def mount(params, _session, socket) do
    if socket.assigns.current_user do
      {:ok, push_navigate(socket, to: ~p"/account")}
    else
      {:ok,
       socket
       |> assign(
         form: to_form(Accounts.change_registration(%{"country" => "Kenya"}), as: :user),
         countries: @countries,
         return_to: params["return_to"],
         # connect_info can only be read here, in mount.
         ip: if(connected?(socket), do: get_connect_info_ip(socket), else: :unknown),
         trigger_submit: false,
         token: nil
       )
       |> Meta.put(
         title: "Register to bid",
         description:
           "Register with Umber in a minute and bid live from the rostrum or online, from your phone.",
         path: "/register"
       )}
    end
  end

  @impl true
  def handle_event("validate", %{"user" => attrs}, socket) do
    form =
      attrs |> Accounts.change_registration() |> Map.put(:action, :validate) |> to_form(as: :user)

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("save", %{"user" => attrs}, socket) do
    with :ok <- RateLimit.check({:register, socket.assigns.ip}, 5, 600),
         {:ok, user} <- Accounts.register_bidder(attrs) do
      token = Accounts.generate_session_token(user)

      {:noreply,
       assign(socket,
         trigger_submit: true,
         token: Base.url_encode64(token),
         form: to_form(%{}, as: :user)
       )}
    else
      {:error, :rate_limited} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Too many accounts from this connection. Please try again in a few minutes."
         )}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, form: to_form(Map.put(cs, :action, :insert), as: :user))}
    end
  end

  # nginx passes the visitor's address in X-Real-IP; the connection itself is local.
  defp get_connect_info_ip(socket) do
    headers = get_connect_info(socket, :x_headers) || []

    case List.keyfind(headers, "x-real-ip", 0) do
      {_, ip} ->
        ip

      nil ->
        with(
          %{address: addr} <- get_connect_info(socket, :peer_data),
          do: addr,
          else: (_ -> :unknown)
        )
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} live_now={@live_now} notices={@notices}>
      <div class="wrap auth">
        <div class="auth-side" aria-hidden="true">
          <p class="label">What you get</p>
          <ul class="auth-points">
            <li><span class="serif">A paddle number</span> for every sale, live and online.</li>
            <li>
              <span class="serif">A bidding limit</span>
              of {Format.money(Accounts.default_limit())} a lot, raised on request.
            </li>
            <li>
              <span class="serif">Notices as you browse</span>
              when you are outbid or win, and on your phone if you wish.
            </li>
          </ul>
        </div>
        <div class="auth-main">
          <p class="label">Register to bid</p>
          <h1>Your paddle, in a minute</h1>
          <.form
            for={@form}
            id="register-form"
            phx-change="validate"
            phx-submit="save"
            action={~p"/signin/welcome"}
            method="post"
            phx-trigger-action={@trigger_submit}
            class="auth-form"
          >
            <input type="hidden" name="token" value={@token} />
            <input :if={@return_to} type="hidden" name="return_to" value={@return_to} />
            <.input field={@form[:name]} label="Full name" autocomplete="name" required />
            <.input
              field={@form[:email]}
              type="email"
              label="Email"
              autocomplete="email"
              hint="We never send email; it is how you sign in."
              required
            />
            <.input
              field={@form[:password]}
              type="password"
              label="Password"
              autocomplete="new-password"
              hint="At least 10 characters."
              required
            />
            <div class="field-pair">
              <.input
                field={@form[:country]}
                type="select"
                label="Country"
                options={@countries}
                required
              />
              <.input
                field={@form[:phone]}
                type="tel"
                label="Phone (optional)"
                autocomplete="tel"
                inputmode="tel"
              />
            </div>
            <.input field={@form[:accept_conditions]} type="checkbox">
              I accept the <a href={~p"/conditions"} target="_blank">conditions of sale</a>, including the 20% buyer's premium.
            </.input>
            <button type="submit" class="btn block" phx-disable-with="Registering…">Register and get my paddle
            <span class="arrow" aria-hidden="true">→</span></button>
          </.form>
          <p class="auth-alt">
            Already registered? <a href={
              ~p"/signin?#{if @return_to, do: [return_to: @return_to], else: []}"
            }>Sign in</a>.
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
