#!/usr/bin/env bash
#
# Puts an uploaded release live. Installed as /usr/local/bin/umber-activate.
#
# The deploy pipeline reaches this through an SSH key whose only permitted
# command is this script, so the one thing it can ask for is "activate the
# release with this commit id".
#
# The app runs in one of two slots, on ports 8500 and 8501, and nginx sends
# visitors to one of them. A new release is started in the idle slot beside
# the live one and must pass its check there: the health check names it,
# every public page answers twice, a bid goes through the bidding engine in a
# transaction that is rolled back, and the live socket upgrades. Only then do
# visitors reach it. The pages and the socket are checked again through
# nginx; if they fail, nginx goes back to the release before, which has been
# running all along.
#
# Bids are safe through the switch: both slots take bids for a few seconds,
# every bid locks its lot's row in PostgreSQL, and broadcasts reach both
# slots through PostgreSQL. The old slot hands the market lease to the new
# one as it stops.
#
# To go back by hand, run this script with the commit id of an earlier
# release that is still in the releases directory.

set -euo pipefail

BASE=/var/www/umber.jeffgicharu.com
HOST=umber.jeffgicharu.com
APP_USER=umber
ENV_FILE=$BASE/shared/env
STATIC=$BASE/shared/static
UPSTREAM=/etc/nginx/umber/upstream.conf
KEEP_RELEASES=3

release_id="${SSH_ORIGINAL_COMMAND:-${1:-}}"

if [[ ! "$release_id" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Expected a 40 character commit id." >&2
    exit 64
fi

release="$BASE/releases/$release_id"

if [[ ! -d "$release" ]]; then
    echo "Release $release_id has not been uploaded." >&2
    exit 66
fi

# This script runs as deploy, which can become root, and it copies files out
# of the release that nginx then serves. A symlink could point anywhere, so a
# release holding one is refused before anything in it is read.
if [[ -n "$(find "$release" -type l -print -quit)" ]]; then
    echo "Release $release_id contains a symlink. Refusing it." >&2
    exit 66
fi

for file in bin/umber REVISION unavailable.html; do
    if [[ ! -f "$release/$file" ]]; then
        echo "Release $release_id has not been uploaded completely ($file is missing)." >&2
        exit 66
    fi
done
if [[ "$(cat "$release/REVISION")" != "$release_id" ]]; then
    echo "Release $release_id carries the wrong REVISION." >&2
    exit 66
fi

# One deploy at a time.
exec 9>"$BASE/.activate.lock"
flock -n 9 || { echo "Another activation is running." >&2; exit 75; }

live_port="$(grep -oE '127\.0\.0\.1:850[01]' "$UPSTREAM" | head -n1 | cut -d: -f2 || true)"
case "$live_port" in
    8500) idle_port=8501 ;;
    8501) idle_port=8500 ;;
    *) echo "Cannot tell which slot is live from $UPSTREAM." >&2; exit 70 ;;
esac
live_release="$(readlink -f "$BASE/slots/$live_port" 2>/dev/null || true)"
first_release=""
if [[ -z "$live_release" || ! -d "$live_release" ]] || ! systemctl is-active --quiet "umber@$live_port.service"; then
    first_release=yes
fi

if [[ -z "$first_release" && "$live_release" == "$release" ]]; then
    echo "Release ${release_id:0:7} is already live on port $live_port."
    exit 0
fi

# nginx is shared by every site on this server. If its configuration is
# already broken by something else, nothing here should touch it.
if ! sudo nginx -t >/dev/null 2>&1; then
    echo "nginx's configuration does not pass its own test before this release changed anything." >&2
    echo "Nothing was changed. Find out which site broke it before deploying again." >&2
    exit 70
fi

