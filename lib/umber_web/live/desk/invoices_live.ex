defmodule UmberWeb.Desk.InvoicesLive do
  use UmberWeb, :live_view

  alias Umber.{Auctions, Repo}
  alias Umber.Auctions.Invoice

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, page_title: "Invoices")}

  @impl true
  def handle_params(params, _uri, socket) do
    status = if params["status"] in ["due", "paid"], do: params["status"]

    {:noreply,
     assign(socket, status: status, invoices: Auctions.list_invoices(status: status, limit: 100))}
  end

  @impl true
  def handle_event("paid", %{"id" => id}, socket) do
    inv = Repo.get!(Invoice, id)

    case Auctions.mark_paid(inv, socket.assigns.current_user) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Invoice #{inv.number} marked paid.")
         |> assign(invoices: Auctions.list_invoices(status: socket.assigns.status, limit: 100))}

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, "Marking invoices paid needs the client services role.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.desk flash={@flash} current_user={@current_user} active={:invoices}>
      <header class="desk-head">
        <div>
          <p class="label">Client services</p>
          <h1>Invoices</h1>
        </div>
        <nav class="desk-filter" aria-label="Show">
          <.link patch={~p"/desk/invoices"} aria-current={is_nil(@status) && "page"}>All</.link>
          <.link patch={~p"/desk/invoices?status=due"} aria-current={@status == "due" && "page"}>Due</.link>
          <.link patch={~p"/desk/invoices?status=paid"} aria-current={@status == "paid" && "page"}>Paid</.link>
        </nav>
      </header>
      <div class="desk-card">
        <p :if={@invoices == []} class="muted">No invoices here.</p>
        <div :if={@invoices != []} class="table-scroll">
          <table class="table">
            <thead>
              <tr>
                <th>Invoice</th><th>Buyer</th><th>Lot</th><th class="num">Hammer</th><th class="num">
                  Total
                </th><th>Status</th><th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={i <- @invoices}>
                <td>
                  <a href={~p"/account/invoices/#{i.number}"}>{i.number}</a><br /><span class="muted">{Format.short_datetime(
                    i.inserted_at
                  )}</span>
                </td>
                <td>{i.user.name}<br /><span class="muted">Paddle {i.user.paddle}</span></td>
                <td>
                  <em class="serif">{i.lot.work.title}</em><br /><span class="muted">Sale {i.lot.sale.number}, lot {i.lot.number}</span>
                </td>
                <td class="num">{Format.thousands(i.hammer)}</td>
                <td class="num">{Format.thousands(i.total)}</td>
                <td>
                  <span class={[
                    "chip",
                    i.status == "paid" && "leading",
                    i.status == "due" && "outbid"
                  ]}>{String.capitalize(i.status)}</span>
                </td>
                <td>
                  <button
                    :if={i.status == "due"}
                    class="btn ghost small"
                    phx-click="paid"
                    phx-value-id={i.id}
                  >Mark paid</button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.desk>
    """
  end
end
