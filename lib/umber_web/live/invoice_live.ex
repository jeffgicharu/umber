defmodule UmberWeb.InvoiceLive do
  use UmberWeb, :live_view

  alias Umber.Auctions
  alias Umber.Auctions.Invoice
  alias Umber.Catalogue.Lot
  alias UmberWeb.Meta

  @impl true
  def mount(%{"number" => number}, _session, socket) do
    case Auctions.get_invoice(socket.assigns.current_user, number) do
      %Invoice{} = inv ->
        {:ok,
         socket
         |> assign(inv: inv)
         |> Meta.put(title: "Invoice #{inv.number}", path: "/account/invoices/#{inv.number}")}

      nil ->
        raise UmberWeb.NotFound
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} live_now={@live_now} notices={@notices}>
      <div class="wrap">
        <nav class="crumbs" aria-label="Breadcrumb">
          <a href={~p"/account/purchases"}>Purchases</a><span class="sep">/</span><span>Invoice {@inv.number}</span>
        </nav>
      </div>
      <article class="wrap invoice" aria-labelledby="inv-title">
        <header class="invoice-head">
          <div>
            <p class="wordmark">
              <span class="name">Umber</span><span class="place">Auctioneers · Nairobi</span>
            </p>
            <p class="muted">Umber House, Lenana Road, Kilimani, Nairobi</p>
          </div>
          <div class="invoice-meta">
            <h1 id="inv-title" class="label">Invoice</h1>
            <p class="serif num invoice-number">{@inv.number}</p>
            <p class="muted">Issued {Format.short_datetime(@inv.inserted_at)}</p>
            <p>
              <span class={[
                "chip",
                @inv.status == "paid" && "leading",
                @inv.status == "due" && "outbid"
              ]}>{if @inv.status == "paid",
                do: "Paid #{Format.short_datetime(@inv.paid_at)}",
                else: "Payment due"}</span>
            </p>
          </div>
        </header>

        <section class="invoice-to">
          <p class="label">Buyer</p>
          <p>{@inv.user.name}, paddle <span class="num">{@inv.user.paddle}</span></p>
          <p class="muted">{@inv.user.country}</p>
        </section>

        <section class="invoice-lot">
          <div class="invoice-thumb"><.work_image work={@inv.lot.work} sizes="160px" /></div>
          <div>
            <p class="label">Sale {@inv.lot.sale.number} · Lot {@inv.lot.number}</p>
            <.caption work={@inv.lot.work} />
            <a class="text-link" href={Lot.path(@inv.lot)} style="margin-top: 10px">The lot
            <span class="arrow" aria-hidden="true">→</span></a>
          </div>
        </section>

        <table class="table invoice-table">
          <tbody>
            <tr>
              <td>Hammer price</td><td class="num">{Format.money(@inv.hammer)}</td>
            </tr>
            <tr>
              <td>Buyer's premium, {Invoice.premium_rate()}% of the hammer price</td><td class="num">
                {Format.money(@inv.premium)}
              </td>
            </tr>
            <tr>
              <td>VAT, {Invoice.vat_rate()}% on the premium</td><td class="num">
                {Format.money(@inv.vat)}
              </td>
            </tr>
            <tr class="invoice-total">
              <td>{if @inv.status == "paid", do: "Total paid", else: "Total due"}</td>
              <td class="num serif">{Format.money(@inv.total)}</td>
            </tr>
          </tbody>
        </table>

        <section :if={@inv.status == "due"} class="invoice-pay">
          <p class="label">Paying</p>
          <p>
            Please pay within seven days of the sale, by bank transfer or at Umber House. Our client services team will give you our bank details on request and confirm when payment arrives. The lot is ready to collect once it is paid for, and we keep it free for fourteen days.
          </p>
        </section>
        <p class="invoice-note muted">
          Sold on Umber's <a href={~p"/conditions"}>conditions of sale</a>.
        </p>
        <button type="button" class="btn ghost print-button" onclick="window.print()">Print the invoice</button>
      </article>
    </Layouts.app>
    """
  end
end
