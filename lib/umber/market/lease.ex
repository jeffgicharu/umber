defmodule Umber.Market.Lease do
  @moduledoc """
  Decides which running copy of the app runs the market: the schedule, the
  sample bidders and the automatic auctioneers. Bids are taken by every copy.

  The holder renews a row in `leases` every few seconds. A new release started
  beside the live one cannot take it until the old one lets go, which it does
  as it shuts down, so the market moves across within seconds of a switch.
  """

  use GenServer
  require Logger
  alias Umber.Repo

  @name "market"
  @renew_every 3_000
  @valid_for 10

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def held?, do: GenServer.call(__MODULE__, :held?)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    holder =
      "#{Application.get_env(:umber, :release, "dev")}:#{System.get_env("PORT", "4000")}:#{Base.encode16(:crypto.strong_rand_bytes(3))}"

    send(self(), :renew)
    {:ok, %{holder: holder, held: false, runner: nil}}
  end

  @impl true
  def handle_call(:held?, _from, state), do: {:reply, state.held, state}

  @impl true
  def handle_info(:renew, state) do
    Process.send_after(self(), :renew, @renew_every)
    {:noreply, state |> renew() |> run()}
  end

  def handle_info({:EXIT, pid, reason}, %{runner: pid} = state) do
    Logger.warning("market stopped: #{inspect(reason)}; restarting while the lease is held")
    {:noreply, run(%{state | runner: nil})}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.runner, do: Supervisor.stop(state.runner, :shutdown, 15_000)

    Repo.query("DELETE FROM leases WHERE name = $1 AND holder = $2", [@name, state.holder])
    :ok
  end

  defp renew(state) do
    sql = """
    INSERT INTO leases (name, holder, expires_at) VALUES ($1, $2, now() + make_interval(secs => $3))
    ON CONFLICT (name) DO UPDATE SET holder = EXCLUDED.holder, expires_at = EXCLUDED.expires_at
    WHERE leases.holder = EXCLUDED.holder OR leases.expires_at < now()
    RETURNING holder
    """

    case Repo.query(sql, [@name, state.holder, @valid_for]) do
      {:ok, %{num_rows: 1}} ->
        unless state.held, do: Logger.info("market lease taken by #{state.holder}")
        %{state | held: true}

      {:ok, _} ->
        %{state | held: false}

      {:error, error} ->
        Logger.warning("market lease not renewed: #{inspect(error)}")
        %{state | held: false}
    end
  end

  defp run(%{held: true, runner: nil} = state) do
    {:ok, pid} =
      Supervisor.start_link(Umber.Market.Supervisor.children(),
        strategy: :one_for_one,
        max_restarts: 20,
        max_seconds: 60
      )

    %{state | runner: pid}
  end

  defp run(%{held: false, runner: pid} = state) when is_pid(pid) do
    Logger.warning("market lease lost; stopping the market here")
    Supervisor.stop(pid, :shutdown, 15_000)
    %{state | runner: nil}
  end

  defp run(state), do: state
end

defmodule Umber.Market.Supervisor do
  @moduledoc false

  def children do
    [
      {Registry, keys: :unique, name: Umber.Market.AuctioneerRegistry},
      {DynamicSupervisor, name: Umber.Market.AuctioneerSupervisor, strategy: :one_for_one},
      Umber.Market.Scheduler,
      Umber.Market.SampleBidders
    ]
  end
end
