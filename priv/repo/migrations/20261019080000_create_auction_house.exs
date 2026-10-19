defmodule Umber.Repo.Migrations.CreateAuctionHouse do
  use Ecto.Migration

  def change do
    create table(:artists) do
      add :slug, :string, null: false
      add :name, :string, null: false
      add :born, :integer
      add :died, :integer
      add :founded, :integer
      add :period, :string
      add :nationality, :string, null: false
      add :based, :string, null: false
      add :discipline, :string, null: false
      add :bio, :text, null: false
      timestamps()
    end

    create unique_index(:artists, [:slug])

    # A work is the object itself; a lot is a work offered in one sale.
    create table(:works) do
      add :slug, :string, null: false
      add :image, :string, null: false
      add :artist_id, references(:artists, on_delete: :restrict), null: false
      add :title, :string, null: false
      add :year, :string, null: false
      add :medium, :string, null: false
      add :height_cm, :decimal
      add :width_cm, :decimal
      add :depth_cm, :decimal
      add :dimensions_note, :string
      add :edition, :string
      add :description, :text, null: false
      add :condition, :text, null: false
      add :provenance, :text, null: false
      add :exhibited, :text
      add :literature, :text
      add :image_width, :integer, null: false
      add :image_height, :integer, null: false
      add :second_view, :map
      add :category, :string, null: false
      timestamps()
    end

    create unique_index(:works, [:slug])
    create index(:works, [:artist_id])

    create table(:users) do
      add :email, :string, null: false
      add :hashed_password, :string
      add :name, :string, null: false
      add :country, :string
      add :phone, :string
      add :paddle, :integer, null: false
      add :bid_limit, :bigint, null: false
      add :kind, :string, null: false, default: "bidder"
      add :roles, {:array, :string}, null: false, default: []
      add :trial, :boolean, null: false, default: false
      add :last_seen_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec
      timestamps()
    end

    create unique_index(:users, [:email])
    create unique_index(:users, [:paddle])
    create index(:users, [:kind])

    create table(:users_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :context, :string, null: false
      timestamps(updated_at: false)
    end

    create index(:users_tokens, [:user_id])
    create unique_index(:users_tokens, [:context, :token])

    create table(:sales) do
      add :number, :integer, null: false
      add :template, :string
      add :title, :string, null: false
      add :format, :string, null: false
      add :category, :string, null: false
      add :summary, :text, null: false
      add :description, :text, null: false
      add :status, :string, null: false
      add :published, :boolean, null: false, default: true
      add :opens_at, :utc_datetime_usec
      # Timed sales: the first lot closes at first_close_at and each later lot
      # lot_interval seconds after the one before.
      add :first_close_at, :utc_datetime_usec
      add :lot_interval, :integer
      # Live sales: when the auctioneer opens the first lot.
      add :starts_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec
      add :created_by_id, references(:users, on_delete: :nilify_all)
      timestamps()
    end

    create unique_index(:sales, [:number])
    create index(:sales, [:template, :status])
    create index(:sales, [:status])

    create table(:lots) do
      add :sale_id, references(:sales, on_delete: :delete_all), null: false
      add :work_id, references(:works, on_delete: :restrict), null: false
      add :number, :integer, null: false
      add :estimate_low, :bigint, null: false
      add :estimate_high, :bigint, null: false
      add :reserve, :bigint, null: false
      add :opening_bid, :bigint, null: false
      # pending -> open -> sold | unsold; withdrawn at any time before.
      add :status, :string, null: false, default: "pending"
      add :current_bid, :bigint
      add :leader_id, references(:users, on_delete: :nilify_all)
      add :bid_count, :integer, null: false, default: 0
      add :closes_at, :utc_datetime_usec
      add :extensions, :integer, null: false, default: 0
      add :hammer, :bigint
      add :buyer_id, references(:users, on_delete: :nilify_all)
      add :closed_at, :utc_datetime_usec
      # What the sample bidders will go to, chosen when the lot is made.
      add :market_value, :bigint, null: false
      # Every accepted change bumps the version; writers check it.
      add :version, :integer, null: false, default: 0
      timestamps()
    end

    create unique_index(:lots, [:sale_id, :number])
    create index(:lots, [:work_id])
    create index(:lots, [:status, :closes_at])
    create index(:lots, [:leader_id])
    create index(:lots, [:buyer_id])

    # Every bid ever accepted, in order. Never updated.
    create table(:bids) do
      add :lot_id, references(:lots, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all)
      add :amount, :bigint, null: false
      # bid (one tap), proxy (placed by a maximum), floor, absentee
      add :kind, :string, null: false
      add :source, :string, null: false
      timestamps(updated_at: false)
    end

    create index(:bids, [:lot_id, :inserted_at])
    create index(:bids, [:user_id])

    create table(:max_bids) do
      add :lot_id, references(:lots, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :amount, :bigint, null: false
      timestamps()
    end

    create unique_index(:max_bids, [:lot_id, :user_id])

    create table(:watches, primary_key: false) do
      add :user_id, references(:users, on_delete: :delete_all), null: false, primary_key: true
      add :lot_id, references(:lots, on_delete: :delete_all), null: false, primary_key: true
      timestamps(updated_at: false)
    end

    create index(:watches, [:lot_id])

    create table(:invoices) do
      add :number, :string, null: false
      add :lot_id, references(:lots, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :hammer, :bigint, null: false
      add :premium, :bigint, null: false
      add :vat, :bigint, null: false
      add :total, :bigint, null: false
      add :status, :string, null: false, default: "due"
      add :paid_at, :utc_datetime_usec
      add :paid_by_id, references(:users, on_delete: :nilify_all)
      timestamps()
    end

    create unique_index(:invoices, [:number])
    create unique_index(:invoices, [:lot_id])
    create index(:invoices, [:user_id])

    create table(:limit_requests) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :amount, :bigint, null: false
      add :reason, :text
      add :status, :string, null: false, default: "pending"
      add :decided_by_id, references(:users, on_delete: :nilify_all)
      add :decided_at, :utc_datetime_usec
      timestamps()
    end

    create index(:limit_requests, [:status])
    create index(:limit_requests, [:user_id])

    create table(:consignments) do
      add :user_id, references(:users, on_delete: :nilify_all)
      add :name, :string, null: false
      add :email, :string, null: false
      add :phone, :string
      add :artist_name, :string, null: false
      add :title, :string
      add :medium, :string
      add :dimensions, :string
      add :description, :text, null: false
      add :acquired, :text
      add :photos, {:array, :string}, null: false, default: []
      add :status, :string, null: false, default: "new"
      add :staff_note, :text
      timestamps()
    end

    create index(:consignments, [:status])
    create index(:consignments, [:user_id])

    create table(:push_subscriptions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :endpoint, :text, null: false
      add :p256dh, :string, null: false
      add :auth, :string, null: false
      timestamps()
    end

    create unique_index(:push_subscriptions, [:endpoint])
    create index(:push_subscriptions, [:user_id])

    # The state of a live sale at the rostrum, one row per live sale.
    create table(:live_sessions, primary_key: false) do
      add :sale_id, references(:sales, on_delete: :delete_all), primary_key: true
      # waiting | open | warning | sold | passed | paused | ended
      add :state, :string, null: false, default: "waiting"
      add :lot_id, references(:lots, on_delete: :nilify_all)
      add :asking, :bigint
      add :current_bid, :bigint
      add :leader_id, references(:users, on_delete: :nilify_all)
      add :leader_source, :string
      add :call, :string
      add :called_at, :utc_datetime_usec
      add :auctioneer_id, references(:users, on_delete: :nilify_all)
      add :auctioneer_seen_at, :utc_datetime_usec
      add :version, :integer, null: false, default: 0
      timestamps()
    end

    # One release at a time runs the sample market and the auctioneers.
    create table(:leases, primary_key: false) do
      add :name, :string, primary_key: true
      add :holder, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false
    end

    create table(:settings, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :map, null: false
      timestamps()
    end
  end
end
