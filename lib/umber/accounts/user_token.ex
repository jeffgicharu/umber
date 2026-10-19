defmodule Umber.Accounts.UserToken do
  use Umber.Schema
  import Ecto.Query

  @rand_size 32
  @session_validity_days 30

  schema "users_tokens" do
    field :token, :binary
    field :context, :string
    belongs_to :user, Umber.Accounts.User
    timestamps(updated_at: false)
  end

  @doc "A new session token and the row that stores it."
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    {token, %__MODULE__{token: token, context: "session", user_id: user.id}}
  end

  def verify_session_token_query(token) do
    from t in __MODULE__,
      join: u in assoc(t, :user),
      where: t.token == ^token and t.context == "session",
      where: t.inserted_at > ago(@session_validity_days, "day"),
      select: u
  end

  def by_token_and_context_query(token, context) do
    from t in __MODULE__, where: t.token == ^token and t.context == ^context
  end

  def by_user_query(user_id) do
    from t in __MODULE__, where: t.user_id == ^user_id
  end
end
