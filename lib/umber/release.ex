defmodule Umber.Release do
  @moduledoc """
  Tasks a release runs without Mix: migrations, the catalogue, and the sample
  bidders. Used by the activate script on the server.
  """

  import Ecto.Query
  alias Umber.Repo
  alias Umber.Accounts
  alias Umber.Accounts.User

  @app :umber
  @sample_bidders 40

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def seed do
    load_app()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Repo, fn _ ->
        {:ok, :ok} = Umber.Catalogue.import!()
        ensure_sample_bidders()
      end)

    :ok
  end

  @doc "The house's sample bidders, known on screen only by paddle number."
  def ensure_sample_bidders do
    have = Repo.aggregate(from(u in User, where: u.kind == "sample"), :count)

    for i <- (have + 1)..@sample_bidders//1 do
      {:ok, _} =
        %User{
          kind: "sample",
          name: "Sample bidder #{i}",
          email: "sample-#{i}@sample.invalid",
          bid_limit: 50_000_000
        }
        |> Ecto.Changeset.change()
        |> Accounts.insert_with_paddle("sample")
    end

    :ok
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
