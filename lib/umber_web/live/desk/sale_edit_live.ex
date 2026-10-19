defmodule UmberWeb.Desk.SaleEditLive do
  use UmberWeb, :live_view

  alias Umber.Catalogue
  alias Umber.Catalogue.{Sale, Lot}
  alias Umber.Accounts.User

  @impl true
  def mount(params, _session, socket) do
    case socket.assigns.live_action do
      :new ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        sale = %Sale{
          format: "timed",
          category: "Art",
          lot_interval: 120,
          opens_at: DateTime.add(now, 3600, :second),
          first_close_at: DateTime.add(now, 2 * 86_400, :second)
        }

        {:ok,
         socket
         |> assign(page_title: "New sale", sale: sale, lots: [], works: [])
         |> assign_form(Catalogue.change_sale(sale))}

      :edit ->
        case Catalogue.get_sale_by_number(params["number"]) do
          %Sale{} = sale ->
            {:ok,
             socket
             |> assign(
               page_title: "Sale #{sale.number}",
               sale: sale,
               lots: Catalogue.sale_lots(sale),
               works: Catalogue.works_for_picker()
             )
             |> assign(
               lot_form: to_form(%{"work_id" => "", "low" => "", "high" => ""}, as: :lot),
               lot_error: nil
             )
             |> assign_form(Catalogue.change_sale(sale))}

          nil ->
            raise UmberWeb.NotFound
        end
    end
  end

  defp assign_form(socket, cs), do: assign(socket, form: to_form(cs, as: :sale))

  @impl true
  def handle_event("validate", %{"sale" => attrs}, socket) do
    {:noreply,
     assign_form(
       socket,
       socket.assigns.sale |> Catalogue.change_sale(to_utc(attrs)) |> Map.put(:action, :validate)
     )}
  end

  def handle_event("save", %{"sale" => attrs}, socket) do
    attrs = to_utc(attrs)

    result =
      case socket.assigns.live_action do
        :new -> Catalogue.create_draft(attrs, socket.assigns.current_user)
        :edit -> Catalogue.update_draft(socket.assigns.sale, attrs)
      end

    case result do
      {:ok, sale} ->
        {:noreply,
         socket
         |> put_flash(:info, "Draft saved.")
         |> push_navigate(to: ~p"/desk/sales/#{sale.number}")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign_form(socket, cs)}

      {:error, :published} ->
        {:noreply, put_flash(socket, :error, "A published sale cannot be changed here.")}
    end
  end

  def handle_event(
        "add-lot",
        %{"lot" => %{"work_id" => wid, "low" => low, "high" => high}},
        socket
      ) do
    with {wid, ""} <- Integer.parse(wid),
         {low, ""} <- Integer.parse(String.replace(low, ~r/[,\s]/, "")),
         {high, ""} <- Integer.parse(String.replace(high, ~r/[,\s]/, "")),
         {:ok, _} <- Catalogue.add_lot(socket.assigns.sale, wid, low, high) do
      {:noreply,
       assign(socket,
         lots: Catalogue.sale_lots(socket.assigns.sale),
         lot_error: nil,
         lot_form: to_form(%{"work_id" => "", "low" => "", "high" => ""}, as: :lot)
       )}
    else
      {:error, :published} ->
        {:noreply, assign(socket, lot_error: "Lots cannot be added to a published sale.")}

      _ ->
        {:noreply,
         assign(socket,
           lot_error:
             "Choose a work, and give a low and a high estimate in shillings, the high at least the low."
         )}
    end
  end

  def handle_event("remove-lot", %{"id" => id}, socket) do
    {id, ""} = Integer.parse(id)
    Catalogue.remove_lot(socket.assigns.sale, id)
    {:noreply, assign(socket, lots: Catalogue.sale_lots(socket.assigns.sale))}
  end

  def handle_event("publish", _params, socket) do
    case Catalogue.publish(socket.assigns.sale, socket.assigns.current_user) do
      {:ok, sale} ->
        {:noreply,
         socket
         |> assign(sale: sale)
         |> put_flash(:info, "Sale #{sale.number} is on the website.")}

      {:error, :not_head} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Only the head of sale can publish. Your draft is saved for them."
         )}

      {:error, :no_lots} ->
        {:noreply, put_flash(socket, :error, "Add at least one lot before publishing.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "This sale is already published.")}
    end
  end

  # The form shows East Africa Time; the database keeps UTC.
  defp to_utc(attrs) do
    Enum.reduce(~w(opens_at first_close_at starts_at), attrs, fn key, acc ->
      case acc[key] do
        v when is_binary(v) and v != "" ->
          case NaiveDateTime.from_iso8601(if(String.length(v) == 16, do: v <> ":00", else: v)) do
            {:ok, n} ->
              Map.put(
                acc,
                key,
                n |> DateTime.from_naive!("Etc/UTC") |> DateTime.add(-3 * 3600, :second)
              )

            _ ->
              acc
          end

        _ ->
          acc
      end
    end)
  end

  defp eat_input(nil), do: nil

  defp eat_input(%DateTime{} = dt),
    do:
      dt
      |> DateTime.add(3 * 3600, :second)
      |> DateTime.to_naive()
      |> NaiveDateTime.truncate(:second)
      |> NaiveDateTime.to_iso8601()
      |> String.slice(0, 16)

  defp eat_input(other), do: other

  defp editable?(sale), do: sale.status == "draft" or is_nil(sale.id)

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        editable: editable?(assigns.sale),
        head: User.role?(assigns.current_user, "head_of_sale")
      )

    ~H"""
    <Layouts.desk flash={@flash} current_user={@current_user} active={:sales}>
      <header class="desk-head">
        <div>
          <p class="label">
            <a href={~p"/desk/sales"}>Sales</a>
            · {if @sale.id, do: "Sale #{@sale.number}", else: "New"}
          </p>
          <h1>{@sale.title || "New sale"}</h1>
        </div>
        <div class="desk-row-actions">
          <a :if={@sale.published} class="btn ghost" href={Sale.path(@sale)} target="_blank">On the website</a>
          <a
            :if={@sale.id && Sale.live?(@sale) && @sale.status in ["upcoming", "live"]}
            class="btn"
            href={~p"/desk/rostrum/#{@sale.number}"}
          >Rostrum</a>
          <button
            :if={@sale.status == "draft"}
            class="btn"
            phx-click="publish"
            disabled={@lots == []}
            title={!@head && "Needs the head of sale"}
          >
            {if @head, do: "Publish", else: "Publish (head of sale)"}
          </button>
        </div>
      </header>

      <p :if={!@editable} class="desk-note">
        This sale is {if @sale.template,
          do: "one of the house's running sales and is",
          else: "published and"} shown here as it stands. Reserves are confidential to staff.
      </p>

      <div class="desk-split">
        <.form
          :if={@editable}
          for={@form}
          id="sale-form"
          phx-change="validate"
          phx-submit="save"
          class="desk-card"
        >
          <h2 class="desk-card-title">Details</h2>
          <.input field={@form[:title]} label="Title" required />
          <div class="field-pair">
            <.input
              field={@form[:format]}
              type="select"
              label="Format"
              options={[{"Online, closing lot by lot", "timed"}, {"Live, from the rostrum", "live"}]}
            />
            <.input
              field={@form[:category]}
              type="select"
              label="Category"
              options={["Art", "Works on paper", "Design"]}
            />
          </div>
          <.input field={@form[:summary]} label="Summary" hint="One line for sale lists." required />
          <.input field={@form[:description]} type="textarea" label="Description" rows="4" required />
          <%= if Phoenix.HTML.Form.input_value(@form, :format) == "live" do %>
            <.input
              field={@form[:starts_at]}
              type="datetime-local"
              label="Starts (East Africa Time)"
              value={eat_input(Phoenix.HTML.Form.input_value(@form, :starts_at))}
            />
          <% else %>
            <div class="field-pair">
              <.input
                field={@form[:opens_at]}
                type="datetime-local"
                label="Bidding opens (EAT)"
                value={eat_input(Phoenix.HTML.Form.input_value(@form, :opens_at))}
              />
              <.input
                field={@form[:first_close_at]}
                type="datetime-local"
                label="First lot closes (EAT)"
                value={eat_input(Phoenix.HTML.Form.input_value(@form, :first_close_at))}
              />
            </div>
            <.input
              field={@form[:lot_interval]}
              type="number"
              label="Seconds between lots closing"
              min="30"
              max="3600"
            />
          <% end %>
          <button type="submit" class="btn">{if @sale.id, do: "Save draft", else: "Create draft"}</button>
        </.form>

        <section :if={@sale.id} class="desk-card" aria-labelledby="lots-title">
          <h2 id="lots-title" class="desk-card-title">Lots · {length(@lots)}</h2>
          <p :if={@lots == []} class="muted">No lots yet.</p>
          <div :if={@lots != []} class="table-scroll">
            <table class="table">
              <thead>
                <tr>
                  <th class="num">Lot</th><th>Work</th><th class="num">Estimate</th><th class="num">
                    Reserve
                  </th><th class="num">Bid</th><th>Status</th><th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={l <- @lots}>
                  <td class="num serif">{l.number}</td>
                  <td>
                    <em class="serif">{l.work.title}</em><br /><span class="muted">{l.work.artist.name}</span>
                  </td>
                  <td class="num">
                    {Format.short_money(l.estimate_low)}–{Format.short_money(l.estimate_high)
                    |> String.replace("KES ", "")}
                  </td>
                  <td class="num">{Format.short_money(l.reserve)}</td>
                  <td class="num">
                    {(l.hammer || l.current_bid) && Format.short_money(l.hammer || l.current_bid)}
                  </td>
                  <td>
                    {l.status}{if l.status == "open" and Lot.reserve_met?(l), do: " · reserve met"}
                  </td>
                  <td>
                    <button
                      :if={@editable}
                      class="btn ghost small"
                      phx-click="remove-lot"
                      phx-value-id={l.id}
                    >Remove</button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <.form
            :if={@editable}
            for={@lot_form}
            phx-submit="add-lot"
            id="add-lot-form"
            class="add-lot"
          >
            <h3 class="label">Add a lot from the archive</h3>
            <.input
              field={@lot_form[:work_id]}
              type="select"
              label="Work"
              prompt="Choose a work"
              options={Enum.map(@works, &{"#{&1.artist.name}: #{&1.title}, #{&1.year}", &1.id})}
            />
            <div class="field-pair">
              <.input
                field={@lot_form[:low]}
                label="Low estimate (KES)"
                inputmode="numeric"
                placeholder="200000"
              />
              <.input
                field={@lot_form[:high]}
                label="High estimate (KES)"
                inputmode="numeric"
                placeholder="300000"
              />
            </div>
            <p :if={@lot_error} class="error-text">{@lot_error}</p>
            <p class="hint">
              The reserve is set a little under the low estimate and the opening bid at about half of it.
            </p>
            <button type="submit" class="btn ghost">Add lot</button>
          </.form>
        </section>
      </div>
    </Layouts.desk>
    """
  end
end
