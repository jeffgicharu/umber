defmodule Umber.Accounts.User do
  use Umber.Schema
  import Ecto.Changeset

  @kinds ~w(bidder sample staff)
  @roles ~w(specialist head_of_sale auctioneer client_services)

  schema "users" do
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :name, :string
    field :country, :string
    field :phone, :string
    field :paddle, :integer
    field :bid_limit, :integer
    field :kind, :string, default: "bidder"
    field :roles, {:array, :string}, default: []
    field :trial, :boolean, default: false
    field :last_seen_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :accept_conditions, :boolean, virtual: true

    timestamps()
  end

  def kinds, do: @kinds
  def roles, do: @roles

  def staff?(%__MODULE__{kind: "staff"}), do: true
  def staff?(_), do: false

  def role?(%__MODULE__{kind: "staff", roles: roles}, role), do: role in roles
  def role?(_, _), do: false

  @doc "A first name for greetings: \"Wanjiru\" from \"Wanjiru Kamau\"."
  def first_name(%__MODULE__{name: name}), do: name |> String.split() |> List.first()

  @doc "Registration of a bidder: name, email, password, country and an optional phone."
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :email, :password, :country, :phone, :accept_conditions])
    |> update_change(:name, &squish/1)
    |> update_change(:phone, &squish/1)
    |> validate_required([:name], message: "Enter your name")
    |> validate_length(:name, min: 2, max: 80, message: "Enter your full name")
    |> validate_email()
    |> validate_password()
    |> validate_required([:country], message: "Choose your country")
    |> validate_length(:country, max: 60)
    |> validate_format(:phone, ~r/^\+?[0-9 ()-]{7,20}$/,
      message: "Enter a phone number like +254 712 345 678"
    )
    |> validate_acceptance(:accept_conditions,
      message: "Accept the conditions of sale to register"
    )
    |> hash_password()
  end

  defp validate_email(cs) do
    cs
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> validate_required([:email], message: "Enter your email address")
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+\.[^@,;\s]+$/,
      message: "Enter an email address like name@example.com"
    )
    |> validate_length(:email, max: 160)
    |> unsafe_validate_unique(:email, Umber.Repo,
      message: "An account already uses this email. Sign in instead."
    )
    |> unique_constraint(:email, message: "An account already uses this email. Sign in instead.")
  end

  defp validate_password(cs) do
    cs
    |> validate_required([:password], message: "Choose a password")
    |> validate_length(:password, min: 10, max: 72, message: "Use at least 10 characters")
  end

  defp hash_password(cs) do
    case cs do
      %Ecto.Changeset{valid?: true, changes: %{password: password}} ->
        cs
        |> put_change(:hashed_password, Pbkdf2.hash_pwd_salt(password))
        |> delete_change(:password)

      _ ->
        cs
    end
  end

  @doc "Checks a password, taking the same time whether or not the user exists."
  def valid_password?(%__MODULE__{hashed_password: hashed}, password)
      when is_binary(hashed) and byte_size(password) > 0 do
    Pbkdf2.verify_pass(password, hashed)
  end

  def valid_password?(_, _) do
    Pbkdf2.no_user_verify()
    false
  end

  defp squish(nil), do: nil

  defp squish(s),
    do: s |> String.split() |> Enum.join(" ") |> then(&if(&1 == "", do: nil, else: &1))
end
