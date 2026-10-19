#!/usr/bin/env bash
#
# Prepares the server for Umber. Run once, as deploy, from a temporary folder
# (made with mktemp -d) that holds the files it installs:
#
#   nginx.conf  umber@.service  activate.sh  unavailable.html
#   deploy-keys.pub  staff-trial-key
#
# The folder is sent and unpacked in the same SSH connection that runs this:
#
#   tar -czf - -C <folder> . | ssh deploy@<server> \
#     'd="$(mktemp -d)" && { tar -xzf - -C "$d" && bash "$d/provision.sh"; rc=$?; rm -rf -- "$d"; exit $rc; }'
#
# The folder holds a key, so it is removed when this script ends, whether it
# finishes or fails. It is safe to run again: anything that already exists is
# left alone, and no secret is ever printed.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BASE=/var/www/umber.jeffgicharu.com

case "$HERE" in
    /tmp/tmp.*) trap 'rm -rf -- "$HERE"' EXIT ;;
    *) echo "Run this from a folder made by mktemp -d, so it can be removed afterwards." >&2; exit 64 ;;
esac

step() { printf '\n== %s\n' "$1"; }

step "Application user"
if id umber >/dev/null 2>&1; then
    echo "umber exists"
else
    sudo useradd --system --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin umber
    echo "created umber"
fi

