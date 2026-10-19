defmodule Umber.Catalogue.Lot do
  use Umber.Schema

  @statuses ~w(pending open sold unsold withdrawn)

  schema "lots" do
    field :number, :integer
    field :estimate_low, :integer
    field :estimate_high, :integer
    field :reserve, :integer
    field :opening_bid, :integer
    field :status, :string, default: "pending"
    field :current_bid, :integer
    field :bid_count, :integer, default: 0
    field :closes_at, :utc_datetime_usec
    field :extensions, :integer, default: 0
    field :hammer, :integer
    field :closed_at, :utc_datetime_usec
    field :market_value, :integer
    field :version, :integer, default: 0

    belongs_to :sale, Umber.Catalogue.Sale
    belongs_to :work, Umber.Catalogue.Work
    belongs_to :leader, Umber.Accounts.User
    belongs_to :buyer, Umber.Accounts.User
    timestamps()
  end

  def statuses, do: @statuses

  def finished?(%__MODULE__{status: s}), do: s in ~w(sold unsold withdrawn)
  def reserve_met?(%__MODULE__{current_bid: b, reserve: r}), do: is_integer(b) and b >= r

  @doc "The address of a lot: /sales/3141/lots/8."
  def path(%__MODULE__{number: n, sale: %{number: s}}), do: "/sales/#{s}/lots/#{n}"
end
