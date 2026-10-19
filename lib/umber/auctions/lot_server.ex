defmodule Umber.Auctions.LotServer do
  @moduledoc """
  One process per open timed lot. Bids for the lot that reach this copy of the
  app queue here and are decided one at a time; the process also holds the
  lot's closing timer and moves it when a late bid extends the close.

  The process keeps nothing that is not in the database. If it crashes, its
  supervisor starts it again and it reads the lot back, and because a bid is
  only acknowledged after it is committed, no accepted bid is ever lost.
  """

  use GenServer, restart: :transient

  alias Umber.Repo
  alias Umber.Catalogue.Lot
  alias Umber.Auctions.{Timed, Broadcasts}

  @registry Umber.Auctions.LotRegistry
  @supervisor Umber.Auctions.LotSupervisor

  def start_link(lot_id), do: GenServer.start_link(__MODULE__, lot_id, name: via(lot_id))

  defp via(lot_id), do: {:via, Registry, {@registry, lot_id}}

  @doc "The process for a lot, started if it is not running."
  def ensure(lot_id) do
    case Registry.lookup(@registry, lot_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(@supervisor, {__MODULE__, lot_id}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          :ignore -> {:error, :closed}
          other -> other
        end
    end
  end

  def running?(lot_id), do: Registry.lookup(@registry, lot_id) != []

  @doc "Places a bid through the lot's process."
  def bid(lot_id, user, kind, amount) do
    with {:ok, pid} <- ensure(lot_id) do
      GenServer.call(pid, {:bid, user, kind, amount}, 10_000)
    end
  catch
    # The lot closed and its process stopped between the lookup and the call.
    :exit, {:noproc, _} -> {:error, :closed}
    :exit, {:normal, _} -> {:error, :closed}
  end

  ## Server

  @impl true
  def init(lot_id) do
    case Repo.get(Lot, lot_id) do
      %Lot{status: "open"} = lot ->
        Umber.Events.subscribe("lot:#{lot_id}")
        {:ok, schedule(%{lot_id: lot_id, closes_at: lot.closes_at, timer: nil})}

      _ ->
        :ignore
    end
  end

  @impl true
  def handle_call({:bid, user, kind, amount}, _from, state) do
    case Timed.place(state.lot_id, user, kind, amount) do
      {:ok, change} ->
        Broadcasts.timed_bid(change)
        {:reply, {:ok, change}, schedule(%{state | closes_at: change.lot.closes_at})}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_info(:close, state) do
    case Timed.close(state.lot_id) do
      {:ok, :already_closed} ->
        {:stop, :normal, state}

      {:ok, change} ->
        Broadcasts.timed_close(change)
        {:stop, :normal, state}

      # Extended in the meantime by the other copy of the app; read the new time.
      {:error, :not_due} ->
        lot = Repo.get!(Lot, state.lot_id)
        {:noreply, schedule(%{state | closes_at: lot.closes_at})}
    end
  end

  # Another copy accepted a bid that moved the close.
  def handle_info({:lot, %{id: id, status: "open", closes_at: closes}}, %{lot_id: id} = state) do
    if DateTime.compare(closes, state.closes_at) == :gt,
      do: {:noreply, schedule(%{state | closes_at: closes})},
      else: {:noreply, state}
  end

  def handle_info({:lot, %{id: id, status: status}}, %{lot_id: id} = state) when status != "open" do
    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule(%{timer: timer, closes_at: closes} = state) do
    if timer, do: Process.cancel_timer(timer)
    ms = max(DateTime.diff(closes, DateTime.utc_now(), :millisecond), 0)
    %{state | timer: Process.send_after(self(), :close, ms)}
  end
end