# Release code only ever runs as the application user, with the settings
# file. This script runs as deploy, which can become root, so it never runs
# anything it was sent as itself.
as_app() {
    sudo -u "$APP_USER" -- env -i PATH=/usr/bin:/bin HOME=/nonexistent LANG=C.UTF-8 \
        RELEASE_TMP="$BASE/shared/tmp/eval" \
        bash -c 'set -a; . "$1"; set +a; shift; exec "$@"' _ "$ENV_FILE" "$release/bin/umber" "$@"
}

# The processor here is old. Prove this build runs on it before anything else.
if ! flavor="$(as_app eval "Umber.Release.flavor()" 2>&1)" || [[ "$flavor" != *jit* && "$flavor" != *emu* ]]; then
    echo "Release ${release_id:0:7} does not run on this server: $flavor" >&2
    exit 1
fi
echo "Release ${release_id:0:7} runs here ($flavor)"

# Migrations only ever add, so the release before keeps working beside them.
echo "Migrating the database"
as_app eval "Umber.Release.migrate()"
echo "Loading the catalogue"
as_app eval "Umber.Release.seed()"

# This release's files are added beside the live release's, never in place
# of them: until the switch, visitors still use the release before. Files the
# new release no longer has are removed only after it has gone live.
# Fingerprinted scripts and styles are kept for every release still on disk.
# A font that changes gets a new name, since fonts are cached for a year.
echo "Sharing this release's scripts, styles, fonts and pictures"
static_src="$(echo "$release"/lib/umber-*/priv/static)"
images_src="$(echo "$release"/lib/umber-*/priv/images)"
mkdir -p "$STATIC/assets" "$STATIC/images" "$STATIC/fonts"
rsync -a --ignore-existing "$static_src/assets/" "$STATIC/assets/"
rsync -a --ignore-existing "$images_src/" "$STATIC/images/"
rsync -a --ignore-existing "$static_src/fonts/" "$STATIC/fonts/"

echo "Starting release ${release_id:0:7} on port $idle_port"
sudo systemctl stop "umber@$idle_port.service" 2>/dev/null || true
ln -sfn "$release" "$BASE/slots/$idle_port.new"
mv -Tf "$BASE/slots/$idle_port.new" "$BASE/slots/$idle_port"
sudo systemctl start "umber@$idle_port.service"

abandon() {
    sudo systemctl stop "umber@$idle_port.service" 2>/dev/null || true
    echo "$1" >&2
    exit 1
}

started=""
for attempt in $(seq 1 60); do
    if curl --silent --max-time 3 --head "http://127.0.0.1:$idle_port/healthz" 2>/dev/null | grep -qi "^x-release: $release_id"; then
        started=yes
        break
    fi
    sleep 1
done
if [[ -z "$started" ]]; then
    sudo journalctl -u "umber@$idle_port.service" -n 40 --no-pager >&2 || true
    abandon "Release ${release_id:0:7} did not start. The site is unchanged."
fi

# The gate. Visitors are still on the release before, so a release that
# fails here never reaches them.
echo "Checking the release before it goes live"
if ! as_app eval "Umber.Release.check(\"http://127.0.0.1:$idle_port\", \"$release_id\")"; then
    sudo journalctl -u "umber@$idle_port.service" -n 40 --no-pager >&2 || true
    abandon "Release ${release_id:0:7} failed its check and was not put live."
fi

point_nginx_at() {
    printf 'server 127.0.0.1:%s;\n' "$1" | sudo tee "$UPSTREAM.new" >/dev/null
    sudo mv -f "$UPSTREAM.new" "$UPSTREAM"
    sudo nginx -t >/dev/null 2>&1 || return 1
    sudo systemctl reload nginx
}

# Asks the web server on this machine for a page under the public name. The
# certificate is the one Cloudflare trusts, not one curl knows, hence --insecure.
fetch() {
    curl --silent --show-error --insecure --max-time 20 --resolve "$HOST:443:127.0.0.1" "$@"
}

