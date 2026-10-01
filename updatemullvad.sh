#!/usr/bin/env bash
set -euo pipefail
[[ $# -le 1 ]] || { echo "Usage: $0 [MullvadVPN.deb]" >&2; exit 1; }
service_dir=${RUNIT_SERVICE_DIR:-}
if [[ -z "$service_dir" ]]; then
    for dir in /var/service /run/runit/service /etc/service /service; do
        [[ -d "$dir" ]] && { service_dir=$dir; break; }
    done
fi
[[ -n "$service_dir" && -d "$service_dir" ]] || { echo 'Set RUNIT_SERVICE_DIR to your active runit service directory.' >&2; exit 1; }
for cmd in curl ar tar sv sudo install; do command -v "$cmd" >/dev/null; done
workdir=$(mktemp -d)
trap 'rm -rf -- "$workdir"' EXIT
if [[ $# -eq 1 ]]; then
    cp -- "$1" "$workdir/mullvad.deb"
else
    curl -fL --retry 3 --proto '=https' --proto-redir '=https' 'https://mullvad.net/en/download/app/deb/latest' -o "$workdir/mullvad.deb"
fi
member=$(ar t "$workdir/mullvad.deb" | awk '/^data\.tar(\.(xz|gz|zst|bz2))?$/ {print; exit}')
[[ -n "$member" ]] || { echo 'No .deb found.' >&2; exit 1; }
ar p "$workdir/mullvad.deb" "$member" > "$workdir/$member"
mkdir "$workdir/payload"
tar -xaf "$workdir/$member" -C "$workdir/payload"
"$workdir/payload/usr/bin/mullvad" --version >/dev/null
[[ -x "$workdir/payload/usr/bin/mullvad-daemon" ]]
service="$service_dir/mullvad"
sudo -v
[[ ! -d "$service" ]] || sudo sv -w 30 down "$service"
trap '[[ ! -d "$service" ]] || sudo sv -w 30 up "$service" || true; rm -rf -- "$workdir"' EXIT
sudo cp -a -- "$workdir/payload/." /
sudo chown root:root /usr/bin/mullvad-exclude
sudo chmod u+s /usr/bin/mullvad-exclude
if [[ ! -d "$service" ]]; then
    echo 'Mullvad runit sv missing, createing one now.'
    [[ ! -e "$service" && ! -L "$service" ]] || { echo "Invalid sv entry: $service" >&2; exit 1; }
    if [[ ! -f /etc/sv/mullvad/run ]]; then
        printf '%s\n' '#!/bin/sh' 'exec 2>&1' 'exec /usr/bin/mullvad-daemon -v --disable-stdout-timestamps' > "$workdir/run"
        sudo install -d -m 755 /etc/sv/mullvad
        sudo install -m 755 "$workdir/run" /etc/sv/mullvad/run
    fi
    sudo ln -s /etc/sv/mullvad "$service"
fi
for ((i=0; i<20; i++)); do
    sudo sv status "$service" >/dev/null 2>&1 && break
    sleep 1
done
sudo sv -w 30 up "$service"
sudo sv status "$service"
mullvad version
