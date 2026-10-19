defmodule Umber.Market.Lease do
  @moduledoc """
  Decides which running copy of the app runs the market: the schedule, the
  sample bidders and the automatic auctioneers. Bids are taken by every copy.

  The holder renews a row in `leases` every few seconds. A new release started
  beside the live one cannot take it until the old one lets go, which it does
  as it shuts down, so the market moves across within seconds of a switch.

  This process only renews and says whether the lease is held; the market's
  processes run all the time and act only while it is. It also watches them:
  if the scheduler stops answering, it is killed and its supervisor starts it
  again, so the market can never stall silently behind a held lease.
  """

  use GenServer
  require Logger
  alias Umber.Repo

  @name "market"
  @renew_every 3_000
  @valid_for 10
  @flag {__MODULE__, :held}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Whether this copy runs the market now. Cheap: read on every market tick."
  def held?, do: :persistent_term.get(@flag, false)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    put_held(false)

    holder =
      "#{Application.get_env(:umber, :release, "dev")}:#{System.get_env("PORT", "4000")}:#{Base.encode16(:crypto.strong_rand_bytes(3))}"

    send(self(), :renew)
    {:ok, %{holder: holder, held: false}}
  end

  @impl true
  def handle_info(:renew, state) do
    Process.send_after(self(), :renew, @renew_every)
    state = renew(state)
    if state.held, do: watch_scheduler()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    put_held(false)

    Repo.query("DELETE FROM leases WHERE name = $1 AND holder = $2", [@name, state.holder],
      timeout: 5_000
    )

    :ok
  end

  defp renew(state) do
    sql = """
    INSERT INTO leases (name, holder, expires_at) VALUES ($1, $2, now() + make_interval(secs => $3))
    ON CONFLICT (name) DO UPDATE SET holder = EXCLUDED.holder, expires_at = EXCLUDED.expires_at
    WHERE leases.holder = EXCLUDED.holder OR leases.expires_at < now()
    RETURNING holder
    """

    held =
      case Repo.query(sql, [@name, state.holder, @valid_for], timeout: 5_000) do
        {:ok, %{num_rows: 1}} -> true
        {:ok, _} -> false
        {:error, error} -> Logger.warning("market lease not renewed: #{inspect(error)}") && false
      end

    cond do
      held and not state.held -> Logger.info("market lease taken by #{state.holder}")
      state.held and not held -> Logger.warning("market lease lost by #{state.holder}")
      true -> :ok
    end

    put_held(held)
    %{state | held: held}
  rescue
    e ->
      Logger.warning("market lease not renewed: #{Exception.message(e)}")
      put_held(false)
      %{state | held: false}
  end

  defp put_held(value) do
    if :persistent_term.get(@flag, nil) != value, do: :persistent_term.put(@flag, value)
  end

  # The scheduler answers within a second with how long ago it last ticked.
  defp watch_scheduler do
    case Process.whereis(Umber.Market.Scheduler) do
      nil ->
        :ok

      pid ->
        stale =
          try do
            GenServer.call(pid, :last_tick_age, 1_000) > 20_000
          catch
            :exit, _ -> true
          end

        if stale do
          Logger.error("market scheduler stopped ticking; restarting it")
          Process.exit(pid, :kill)
        end
    end
  end
end
