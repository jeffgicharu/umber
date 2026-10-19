defmodule UmberWeb.Desk.ConsignmentsLive do
  use UmberWeb, :live_view

  alias Umber.{Desk, Events}
  alias Umber.Desk.Consignment

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe("desk")
    {:ok, assign(socket, page_title: "Consignments")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    status = if params["status"] in Consignment.statuses(), do: params["status"]

    open =
      with id when is_binary(id) <- params["open"],
           {n, ""} <- Integer.parse(id),
           do: n,
           else: (_ -> nil)

    {:noreply,
     socket
     |> assign(status: status, open: open)
     |> load()}
  end

  defp load(socket) do
    items = Desk.list_consignments(socket.assigns.status)
    current = socket.assigns.open && Enum.find(items, &(&1.id == socket.assigns.open))
    current = current || (socket.assigns.open && Desk.get_consignment!(socket.assigns.open))
    form = current && to_form(Consignment.review_changeset(current, %{}), as: :review)
    assign(socket, items: items, current: current, form: form)
  end

  @impl true
  def handle_event("review", %{"review" => attrs}, socket) do
    case Desk.review_consignment(socket.assigns.current, socket.assigns.current_user, attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved. The consignor sees the new status in their account.")
         |> load()}

      {:error, :not_allowed} ->
        {:noreply,
         put_flash(socket, :error, "Reviewing needs the specialist or client services role.")}

      {:error, cs} ->
        {:noreply, assign(socket, form: to_form(cs, as: :review))}
    end
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, load(socket)}

  defp status_name("new"), do: "New"
  defp status_name("reviewing"), do: "With a specialist"
  defp status_name("invited"), do: "Invited to consign"
  defp status_name("declined"), do: "Declined"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.desk flash={@flash} current_user={@current_user} active={:consignments}>
      <header class="desk-head">
        <div>
          <p class="label">Specialists</p>
          <h1>Consignments</h1>
        </div>
        <nav class="desk-filter" aria-label="Show">
          <.link patch={~p"/desk/consignments"} aria-current={is_nil(@status) && "page"}>All</.link>
          <.link
            :for={s <- Consignment.statuses()}
            patch={~p"/desk/consignments?#{[status: s]}"}
            aria-current={@status == s && "page"}
          >{status_name(s)}</.link>
        </nav>
      </header>

      <div class="desk-split">
        <div class="desk-card">
          <p :if={@items == []} class="muted">No enquiries here.</p>
          <ul class="desk-list selectable">
            <li :for={c <- @items} class={@current && @current.id == c.id && "selected"}>
              <.link patch={
                ~p"/desk/consignments?#{Enum.reject([status: @status, open: c.id], fn {_, v} -> is_nil(v) end)}"
              }>
                <strong>{c.artist_name}</strong>{if c.title, do: ", #{c.title}"}
                <span class="muted">{c.name} · {Format.short_datetime(c.inserted_at)} · {Format.count(
                  length(c.photos),
                  "photo",
                  "photos"
                )}</span>
              </.link>
              <span class="chip plain">{status_name(c.status)}</span>
            </li>
          </ul>
        </div>

        <div :if={@current} class="desk-card">
          <p class="label">Enquiry {@current.id} · {Format.short_datetime(@current.inserted_at)}</p>
          <h2 class="desk-card-title">
            {@current.artist_name}{if @current.title, do: ", #{@current.title}"}
          </h2>
          <dl class="details">
            <div :if={@current.medium}>
              <dt class="label">Medium</dt><dd>{@current.medium}</dd>
            </div>
            <div :if={@current.dimensions}>
              <dt class="label">Size</dt><dd>{@current.dimensions}</dd>
            </div>
            <div>
              <dt class="label">About the work</dt><dd>{@current.description}</dd>
            </div>
            <div :if={@current.acquired}>
              <dt class="label">Acquired</dt><dd>{@current.acquired}</dd>
            </div>
            <div>
              <dt class="label">From</dt><dd>
                {@current.name} · {@current.email}{if @current.phone, do: " · #{@current.phone}"}
              </dd>
            </div>
          </dl>
          <div :if={@current.photos != []} class="consign-photos">
            <a :for={p <- @current.photos} href={~p"/desk/uploads/#{p}"} target="_blank">
              <img
                src={~p"/desk/uploads/#{p}"}
                alt={"Photograph sent with enquiry #{@current.id}"}
                loading="lazy"
              />
            </a>
          </div>
          <.form for={@form} phx-submit="review" id="review-form" style="margin-top: 20px">
            <.input
              field={@form[:status]}
              type="select"
              label="Status"
              options={Enum.map(Consignment.statuses(), &{status_name(&1), &1})}
            />
            <.input field={@form[:staff_note]} type="textarea" label="Note for the file" rows="3" />
            <button type="submit" class="btn">Save</button>
          </.form>
        </div>
      </div>
    </Layouts.desk>
    """
  end
end
