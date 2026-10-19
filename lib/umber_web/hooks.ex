defmodule UmberWeb.Hooks do
  @moduledoc """
  Shared by every public page:

    * personal notices (outbid, won, closing soon) for the signed-in bidder,
      shown on whatever page they have open;
    * the header's live marker, which lights up while a live sale is selling.
  """

  import Phoenix.Component
  import Phoenix.LiveView
  import Ecto.Query, only: [from: 2]

  alias Umber.{Repo, Events}
  alias Umber.Catalogue.Sale

  @notice_ttl 12_000

  def on_mount(:default, _params, _session, socket) do
    user = socket.assigns[:current_user]

    if connected?(socket) do
      Events.subscribe("market")
      if user, do: Events.subscribe("user:#{user.id}")
    end

    socket =
      socket
      |> assign(notices: [], live_now: live_now(), page_class: nil)
      |> attach_hook(:notices, :handle_info, &handle_info/2)
      |> attach_hook(:notice_events, :handle_event, &handle_event/3)

    {:cont, socket}
  end

  defp handle_info({:notice, notice}, socket) do
    Process.send_after(self(), {:expire_notice, notice.id}, @notice_ttl)
    {:halt, update(socket, :notices, &Enum.take([notice | &1], 3))}
  end

  defp handle_info({:expire_notice, id}, socket) do
    {:halt, update(socket, :notices, &Enum.reject(&1, fn n -> n.id == id end))}
  end

  defp handle_info(:sales_changed, socket) do
    # Pages that care about the market also handle it themselves.
    {:cont, assign(socket, :live_now, live_now())}
  end

  defp handle_info(_msg, socket), do: {:cont, socket}

  defp handle_event("dismiss-notice", %{"id" => id}, socket) do
    {id, ""} = Integer.parse(id)
    {:halt, update(socket, :notices, &Enum.reject(&1, fn n -> n.id == id end))}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  @doc "The live sale selling right now, if any."
  def live_now do
    from(s in Sale,
      where: s.format == "live" and s.status == "live" and s.published,
      order_by: [desc: s.starts_at],
      limit: 1
    )
    |> Repo.one()
  end
end
