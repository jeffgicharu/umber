defmodule Umber.Market.Cleanup do
  @moduledoc """
  Keeps the database the size of a working week. Run by the scheduler every
  ten minutes; each pass is a few indexed deletes.

    * Finished cycles of the running sales go after six hours, unless a
      visitor won a lot in them; those stay eight days, with their invoices.
    * Visitors' accounts go seven days after they were last seen, with their
      bids, watches and invoices.
    * Guest staff accounts go when their 24 hours are up.
    * Consignment enquiries, and their photographs, go after seven days.

  The house's own past sales, its catalogue and its sample bidders are never touched.
  """

  require Logger
  import Ecto.Query
  alias Umber.Repo
  alias Umber.Accounts.User
  alias Umber.Catalogue.{Sale, Lot}
  alias Umber.Auctions.Invoice
  alias Umber.Desk.Consignment

  @cycle_hours 6
  @won_days 8
  @visitor_days 7
  @consignment_days 7

  def run(now \\ DateTime.utc_now()) do
    cycles = old_cycles(now)
    visitors = old_visitors(now)
    staff = expired_staff(now)
    consignments = old_consignments(now)

    if cycles + visitors + staff + consignments > 0 do
      Logger.info(
        "clean-up: #{cycles} sale cycles, #{visitors} visitor accounts, #{staff} guest staff, #{consignments} consignments"
      )
    end

    :ok
  end

  defp old_cycles(now) do
    cutoff = DateTime.add(now, -@cycle_hours * 3600, :second)
    won_cutoff = DateTime.add(now, -@won_days * 86_400, :second)

    with_invoices =
      from(i in Invoice,
        join: l in Lot,
        on: l.id == i.lot_id,
        where: l.sale_id == parent_as(:sale).id,
        select: 1
      )

    {n, _} =
      from(s in Sale,
        as: :sale,
        where: not is_nil(s.template) and s.status == "closed",
        where:
          (s.ended_at < ^cutoff and not exists(subquery(with_invoices))) or
            s.ended_at < ^won_cutoff
      )
      |> Repo.delete_all(timeout: 30_000)

    n
  end

  defp old_visitors(now) do
    cutoff = DateTime.add(now, -@visitor_days * 86_400, :second)

    {n, _} =
      from(u in User,
        where: u.kind == "bidder",
        where: coalesce(u.last_seen_at, u.inserted_at) < ^cutoff
      )
      |> Repo.delete_all(timeout: 30_000)

    n
  end

  defp expired_staff(now) do
    {n, _} =
      from(u in User, where: u.kind == "staff" and u.trial and u.expires_at < ^now)
      |> Repo.delete_all()

    n
  end

  defp old_consignments(now) do
    cutoff = DateTime.add(now, -@consignment_days * 86_400, :second)
    old = from(c in Consignment, where: c.inserted_at < ^cutoff) |> Repo.all()
    dir = UmberWeb.SellLive.uploads_dir()

    for c <- old, photo <- c.photos, do: File.rm(Path.join(dir, photo))
    {n, _} = from(c in Consignment, where: c.id in ^Enum.map(old, & &1.id)) |> Repo.delete_all()
    n
  end
end
