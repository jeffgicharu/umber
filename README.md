# Umber

The website, saleroom and staff desk of Umber, an auction house in Nairobi for
modern and contemporary East African art and collectable design.

- **Online sales** close lot by lot. Bidders tap to bid or leave a maximum that
  bids for them. A bid in the last two minutes gives that lot two more.
- **Live sales** are run from the rostrum. Bids from the room, the absentee book
  and online phones are taken one at a time, and every screen shows the same
  asking price, bid in hand and call.
- **The desk** is for staff: the auctioneer's console, sales and lots, bidders
  and their limits, invoices, and consignment enquiries.

## How it is built

- **Elixir and Phoenix LiveView** on Erlang/OTP 29. Every page that changes by
  itself (a lot's price, its closing time, the live room) is a LiveView kept
  current from the server.
- **PostgreSQL** holds everything. A bid is one transaction that locks its lot's
  row, checks the bid, settles maximums, records it and bumps the lot's version.
  Nothing is shown as accepted until it is committed.
- **One process per open lot** queues that lot's bids and holds its closing
  timer. If it crashes it reads the lot back and carries on. Closing is a
  guarded update, so a lot closes exactly once.
- **Broadcasts go through PostgreSQL** `LISTEN`/`NOTIFY`, so two copies of the
  app running side by side during a release both see every bid. Erlang
  distribution stays off.
- **The market**, meaning the schedule, the house's sample bidders and the
  automatic auctioneer, runs on whichever copy holds a lease row in PostgreSQL.
- **Web Push** notices are encrypted in Erlang's own crypto, with no
  third-party service.
- **Hand-written CSS** and a little JavaScript. Movement comes from the
  browser's own View Transitions, scroll-driven animations and the Web
  Animations API.

## Running it

You need Erlang/OTP 29, Elixir 1.20 and PostgreSQL 16 or newer.

```sh
mix setup        # dependencies, database, catalogue, sample bidders
mix phx.server   # http://localhost:4000
```

The market starts with the app: the next live session and both online sales
are created on the hour and the half hour. For the staff desk locally, open
`/desk/try?key=local-desk`.

```sh
mix test
```

The tests cover the bidding rules (maximums, ties, reserves, soft close),
forty bidders bidding on one lot at once, closing from twenty processes at
once, a lot process killed mid-sale, the live rostrum, the clean-up, and every
public page.

## Pictures

Catalogue photographs are built from masters with `scripts/build_images.py`
(AVIF and WebP at three widths, and a JPEG for sharing). The mark, favicons
and sharing picture come from `scripts/build_brand.py`.

## Releasing

Each push to `main` is tested and built in Ubuntu 22.04 by
`.github/workflows/deploy.yml`, then walked by `Umber.Release.check`: every
public page twice, a bid through the engine in a transaction that is rolled
back, and the live socket.

The release is uploaded to the server and started beside the live one by
`deploy/activate.sh`, which runs the same check there. Visitors move to the
new release only when it passes. If the live site then fails its check
through nginx, it goes straight back to the release before.
