defmodule Umber.Desk.LimitRequest do
  use Umber.Schema
  import Ecto.Changeset

  schema "limit_requests" do
    field :amount, :integer
    field :reason, :string
    field :status, :string, default: "pending"
    field :decided_at, :utc_datetime_usec
    belongs_to :user, Umber.Accounts.User
    belongs_to :decided_by, Umber.Accounts.User
    timestamps()
  end

  @amounts [3_000_000, 5_000_000, 10_000_000, 20_000_000]
  def amounts, do: @amounts

  def changeset(req, attrs, current_limit) do
    req
    |> cast(attrs, [:amount, :reason])
    |> validate_required([:amount], message: "Choose the limit you would like")
    |> validate_inclusion(:amount, @amounts, message: "Choose one of the limits offered")
    |> validate_number(:amount,
      greater_than: current_limit,
      message: "Choose a limit above your current one"
    )
    |> validate_length(:reason, max: 500, message: "Keep it under 500 characters")
  end
end

defmodule Umber.Desk.Consignment do
  use Umber.Schema
  import Ecto.Changeset

  @statuses ~w(new reviewing invited declined)

  schema "consignments" do
    field :name, :string
    field :email, :string
    field :phone, :string
    field :artist_name, :string
    field :title, :string
    field :medium, :string
    field :dimensions, :string
    field :description, :string
    field :acquired, :string
    field :photos, {:array, :string}, default: []
    field :status, :string, default: "new"
    field :staff_note, :string
    belongs_to :user, Umber.Accounts.User
    timestamps()
  end

  def statuses, do: @statuses

  def changeset(c, attrs) do
    c
    |> cast(attrs, [
      :name,
      :email,
      :phone,
      :artist_name,
      :title,
      :medium,
      :dimensions,
      :description,
      :acquired
    ])
    |> validate_required([:name], message: "Enter your name")
    |> validate_required([:email], message: "Enter an email so we can find your enquiry")
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+\.[^@,;\s]+$/,
      message: "Enter an email address like name@example.com"
    )
    |> validate_required([:artist_name],
      message: "Tell us the artist or maker, or write \"unknown\""
    )
    |> validate_required([:description], message: "Tell us a little about the work")
    |> validate_length(:description,
      min: 20,
      max: 2000,
      message: "Write at least a sentence or two, and under 2,000 characters"
    )
    |> validate_length(:name, max: 80)
    |> validate_length(:artist_name, max: 120)
    |> validate_length(:title, max: 160)
    |> validate_length(:medium, max: 120)
    |> validate_length(:dimensions, max: 80)
    |> validate_length(:acquired, max: 500)
    |> validate_format(:phone, ~r/^\+?[0-9 ()-]{7,20}$/,
      message: "Enter a phone number like +254 712 345 678"
    )
  end

  def review_changeset(c, attrs) do
    c
    |> cast(attrs, [:status, :staff_note])
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:staff_note, max: 1000)
  end
end

defmodule Umber.Desk do
  @moduledoc "What client services and the specialists handle: limits and consignments."

  import Ecto.Query
  alias Umber.{Repo, Events, Accounts}
  alias Umber.Accounts.User
  alias Umber.Desk.{LimitRequest, Consignment}

  ## Bidding limits

  def change_limit_request(%User{} = user, attrs \\ %{}),
    do: LimitRequest.changeset(%LimitRequest{}, attrs, user.bid_limit)

  def pending_limit_request(%User{id: uid}) do
    Repo.one(from r in LimitRequest, where: r.user_id == ^uid and r.status == "pending", limit: 1)
  end

  def limit_requests(%User{id: uid}) do
    from(r in LimitRequest, where: r.user_id == ^uid, order_by: [desc: r.inserted_at], limit: 10)
    |> Repo.all()
  end

  def request_limit(%User{} = user, attrs) do
    if pending_limit_request(user) do
      {:error, :already_pending}
    else
      result =
        %LimitRequest{user_id: user.id}
        |> LimitRequest.changeset(attrs, user.bid_limit)
        |> Repo.insert()

      with {:ok, _} <- result, do: Events.broadcast("desk", :limit_requested)
      result
    end
  end

  def list_pending_limits do
    from(r in LimitRequest, where: r.status == "pending", order_by: r.inserted_at, preload: :user)
    |> Repo.all()
  end

  def decide_limit(%LimitRequest{status: "pending"} = req, %User{} = staff, decision)
      when decision in ["approved", "declined"] do
    if User.role?(staff, "client_services") do
      Repo.transaction(fn ->
        {:ok, req} =
          req
          |> Ecto.Changeset.change(
            status: decision,
            decided_by_id: staff.id,
            decided_at: DateTime.utc_now()
          )
          |> Repo.update()

        if decision == "approved" do
          {:ok, _} = req.user_id |> Accounts.get_user!() |> Accounts.set_bid_limit(req.amount)
        end

        req
      end)
      |> tap(fn
        {:ok, req} ->
          Events.broadcast("user:#{req.user_id}", {:limit_decided, decision, req.amount})

        _ ->
          :ok
      end)
    else
      {:error, :not_allowed}
    end
  end

  def decide_limit(_, _, _), do: {:error, :already_decided}

  def get_limit_request!(id), do: Repo.get!(LimitRequest, id) |> Repo.preload(:user)

  ## Consignments

  def change_consignment(attrs \\ %{}), do: Consignment.changeset(%Consignment{}, attrs)

  def submit_consignment(attrs, photos, user) do
    %Consignment{user_id: user && user.id, photos: photos}
    |> Consignment.changeset(attrs)
    |> Repo.insert()
    |> tap(fn
      {:ok, _} -> Events.broadcast("desk", :consignment_received)
      _ -> :ok
    end)
  end

  def user_consignments(%User{id: uid}) do
    from(c in Consignment, where: c.user_id == ^uid, order_by: [desc: c.inserted_at])
    |> Repo.all()
  end

  def list_consignments(status \\ nil) do
    from(c in Consignment, order_by: [desc: c.inserted_at], limit: 100)
    |> then(fn q -> if status, do: where(q, [c], c.status == ^status), else: q end)
    |> Repo.all()
  end

  def get_consignment!(id), do: Repo.get!(Consignment, id)

  def review_consignment(%Consignment{} = c, %User{} = staff, attrs) do
    if User.role?(staff, "specialist") or User.role?(staff, "client_services") do
      c |> Consignment.review_changeset(attrs) |> Repo.update()
    else
      {:error, :not_allowed}
    end
  end

  def counts do
    %{
      limits: Repo.aggregate(from(r in LimitRequest, where: r.status == "pending"), :count),
      consignments: Repo.aggregate(from(c in Consignment, where: c.status == "new"), :count)
    }
  end
end
