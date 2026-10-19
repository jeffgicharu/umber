defmodule Umber.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        UmberWeb.Telemetry,
        Umber.MemoryWatch,
        Umber.Repo,
        {Phoenix.PubSub, name: Umber.PubSub},
        Umber.Events.Listener,
        {Registry, keys: :unique, name: Umber.Auctions.LotRegistry},
        {DynamicSupervisor, name: Umber.Auctions.LotSupervisor, strategy: :one_for_one},
        {Oban, Application.fetch_env!(:umber, Oban)},
        UmberWeb.Presence,
        UmberWeb.Endpoint
      ] ++ market()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Umber.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The market starts last, after the endpoint, and so stops first: it hands
  # its lease back before the copy stops serving.
  defp market do
    if Application.get_env(:umber, :start_market, true) do
      [
        {Registry, keys: :unique, name: Umber.Market.AuctioneerRegistry},
        {DynamicSupervisor, name: Umber.Market.AuctioneerSupervisor, strategy: :one_for_one},
        Umber.Market.Scheduler,
        Umber.Market.SampleBidders,
        # Last, so it stops first: the lease is handed back before the market's processes go.
        Umber.Market.Lease
      ]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    UmberWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
