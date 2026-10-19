defmodule UmberWeb.SellLive do
  use UmberWeb, :live_view

  alias Umber.Desk
  alias UmberWeb.{Meta, RateLimit}

  @max_photos 4

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    prefill =
      if user, do: %{"name" => user.name, "email" => user.email, "phone" => user.phone}, else: %{}

    {:ok,
     socket
     |> assign(form: to_form(Desk.change_consignment(prefill), as: :consignment), sent: nil)
     |> allow_upload(:photos,
       accept: ~w(.jpg .jpeg),
       max_entries: @max_photos,
       # Photos are resized in the browser to 1600 px before they are sent.
       max_file_size: 2_500_000
     )
     |> Meta.put(
       title: "Sell with us",
       description:
         "Ask Umber's specialists for a free valuation of a painting, sculpture or piece of design you would like to sell at auction.",
       path: "/sell",
       image: "/images/photos/photo-valuation-1600.jpg"
     )}
  end

  @impl true
  def handle_event("validate", %{"consignment" => attrs}, socket) do
    form =
      attrs
      |> Desk.change_consignment()
      |> Map.put(:action, :validate)
      |> to_form(as: :consignment)

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("cancel-photo", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :photos, ref)}

  def handle_event("save", %{"consignment" => attrs}, socket) do
    key = {:consign, (socket.assigns.current_user && socket.assigns.current_user.id) || socket.id}

    with :ok <- RateLimit.check(key, 3, 3600),
         %Ecto.Changeset{valid?: true} <- Desk.change_consignment(attrs) do
      photos =
        consume_uploaded_entries(socket, :photos, fn %{path: path}, entry ->
          name = "#{Ecto.UUID.generate()}#{ext(entry.client_type)}"
          dest = Path.join(uploads_dir(), name)
          File.mkdir_p!(uploads_dir())
          File.cp!(path, dest)
          {:ok, name}
        end)

      {:ok, c} = Desk.submit_consignment(attrs, photos, socket.assigns.current_user)

      {:noreply,
       assign(socket, sent: c, form: to_form(Desk.change_consignment(), as: :consignment))}
    else
      {:error, :rate_limited} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "You have sent several enquiries already. A specialist will be in touch about those first."
         )}

      %Ecto.Changeset{} = cs ->
        {:noreply, assign(socket, form: to_form(Map.put(cs, :action, :insert), as: :consignment))}
    end
  end

  def handle_event("again", _params, socket), do: {:noreply, assign(socket, sent: nil)}

  defp ext("image/webp"), do: ".webp"
  defp ext(_), do: ".jpg"

  def uploads_dir,
    do: Application.get_env(:umber, :uploads_dir) || Path.expand("tmp/uploads", File.cwd!())

  defp upload_error(:too_large),
    do: "That photo is too large even after shrinking. Try a smaller one."

  defp upload_error(:not_accepted), do: "Send photos as JPEG or WebP."
  defp upload_error(:too_many_files), do: "Send at most #{@max_photos} photos."
  defp upload_error(_), do: "That photo could not be added."

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      live_now={@live_now}
      notices={@notices}
      active={:sell}
    >
      <header class="page-head wrap">
        <p class="label">Selling</p>
        <h1>Sell with us</h1>
        <p class="page-lede">
          Send us photographs and what you know of the work. A specialist will look at it, tell you what it might fetch at auction and which sale would suit it. There is no charge for a valuation.
        </p>
      </header>

      <div class="wrap sell-grid">
        <aside class="sell-side">
          <.photo
            name="photo-valuation"
            alt="A specialist and a client look together at a small bronze head across a timber table."
            ratio="4 / 5"
          />
          <ol class="sell-steps">
            <li>
              <span class="serif num">1</span>
              Tell us about the work and send up to four photographs: the front, the back, any signature, and any damage.
            </li>
            <li>
              <span class="serif num">2</span>
              A specialist replies with an estimate and a sale, usually within a week. You will see their answer in your account.
            </li>
            <li>
              <span class="serif num">3</span>
              If you decide to sell, we agree the reserve and our commission with you before anything is catalogued.
            </li>
          </ol>
        </aside>

        <div class="sell-main">
          <%= if @sent do %>
            <div class="form-panel sent" role="status">
              <p class="label">Received</p>
              <h2>Thank you. Your enquiry is with our specialists.</h2>
              <p>
                We have the details of {@sent.artist_name}{if @sent.title, do: ", #{@sent.title}"}, with {Format.count(
                  length(@sent.photos),
                  "photograph",
                  "photographs"
                )}.
              </p>
              <p :if={@current_user}>
                You will see their answer under Purchases in <a href={~p"/account/purchases"}>your account</a>.
              </p>
              <p :if={!@current_user}>
                If you <a href={~p"/register"}>register</a>
                with the same email, you can follow it in your account.
              </p>
              <button type="button" class="btn ghost" phx-click="again">Send another work</button>
            </div>
          <% else %>
            <.form
              for={@form}
              id="consign-form"
              phx-change="validate"
              phx-submit="save"
              class="form-panel"
            >
              <h2 class="form-title">The work</h2>
              <.input
                field={@form[:artist_name]}
                label="Artist or maker"
                placeholder="Or write unknown"
                required
              />
              <.input field={@form[:title]} label="Title, if it has one" />
              <div class="field-pair">
                <.input
                  field={@form[:medium]}
                  label="Medium"
                  placeholder="Oil on canvas, bronze, teak…"
                />
                <.input field={@form[:dimensions]} label="Size" placeholder="Height × width in cm" />
              </div>
              <.input
                field={@form[:description]}
                type="textarea"
                label="About the work"
                rows="4"
                hint="What it shows, its condition, and anything written on the back."
                required
              />
              <.input
                field={@form[:acquired]}
                type="textarea"
                label="How you came to own it (optional)"
                rows="2"
              />

              <div class="field upload-field">
                <span class="legend">Photographs</span>
                <label class="upload-drop" for="photo-picker" id="photo-drop">
                  <span class="serif">Add photographs</span>
                  <span class="muted">Up to 4. We shrink them on your device before sending.</span>
                </label>
                <%!-- The visible picker shrinks each photo, then hands it to the upload below. --%>
                <input
                  type="file"
                  id="photo-picker"
                  class="sr-only"
                  accept="image/*"
                  multiple
                  phx-hook="ResizeUpload"
                  data-upload="photos"
                  data-max="1600"
                  data-drop="photo-drop"
                />
                <div class="sr-only" aria-hidden="true">
                  <.live_file_input upload={@uploads.photos} tabindex="-1" />
                </div>
                <ul :if={@uploads.photos.entries != []} class="upload-list">
                  <li :for={entry <- @uploads.photos.entries}>
                    <.live_img_preview entry={entry} class="upload-thumb" />
                    <span class="upload-name">{entry.client_name}</span>
                    <progress
                      value={entry.progress}
                      max="100"
                      aria-label={"Uploading #{entry.client_name}"}
                    >{entry.progress}%</progress>
                    <button
                      type="button"
                      phx-click="cancel-photo"
                      phx-value-ref={entry.ref}
                      aria-label={"Remove #{entry.client_name}"}
                    >×</button>
                    <p :for={err <- upload_errors(@uploads.photos, entry)} class="error-text">
                      {upload_error(err)}
                    </p>
                  </li>
                </ul>
                <p :for={err <- upload_errors(@uploads.photos)} class="error-text">
                  {upload_error(err)}
                </p>
              </div>

              <h2 class="form-title">You</h2>
              <.input field={@form[:name]} label="Your name" autocomplete="name" required />
              <div class="field-pair">
                <.input
                  field={@form[:email]}
                  type="email"
                  label="Email"
                  autocomplete="email"
                  required
                />
                <.input field={@form[:phone]} type="tel" label="Phone (optional)" autocomplete="tel" />
              </div>
              <button type="submit" class="btn block" phx-disable-with="Sending…">Send to a specialist
              <span class="arrow" aria-hidden="true">→</span></button>
            </.form>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
