defmodule Umber.Release do
  @moduledoc """
  Tasks a release runs without Mix: migrations, the catalogue, the sample
  bidders, and the check every release must pass before visitors reach it.
  The activate script on the server calls these through `bin/umber eval`.
  """

  import Ecto.Query
  alias Umber.Repo
  alias Umber.Accounts
  alias Umber.Accounts.User

  @app :umber
  @sample_bidders 40

  # Release tasks run beside two slots during a switch: 8 connections each
  # (a pool of 6, the broadcast listener and the job queue's listener), plus
  # these 2, within the role's limit of 20.
  @task_pool [pool_size: 2]

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true), @task_pool)
    end
  end

  def seed do
    load_app()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(
        Repo,
        fn _ ->
          {:ok, :ok} = Umber.Catalogue.import!()
          ensure_sample_bidders()
        end,
        @task_pool
      )

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

  @doc "Prints the Erlang flavour, so the activate script can see the release runs on this CPU."
  def flavor, do: IO.puts(:erlang.system_info(:emu_flavor))

  ## The release check

  # Every page a visitor is likely to open first. Each is fetched twice: a
  # page that only works on its first request must not pass.
  @static_paths ~w(/ /sales /results /artists /buy /sell /about /visit /conditions /privacy /terms
                   /register /signin /desk/signin /robots.txt /sitemap.xml /manifest.webmanifest
                   /artists/juma-mwakalinga /live)

  @doc "The public paths, one per line, for the activate script to fetch through nginx."
  def print_paths do
    for path <- public_paths(), do: IO.puts(path)
  end

  defp public_paths do
    load_app()
    Application.ensure_all_started(:postgrex)
    Application.ensure_all_started(:ecto_sql)

    {:ok, _, paths} =
      Ecto.Migrator.with_repo(
        Repo,
        fn _ ->
          sales =
            from(s in Umber.Catalogue.Sale,
              where: s.published and s.status != "draft",
              order_by: [desc: s.number],
              limit: 3
            )
            |> Repo.all()

          Enum.flat_map(sales, &["/sales/#{&1.number}", "/sales/#{&1.number}/lots/1"])
        end,
        @task_pool
      )

    @static_paths ++ paths
  end

  @doc """
  Walks a running release at `base` (http://127.0.0.1:8501, say) as the
  deploy gate: the health check names the right release, every public page
  answers twice, the bidding engine works, and the live socket upgrades.
  Halts with status 1 on the first failure.
  """
  def check(base, release) do
    {:ok, _} = Application.ensure_all_started(:inets)
    results = [health(base, release)] ++ pages(base) ++ [engine(base), socket(base)]

    case Enum.reject(results, &(&1 == :ok)) do
      [] ->
        IO.puts("release #{String.slice(release, 0, 7)} passed: #{length(results)} checks")

      failures ->
        Enum.each(failures, fn {:error, why} -> IO.puts(:stderr, "FAILED " <> why) end)
        System.halt(1)
    end
  end

  defp get(url) do
    case :httpc.request(
           :get,
           {String.to_charlist(url), [{~c"user-agent", ~c"umber-release-check"}]},
           [timeout: 15_000, autoredirect: false],
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, headers, body}} ->
        {:ok, status, Map.new(headers, fn {k, v} -> {to_string(k), to_string(v)} end), body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp health(base, release) do
    case get(base <> "/healthz") do
      {:ok, 200, %{"x-release" => ^release}, _} ->
        :ok

      {:ok, status, headers, _} ->
        {:error, "/healthz answered #{status}, release #{headers["x-release"]}"}

      {:error, reason} ->
        {:error, "/healthz: #{inspect(reason)}"}
    end
  end

  defp pages(base) do
    for path <- public_paths(), round <- [1, 2] do
      case get(base <> path) do
        {:ok, status, _, _} when status in [200, 302] -> :ok
        {:ok, status, _, _} -> {:error, "#{path} answered #{status} (request #{round})"}
        {:error, reason} -> {:error, "#{path}: #{inspect(reason)}"}
      end
    end
  end

  defp engine(base) do
    case get(base <> "/healthz/engine") do
      {:ok, 200, _, _} -> :ok
      {:ok, status, _, body} -> {:error, "engine check answered #{status}: #{String.trim(body)}"}
      {:error, reason} -> {:error, "engine check: #{inspect(reason)}"}
    end
  end

  # A LiveView page is useless if its socket cannot connect.
  defp socket(base) do
    %URI{host: host, port: port} = URI.parse(base)

    with {:ok, sock} <-
           :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 5_000) do
      key = Base.encode64(:crypto.strong_rand_bytes(16))

      request = [
        "GET /live/websocket?vsn=2.0.0 HTTP/1.1\r\n",
        "Host: umber.jeffgicharu.com\r\n",
        "X-Forwarded-Proto: https\r\n",
        "Origin: https://umber.jeffgicharu.com\r\n",
        "Upgrade: websocket\r\nConnection: Upgrade\r\n",
        "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: #{key}\r\n\r\n"
      ]

      :ok = :gen_tcp.send(sock, request)
      reply = :gen_tcp.recv(sock, 0, 5_000)
      :gen_tcp.close(sock)

      case reply do
        {:ok, "HTTP/1.1 101" <> _} -> :ok
        {:ok, other} -> {:error, "live socket: " <> (other |> String.split("\r\n") |> hd())}
        {:error, reason} -> {:error, "live socket: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> {:error, "live socket: #{inspect(reason)}"}
    end
  end

  @doc """
  The engine check behind /healthz/engine: a sale, a lot and two bidders in
  a transaction, a bid and a higher maximum through the real bidding code,
  the price checked, and everything rolled back.
  """
  def engine_check do
    result =
      Repo.transaction(fn ->
        now = DateTime.utc_now()

        artist =
          Repo.insert!(%Umber.Catalogue.Artist{
            slug: "check-#{System.unique_integer([:positive])}",
            name: "Check",
            nationality: "-",
            based: "-",
            discipline: "-",
            bio: "-"
          })

        work =
          Repo.insert!(%Umber.Catalogue.Work{
            slug: "check-#{artist.id}",
            image: "check-#{artist.id}",
            artist_id: artist.id,
            title: "Check",
            year: "-",
            medium: "-",
            description: "-",
            condition: "-",
            provenance: "-",
            image_width: 1,
            image_height: 1,
            category: "Art"
          })

        sale =
          Repo.insert!(%Umber.Catalogue.Sale{
            number: 900_000 + rem(System.unique_integer([:positive]), 99_999),
            title: "Check",
            format: "timed",
            category: "Art",
            summary: "-",
            description: "-",
            status: "open",
            published: false
          })

        lot =
          Repo.insert!(%Umber.Catalogue.Lot{
            sale_id: sale.id,
            work_id: work.id,
            number: 1,
            estimate_low: 100_000,
            estimate_high: 200_000,
            reserve: 85_000,
            opening_bid: 50_000,
            status: "open",
            market_value: 0,
            closes_at: DateTime.add(now, 3600, :second)
          })

        [a, b] =
          for n <- [1, 2] do
            Repo.insert!(%User{
              email: "check-#{lot.id}-#{n}@check.invalid",
              name: "Check #{n}",
              paddle: 99_000 + n + rem(lot.id, 800) * 2,
              bid_limit: 1_000_000,
              kind: "bidder"
            })
          end

        {:ok, _} = Umber.Auctions.Timed.place(lot.id, a, :bid, 50_000)
        {:ok, change} = Umber.Auctions.Timed.place(lot.id, b, :max, 120_000)

        if change.lot.current_bid == 85_000 and change.lot.leader_id == b.id,
          do: Repo.rollback(:ok),
          else: Repo.rollback({:wrong_price, change.lot.current_bid})
      end)

    case result do
      {:error, :ok} -> :ok
      other -> other
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
