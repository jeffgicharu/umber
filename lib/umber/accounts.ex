defmodule Umber.Accounts do
  @moduledoc "Bidders, staff and their sessions."

  import Ecto.Query
  alias Umber.Repo
  alias Umber.Accounts.{User, UserToken}

  @default_limit 1_500_000
  # Visitor paddles are four digits; sample bidders and staff have their own ranges.
  @paddles %{"bidder" => 1000..8999, "staff" => 9000..9899, "sample" => 100..499}

  def default_limit, do: @default_limit

  def get_user!(id), do: Repo.get!(User, id)
  def get_user(id), do: Repo.get(User, id)

  def get_user_by_email_and_password(email, password) when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email |> String.trim() |> String.downcase())
    if User.valid_password?(user, password), do: user
  end

  def change_registration(attrs \\ %{}), do: User.registration_changeset(%User{}, attrs)

  @doc "Registers a bidder and gives them a paddle number."
  def register_bidder(attrs) do
    %User{kind: "bidder", bid_limit: @default_limit}
    |> User.registration_changeset(attrs)
    |> insert_with_paddle("bidder")
  end

  @doc "A temporary staff member for visitors trying the desk: 24 hours, no head of sale."
  def create_trial_staff do
    n = :rand.uniform(9000) + 999

    %User{
      kind: "staff",
      trial: true,
      name: "Guest staff #{n}",
      email: "guest-staff-#{System.unique_integer([:positive])}-#{n}@staff.invalid",
      roles: ~w(specialist auctioneer client_services),
      bid_limit: 0,
      expires_at: DateTime.add(DateTime.utc_now(), 24, :hour)
    }
    |> Ecto.Changeset.change()
    |> insert_with_paddle("staff")
  end

  @doc false
  def insert_with_paddle(changeset, kind, attempts \\ 8)
  def insert_with_paddle(_changeset, _kind, 0), do: {:error, :no_paddle}

  def insert_with_paddle(%Ecto.Changeset{} = cs, kind, attempts) do
    range = Map.fetch!(@paddles, kind)
    paddle = Enum.random(range)

    case cs |> Ecto.Changeset.put_change(:paddle, paddle) |> Ecto.Changeset.unique_constraint(:paddle) |> Repo.insert() do
      {:ok, user} ->
        {:ok, user}

      {:error, %Ecto.Changeset{errors: errors} = failed} ->
        if Keyword.has_key?(errors, :paddle) and map_size(Map.delete(Map.new(errors), :paddle)) == 0,
          do: insert_with_paddle(cs, kind, attempts - 1),
          else: {:error, failed}
    end
  end

  ## Sessions

  def generate_session_token(user) do
    {token, row} = UserToken.build_session_token(user)
    Repo.insert!(row)
    token
  end

  def get_user_by_session_token(token) when is_binary(token) do
    token |> UserToken.verify_session_token_query() |> Repo.one() |> live_user()
  end

  def get_user_by_session_token(_), do: nil

  defp live_user(nil), do: nil

  defp live_user(%User{expires_at: %DateTime{} = at} = user) do
    if DateTime.compare(at, DateTime.utc_now()) == :gt, do: user
  end

  defp live_user(user), do: user

  def delete_session_token(token) do
    Repo.delete_all(UserToken.by_token_and_context_query(token, "session"))
    :ok
  end

  @doc "Marks a user as seen; at most once a minute, so it costs nothing per request."
  def touch(%User{last_seen_at: seen} = user) do
    now = DateTime.utc_now()

    if is_nil(seen) or DateTime.diff(now, seen) > 60 do
      from(u in User, where: u.id == ^user.id) |> Repo.update_all(set: [last_seen_at: now])
    end

    :ok
  end

  ## Staff

  def list_bidders(opts \\ []) do
    q = Keyword.get(opts, :q)

    User
    |> where([u], u.kind == "bidder")
    |> then(fn query ->
      case q && String.trim(q) do
        nil -> query
        "" -> query
        term ->
          like = "%" <> String.replace(term, ~r/[%_\\]/, "") <> "%"

          case Integer.parse(term) do
            {paddle, ""} -> where(query, [u], u.paddle == ^paddle or ilike(u.name, ^like))
            _ -> where(query, [u], ilike(u.name, ^like) or ilike(u.email, ^like))
          end
      end
    end)
    |> order_by([u], desc: u.inserted_at)
    |> limit(^Keyword.get(opts, :limit, 50))
    |> Repo.all()
  end

  def set_bid_limit(%User{} = user, amount) when is_integer(amount) and amount >= 0 do
    user |> Ecto.Changeset.change(bid_limit: amount) |> Repo.update()
  end
end