step "Folders"
sudo install -d -o deploy -g deploy -m 755 "$BASE" "$BASE/releases" "$BASE/slots" "$BASE/shared" "$BASE/shared/static" "$BASE/shared/pages"
# Consignment photographs and the release's own scratch space. Only the app writes here.
sudo install -d -o umber -g umber -m 750 "$BASE/shared/uploads" "$BASE/shared/tmp" "$BASE/shared/tmp/eval"
cp "$HERE/unavailable.html" "$BASE/shared/pages/unavailable.html"
ls -ld "$BASE" "$BASE"/* "$BASE"/shared/*

step "Database and settings"
role_exists="$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname = 'umber'")"
db_exists="$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname = 'umber'")"

if sudo test -f "$BASE/shared/env"; then
    echo "settings file exists; left as it is"
    if [[ "$role_exists" != "1" ]]; then
        echo "The settings file exists but the role umber does not. Stopping." >&2
        exit 70
    fi
else
    # Every value is worked out before anything is created, so a failure here
    # leaves nothing behind that the settings file would not record.
    trial_key="$(tr -d '\n' < "$HERE/staff-trial-key")"
    if [[ ! "$trial_key" =~ ^[A-Za-z0-9_-]{20,}$ ]]; then
        echo "The staff trial key must be 20 or more letters, digits, - or _." >&2
        exit 64
    fi

    # VAPID keys for push notices: a P-256 key pair, as raw base64url.
    keydir="$(mktemp -d)"
    openssl ecparam -name prime256v1 -genkey -noout -out "$keydir/vapid.pem" 2>/dev/null
    vapid_private="$(openssl ec -in "$keydir/vapid.pem" -outform DER 2>/dev/null | tail -c +8 | head -c 32 | basenc --base64url | tr -d '=\n')"
    vapid_public="$(openssl ec -in "$keydir/vapid.pem" -pubout -outform DER 2>/dev/null | tail -c 65 | basenc --base64url | tr -d '=\n')"
    rm -rf -- "$keydir"
    if [[ ${#vapid_private} -ne 43 || ${#vapid_public} -ne 87 ]]; then
        echo "The VAPID keys did not come out at the expected lengths. Stopping." >&2
        exit 70
    fi

    # Hex only, so every line is safe to read in a shell.
    db_password="$(openssl rand -hex 24)"
    secret_key_base="$(openssl rand -hex 64)"
    release_cookie="$(openssl rand -hex 32)"

    # The password goes in on standard input, never on a command line.
    if [[ "$role_exists" == "1" ]]; then
        # Left by an earlier run that stopped before writing the settings;
        # nothing uses the role yet, so it gets a fresh password.
        sudo -u postgres psql -v ON_ERROR_STOP=1 -q <<SQL
ALTER ROLE umber WITH LOGIN PASSWORD '$db_password' CONNECTION LIMIT 20;
SQL
        echo "role umber had no settings file; gave it a new password"
    else
        sudo -u postgres psql -v ON_ERROR_STOP=1 -q <<SQL
CREATE ROLE umber LOGIN PASSWORD '$db_password' CONNECTION LIMIT 20;
SQL
        echo "created role umber (connection limit 20)"
    fi

    # Created with its final owner and mode before anything is written into it.
    sudo install -m 640 -o root -g umber /dev/null "$BASE/shared/env"
    {
        echo "PHX_HOST=umber.jeffgicharu.com"
        echo "DATABASE_URL=ecto://umber:$db_password@127.0.0.1/umber"
        echo "POOL_SIZE=6"
        echo "SECRET_KEY_BASE=$secret_key_base"
        echo "RELEASE_COOKIE=$release_cookie"
        echo "VAPID_SUBJECT=https://umber.jeffgicharu.com"
        echo "VAPID_PUBLIC_KEY=$vapid_public"
        echo "VAPID_PRIVATE_KEY=$vapid_private"
        echo "UMBER_STAFF_TRIAL_KEY=$trial_key"
    } | sudo tee -a "$BASE/shared/env" >/dev/null
    unset db_password secret_key_base release_cookie vapid_private vapid_public trial_key
    echo "wrote the settings file"
fi

if [[ "$db_exists" == "1" ]]; then
    echo "database umber exists"
else
    sudo -u postgres psql -v ON_ERROR_STOP=1 -q -c "CREATE DATABASE umber OWNER umber"
    sudo -u postgres psql -v ON_ERROR_STOP=1 -q -c "REVOKE CONNECT ON DATABASE umber FROM PUBLIC"
    echo "created database umber, owned by umber"
fi
sudo -u postgres psql -tAc "SELECT rolname, rolconnlimit FROM pg_roles WHERE rolname = 'umber'"
sudo ls -l "$BASE/shared/env"
echo "settings names: $(sudo cut -d= -f1 "$BASE/shared/env" | tr '\n' ' ')"

step "systemd unit"
sudo install -o root -g root -m 644 "$HERE/umber@.service" /etc/systemd/system/umber@.service
sudo systemctl daemon-reload
echo "installed umber@.service"

step "Activate script"
sudo install -o root -g root -m 755 "$HERE/activate.sh" /usr/local/bin/umber-activate
ls -l /usr/local/bin/umber-activate

step "Deploy keys"
touch ~/.ssh/authorized_keys
backup=~/.ssh/authorized_keys.bak-$(date -u +%F)-umber
if [[ ! -e "$backup" ]]; then
    cp -p ~/.ssh/authorized_keys "$backup"
    echo "backed up authorized_keys to $backup"
fi
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    key="$(awk '{print $(NF-1)}' <<<"$line")"
    if grep -qF "$key" ~/.ssh/authorized_keys; then
        echo "already present: $(awk '{print $NF}' <<<"$line")"
    else
        printf '%s\n' "$line" >> ~/.ssh/authorized_keys
        echo "added: $(awk '{print $NF}' <<<"$line")"
    fi
done < "$HERE/deploy-keys.pub"
echo "authorized_keys lines: $(grep -c . ~/.ssh/authorized_keys)"
awk '/umber-(upload|activate)$/ {print "line " NR ": " $NF}' ~/.ssh/authorized_keys
kept_lines="$(grep -c . "$backup")"
if cmp -s <(head -n "$kept_lines" ~/.ssh/authorized_keys) "$backup"; then
    echo "lines 1 to $kept_lines match the backup"
else
    echo "lines 1 to $kept_lines do NOT match the backup" >&2
fi

step "nginx"
echo "nginx -t before:"
if ! sudo nginx -t 2>&1 | awk '{print "  " $0}'; then
    echo "nginx does not pass its own test before any change. Stopping without touching it." >&2
    exit 70
fi
sudo install -d -o root -g root -m 755 /etc/nginx/umber
if [[ ! -f /etc/nginx/umber/upstream.conf ]]; then
    echo "server 127.0.0.1:8500;" | sudo tee /etc/nginx/umber/upstream.conf >/dev/null
fi
sudo install -o root -g root -m 644 "$HERE/nginx.conf" /etc/nginx/sites-available/umber.jeffgicharu.com
sudo ln -sfn /etc/nginx/sites-available/umber.jeffgicharu.com /etc/nginx/sites-enabled/umber.jeffgicharu.com
echo "nginx -t after:"
if sudo nginx -t 2>&1 | awk '{print "  " $0}'; then
    sudo systemctl reload nginx
    echo "nginx reloaded with umber.jeffgicharu.com"
else
    sudo rm -f /etc/nginx/sites-enabled/umber.jeffgicharu.com
    sudo nginx -t || true
    echo "Umber's nginx file failed the test and was taken out again." >&2
    exit 1
fi

step "Checks"
command -v rrsync >/dev/null && echo "rrsync: $(command -v rrsync)"
curl -s -o /dev/null -w 'umber.jeffgicharu.com through nginx before the first release: %{http_code}\n' --insecure --resolve umber.jeffgicharu.com:443:127.0.0.1 https://umber.jeffgicharu.com/ || true
free -m | head -2
df -h /var/www | tail -1

echo
echo "Provisioning finished."
