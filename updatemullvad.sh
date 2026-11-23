#!/usr/bin/env bash
set -euo pipefail

DEB_URL=https://mullvad.net/en/download/app/deb/latest
KEY_URL=https://mullvad.net/media/mullvad-code-signing.asc
KEY_FPR=A1198702FC3E0A09A9AE5B75D5A1D4F266DE8DDF 

die() { echo "mullvad-update: $*" >&2; exit 1; }
dl()  { curl -fsSL --retry 3 --proto '=https' --proto-redir '=https' "$@"; }

dry=0
if [[ ${1:-} == -n ]]; then dry=1; shift; fi
[[ $# -le 1 ]] || die "usage: $0 [-n] [MullvadVPN.deb]"

for cmd in curl ar tar gpg sv sudo install; do
    command -v "$cmd" >/dev/null || die "missing command: $cmd"
done

service_dir=${RUNIT_SERVICE_DIR:-}
if [[ -z $service_dir ]]; then
    for dir in /var/service /run/runit/service /etc/service /service; do
        [[ -d $dir ]] && { service_dir=$dir; break; }
    done
fi
[[ -n $service_dir && -d $service_dir ]] || die 'set RUNIT_SERVICE_DIR to your active runit service directory'

workdir=$(mktemp -d)
cleanup() { rm -rf -- "$workdir"; }
trap cleanup EXIT

if [[ $# -eq 1 ]]; then
    [[ -f $1.asc ]] || die "signature not found: $1.asc"
    cp -- "$1" "$workdir/mullvad.deb"
    cp -- "$1.asc" "$workdir/mullvad.deb.asc"
else
    echo 'Downloading latest Mullvad .deb ...'
    real_url=$(dl -w '%{url_effective}' -o "$workdir/mullvad.deb" "$DEB_URL")
    echo "  $real_url"
    dl -o "$workdir/mullvad.deb.asc" "$real_url.asc"
fi

export GNUPGHOME="$workdir/gnupg"
install -d -m 700 "$GNUPGHOME"
dl -o "$workdir/key.asc" "$KEY_URL"
gpg --batch --quiet --import "$workdir/key.asc" 2>/dev/null || die 'could not import Mullvad key'
status=$(gpg --batch --status-fd 1 --verify "$workdir/mullvad.deb.asc" "$workdir/mullvad.deb" 2>/dev/null || true)
grep -Eq "^\[GNUPG:\] VALIDSIG .* $KEY_FPR\$" <<<"$status" || die 'signature check FAILED, not installing'
echo 'Signature OK (Mullvad code signing key)'

member=$(ar t "$workdir/mullvad.deb" | awk '/^data\.tar(\.(xz|gz|zst|bz2))?$/ {print; exit}')
[[ -n $member ]] || die 'no data.tar inside the .deb'
ar p "$workdir/mullvad.deb" "$member" > "$workdir/$member"

list=$(tar -tf "$workdir/$member")
grep -Eq '(^/|(^|/)\.\.(/|$))' <<<"$list" && die 'archive contains unsafe paths'
grep -Ev '^\./$|^\./(usr|opt)(/|$)' <<<"$list" | grep -q . && die 'archive contains files outside /usr and /opt'

mkdir "$workdir/payload"
tar -xf "$workdir/$member" -C "$workdir/payload"
[[ -x $workdir/payload/usr/bin/mullvad-daemon ]] || die 'mullvad-daemon missing in package'
new_ver=$("$workdir/payload/usr/bin/mullvad" --version) || die 'mullvad CLI in package does not run'
echo "Package: $new_ver"

if (( dry )); then
    echo 'Dry run (-n): verified and unpacked, nothing installed.'
    exit 0
fi

service="$service_dir/mullvad"
sudo -v
if [[ -d $service ]]; then
    sudo sv -w 30 down "$service"
    trap 'sudo sv -w 30 up "$service" || true; cleanup' EXIT
fi

sudo rm -rf -- '/opt/Mullvad VPN'
sudo tar -xf "$workdir/$member" -C / \
    --no-same-owner --no-overwrite-dir --keep-directory-symlink
sudo chown root:root /usr/bin/mullvad-exclude
sudo chmod 4755 /usr/bin/mullvad-exclude

if [[ ! -d $service ]]; then
    echo 'Mullvad runit service missing, creating one now.'
    [[ ! -e $service && ! -L $service ]] || die "invalid service entry: $service"
    if [[ ! -f /etc/sv/mullvad/run ]]; then
        printf '%s\n' '#!/bin/sh' 'exec 2>&1' 'exec /usr/bin/mullvad-daemon -v --disable-stdout-timestamps' > "$workdir/run"
        sudo install -d -m 755 /etc/sv/mullvad
        sudo install -m 755 "$workdir/run" /etc/sv/mullvad/run
    fi
    sudo ln -s /etc/sv/mullvad "$service"
fi

for ((i = 0; i < 20; i++)); do
    sudo sv status "$service" >/dev/null 2>&1 && break
    sleep 1
done
sudo sv -w 30 up "$service"
sudo sv status "$service"

# nothing systemwide may end up owned by the user.
bad=$(find / /usr /usr/bin /usr/lib /usr/share /opt -maxdepth 0 ! -user root 2>/dev/null
      find /usr/bin/mullvad* '/opt/Mullvad VPN' ! -user root 2>/dev/null | head -5)
[[ -z $bad ]] || { echo 'WARNING: not owned by root:' >&2; echo "$bad" >&2; }

mullvad version