serves_the_release() {
    local attempt headers path upgrade
    for attempt in $(seq 1 10); do
        headers="$(fetch --head "https://$HOST/healthz" || true)"
        if grep -qi "^x-release: $release_id" <<<"$headers"; then
            break
        fi
        if [[ $attempt -eq 10 ]]; then
            echo "The web server is not serving ${release_id:0:7}." >&2
            return 1
        fi
        sleep 1
    done
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        if ! fetch --fail --output /dev/null "https://$HOST$path"; then
            echo "$path did not load on the live site." >&2
            return 1
        fi
    done < <(as_app eval "Umber.Release.print_paths()")
    # The live socket through nginx answers 101 Switching Protocols. The key
    # must be 16 bytes, base64 encoded. An open socket never ends by itself, so
    # curl is cut off and only the status line it has already printed counts.
    upgrade="$(fetch --http1.1 --max-time 4 --dump-header - --output /dev/null \
        -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Origin: https://$HOST" \
        -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dW1iZXItYWN0aXZhdGUtMQ==" \
        "https://$HOST/live/websocket?vsn=2.0.0" 2>/dev/null | head -n 1 | tr -d '\r' || true)"
    if [[ "$upgrade" != "HTTP/1.1 101"* ]]; then
        echo "The live socket does not upgrade through nginx (got: ${upgrade:-nothing})." >&2
        return 1
    fi
}

go_back() {
    if [[ -n "$first_release" ]]; then
        abandon "$1 There was no release before this one to go back to."
    fi
    if point_nginx_at "$live_port"; then
        abandon "$1 Visitors are back on the release before."
    fi
    abandon "$1 nginx could not be pointed back. Look at this now."
}

echo "Switching visitors to release ${release_id:0:7}"
if ! point_nginx_at "$idle_port"; then
    printf 'server 127.0.0.1:%s;\n' "$live_port" | sudo tee "$UPSTREAM" >/dev/null
    abandon "nginx refused its configuration. The site is unchanged."
fi

echo "Checking the live site"
if ! serves_the_release; then
    go_back "Release ${release_id:0:7} did not serve its pages."
fi

# The slot that is live is the one that starts when the server boots.
sudo systemctl enable "umber@$idle_port.service" >/dev/null 2>&1 || true
sudo systemctl disable "umber@$live_port.service" >/dev/null 2>&1 || true

# Live and checked: now the shared pictures and fonts can match this
# release exactly, changed files included, and its unavailable page can take over.
rsync -a --delete "$images_src/" "$STATIC/images/"
rsync -a --delete "$static_src/fonts/" "$STATIC/fonts/"
cp "$release/unavailable.html" "$BASE/shared/pages/unavailable.html"

# Requests in hand on the old release are given time to finish. Stopping it
# hands the market lease to the new release and closes its sockets; those
# browsers reconnect to the new release by themselves.
sleep 10
sudo systemctl stop "umber@$live_port.service" 2>/dev/null || true

echo "Removing old releases"
cd "$BASE/releases"
ls -1t | tail -n +$((KEEP_RELEASES + 1)) | while read -r old; do
    [[ "$old" =~ ^[0-9a-f]{40}$ && "$old" != "$release_id" && "$BASE/releases/$old" != "$live_release" ]] || continue
    rm -rf -- "${BASE:?}/releases/$old"
done

# Fingerprinted files are kept for every release still on disk.
keep="$(mktemp)"
for kept in "$BASE"/releases/*/; do
    dir="$(echo "$kept"lib/umber-*/priv/static/assets)"
    [[ -d "$dir" ]] && ( cd "$dir" && find . -type f ) >>"$keep"
done
sort -u "$keep" -o "$keep"
if [[ -s "$keep" && -d "$STATIC/assets" ]]; then
    ( cd "$STATIC/assets" && find . -type f ) | sort | comm -23 - "$keep" | while read -r stale; do
        rm -f -- "$STATIC/assets/$stale"
    done
    find "$STATIC/assets" -mindepth 1 -type d -empty -delete 2>/dev/null || true
fi
rm -f "$keep"

echo "Release ${release_id:0:7} is live on port $idle_port."
