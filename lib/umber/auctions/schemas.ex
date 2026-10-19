defmodule Umber.Auctions.Bid do
  use Umber.Schema

  schema "bids" do
    field :amount, :integer
    # bid: one tap at the asking price; proxy: placed for a bidder by their
    # maximum; floor: taken by the auctioneer in the room; absentee: from the book.
    field :kind, :string
    field :source, :string
    belongs_to :lot, Umber.Catalogue.Lot
    belongs_to :user, Umber.Accounts.User
    timestamps(updated_at: false)
  end
end

defmodule Umber.Auctions.MaxBid do
  use Umber.Schema

  schema "max_bids" do
    field :amount, :integer
    belongs_to :lot, Umber.Catalogue.Lot
    belongs_to :user, Umber.Accounts.User
    timestamps()
  end
end

defmodule Umber.Auctions.Invoice do
  use Umber.Schema

  @premium_rate 20
  @vat_rate 16

  schema "invoices" do
    field :number, :string
    field :hammer, :integer
    field :premium, :integer
    field :vat, :integer
    field :total, :integer
    field :status, :string, default: "due"
    field :paid_at, :utc_datetime_usec
    belongs_to :lot, Umber.Catalogue.Lot
    belongs_to :user, Umber.Accounts.User
    belongs_to :paid_by, Umber.Accounts.User
    timestamps()
  end

  def premium_rate, do: @premium_rate
  def vat_rate, do: @vat_rate

  @doc "Buyer's premium on the hammer price, and VAT on the premium only."
  def amounts(hammer) when is_integer(hammer) do
    premium = div(hammer * @premium_rate, 100)
    vat = div(premium * @vat_rate, 100)
    %{hammer: hammer, premium: premium, vat: vat, total: hammer + premium + vat}
  end
end

defmodule Umber.Auctions.LiveSession do
  use Umber.Schema

  @primary_key {:sale_id, :id, autogenerate: false}
  @states ~w(waiting open warning sold passed paused ended)

  schema "live_sessions" do
    field :state, :string, default: "waiting"
    field :asking, :integer
    field :current_bid, :integer
    field :leader_source, :string
    field :call, :string
    field :called_at, :utc_datetime_usec
    field :auctioneer_seen_at, :utc_datetime_usec
    field :version, :integer, default: 0
    belongs_to :sale, Umber.Catalogue.Sale, define_field: false
    belongs_to :lot, Umber.Catalogue.Lot
    belongs_to :leader, Umber.Accounts.User
    belongs_to :auctioneer, Umber.Accounts.User
    timestamps()
  end

  def states, do: @states
  def taking_bids?(%__MODULE__{state: s}), do: s in ~w(open warning)
end
