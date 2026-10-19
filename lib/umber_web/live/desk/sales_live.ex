defmodule UmberWeb.Desk.SalesLive do
  use UmberWeb, :live_view

  alias Umber.{Catalogue, Events}
  alias Umber.Catalogue.Sale

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe("market")
    {:ok, socket |> assign(page_title: "Sales") |> load()}
  end

  defp load(socket) do
    sales = Catalogue.desk_sales()

    assign(socket,
      sales: sales,
      counts: Map.new(sales, &{&1.id, length(Catalogue.sale_lots(&1))}),
      now: DateTime.utc_now()
    )
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, load(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.desk flash={@flash} current_user={@current_user} active={:sales}>
      <header class="desk-head">
        <div>
          <p class="label">Specialists</p>
          <h1>Sales</h1>
        </div>
        <a class="btn" href={~p"/desk/sales/new"}>New sale</a>
      </header>
      <div class="desk-card">
        <div class="table-scroll">
          <table class="table">
            <thead>
              <tr>
                <th class="num">Sale</th><th>Title</th><th>Format</th><th>Status</th><th>When</th><th class="num">
                  Lots
                </th><th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={s <- @sales}>
                <td class="num serif">{s.number}</td>
                <td>
                  <a href={~p"/desk/sales/#{s.number}"}>{s.title}</a><br :if={s.template} /><span
                    :if={s.template}
                    class="muted"
                  >Running sale</span>
                </td>
                <td>{if Sale.live?(s), do: "Live", else: "Online"}</td>
                <td>
                  <span class={["chip", s.status == "draft" && "plain", sale_chip(s)]}>{if s.status ==
                                                                                             "draft",
                                                                                           do:
                                                                                             "Draft",
                                                                                           else:
                                                                                             sale_status(
                                                                                               s
                                                                                             )}</span>
                </td>
                <td class="muted">
                  {sale_when(s, @now) || (s.starts_at && Format.short_datetime(s.starts_at)) ||
                    (s.opens_at && Format.short_datetime(s.opens_at)) || "Not scheduled"}
                </td>
                <td class="num">{@counts[s.id]}</td>
                <td class="desk-row-actions">
                  <a
                    :if={Sale.live?(s) and s.status in ["upcoming", "live"]}
                    class="btn small"
                    href={~p"/desk/rostrum/#{s.number}"}
                  >Rostrum</a>
                  <a :if={s.published} class="btn ghost small" href={Sale.path(s)} target="_blank">On the website</a>
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
