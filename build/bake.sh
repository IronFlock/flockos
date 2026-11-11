#!/usr/bin/env bash
# Stage 2b: IronFlock baked into the image (master plan, section 3.4;
# WP-2.3; WP-5.1 of the CLI's plan). Fetches the pinned `ironflock`
# (IronFlock/ironflock-cli) from cli/ below the download base, checks its
# OpenPGP signature against the IronFlock bootstrap key (pinned in
# profiles/base/versions) as the CLI's install.sh does, and runs
# `ironflock bake` on $ROOT: the verified agent of the production channel,
# Docker's daemon.json, the NetworkManager and dbus drop-ins, and ironflock
# itself as /usr/bin/ironflock, which enrolls the device
# (overlay/usr/lib/ironflockos/enroll).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/.." && pwd)
# shellcheck source=build/lib.sh
. "$here/lib.sh"
: "${ROOT:?}" "${WORK:?}" "${OUT:?}" "${ARCH:?}" "${NAME:?}"
: "${IRONFLOCK_DL_BASE:?}" "${IRONFLOCK_VERSION:?}" "${IRONFLOCK_KEYRING_SHA256:?}"
require curl sqv

keyring=$src/profiles/base/keys/ironflock-bootstrap.asc
echo "$IRONFLOCK_KEYRING_SHA256  $keyring" | sha256sum -c --quiet - ||
  die "$keyring is not the pinned bootstrap key (profiles/base/versions)"
dir=$WORK/ironflock
rm -rf "$dir"
mkdir -p "$dir"
# The binary of the image's architecture: bake copies the binary that runs
# into the image.
url=$IRONFLOCK_DL_BASE/cli/linux/$ARCH/$IRONFLOCK_VERSION/ironflock
for f in "" .asc; do
  curl -fsSL --proto '=https' --retry 5 --retry-all-errors -o "$dir/ironflock$f" "$url$f" ||
    die "cannot download $url$f"
done
signer=$(sqv --keyring "$keyring" "$dir/ironflock.asc" "$dir/ironflock") ||
  die "$url is not signed by the IronFlock bootstrap key"
chmod 0755 "$dir/ironflock"
log "ironflock $IRONFLOCK_VERSION verified (signed by $signer)"

"$dir/ironflock" bake --root "$ROOT" --arch "$ARCH" --download-base "$IRONFLOCK_DL_BASE"
record=$ROOT/usr/lib/ironflock/image.json
[ -f "$record" ] || die "ironflock bake wrote no image.json"
[ -x "$ROOT/usr/bin/ironflock" ] || die "ironflock bake did not install /usr/bin/ironflock"
cmp -s "$dir/ironflock" "$ROOT/usr/bin/ironflock" || die "/usr/bin/ironflock is not the verified download"
baked=$(jq -r '.ironflock_version // empty' "$record")
[ "$baked" = "$IRONFLOCK_VERSION" ] ||
  die "image.json says ironflock_version '$baked', the pin is $IRONFLOCK_VERSION (profiles/base/versions)"
cp "$record" "$OUT/$NAME.ironflock.json"
log "baked: $(jq -r '"agent \(.agent_version), ironflock \(.ironflock_version)"' "$record")"
