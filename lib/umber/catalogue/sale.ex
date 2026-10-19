defmodule Umber.Catalogue.Sale do
  use Umber.Schema
  import Ecto.Changeset

  @formats ~w(live timed)
  # upcoming: catalogue published, bidding not open (live sales take absentee bids)
  # open: timed sale taking bids; live: the auctioneer is selling; closed: finished
  @statuses ~w(draft upcoming open live closed)

  schema "sales" do
    field :number, :integer
    field :template, :string
    field :title, :string
    field :format, :string
    field :category, :string
    field :summary, :string
    field :description, :string
    field :status, :string
    field :published, :boolean, default: true
    field :opens_at, :utc_datetime_usec
    field :first_close_at, :utc_datetime_usec
    field :lot_interval, :integer
    field :starts_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec

    belongs_to :created_by, Umber.Accounts.User
    has_many :lots, Umber.Catalogue.Lot
    timestamps()
  end

  def formats, do: @formats
  def statuses, do: @statuses

  def live?(%__MODULE__{format: f}), do: f == "live"
  def timed?(%__MODULE__{format: f}), do: f == "timed"

  @doc "The address of a sale: /sales/3141."
  def path(%__MODULE__{number: n}), do: "/sales/#{n}"

  @doc "Staff edit of a sale's details."
  def changeset(sale, attrs) do
    sale
    |> cast(attrs, [:title, :format, :category, :summary, :description, :opens_at, :first_close_at, :lot_interval, :starts_at])
    |> validate_required([:title, :format, :category, :summary, :description])
    |> validate_inclusion(:format, @formats)
    |> validate_length(:title, max: 120)
    |> validate_length(:summary, max: 280)
    |> validate_length(:description, max: 2000)
    |> validate_number(:lot_interval, greater_than_or_equal_to: 30, less_than_or_equal_to: 3600)
    |> validate_schedule()
  end

  defp validate_schedule(cs) do
    case get_field(cs, :format) do
      "timed" ->
        cs
        |> validate_required([:opens_at, :first_close_at, :lot_interval])
        |> validate_after(:first_close_at, :opens_at)

      "live" ->
        validate_required(cs, [:starts_at])

      _ ->
        cs
    end
  end

  defp validate_after(cs, later, earlier) do
    with %DateTime{} = l <- get_field(cs, later),
         %DateTime{} = e <- get_field(cs, earlier),
         :gt <- DateTime.compare(l, e) do
      cs
    else
      nil -> cs
      _ -> add_error(cs, later, "must be after the time bidding opens")
    end
  end
end
