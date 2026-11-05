#!/usr/bin/env bash
# Stage 2b: IronFlock baked into the image (master plan, section 3.4;
# WP-2.3). Fetches the pinned ironflock-init, checks its OpenPGP signature
# against device-init's bootstrap key (fingerprint pinned in
# profiles/base/versions), and runs `ironflock-init bake` on $ROOT: the
# verified agent of the production channel, Docker's daemon.json, the
# NetworkManager and dbus drop-ins and ironflock-init itself for enroll.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/.." && pwd)
# shellcheck source=build/lib.sh
. "$here/lib.sh"
: "${ROOT:?}" "${WORK:?}" "${OUT:?}" "${ARCH:?}" "${NAME:?}"
: "${IRONFLOCK_DL_BASE:?}" "${DEVICE_INIT_VERSION:?}" "${DEVICE_INIT_KEYRING_SHA256:?}"
require curl sqv

keyring=$src/profiles/base/keys/ironflock-bootstrap.asc
echo "$DEVICE_INIT_KEYRING_SHA256  $keyring" | sha256sum -c --quiet - ||
  die "$keyring is not the pinned bootstrap key (profiles/base/versions)"
dir=$WORK/device-init
rm -rf "$dir"
mkdir -p "$dir"
url=$IRONFLOCK_DL_BASE/device-init/linux/$ARCH/$DEVICE_INIT_VERSION/ironflock-init
for f in "" .asc; do
  curl -fsSL --proto '=https' --retry 5 --retry-all-errors -o "$dir/ironflock-init$f" "$url$f" ||
    die "cannot download $url$f"
done
signer=$(sqv --keyring "$keyring" "$dir/ironflock-init.asc" "$dir/ironflock-init") ||
  die "$url is not signed by the IronFlock bootstrap key"
chmod 0755 "$dir/ironflock-init"
log "ironflock-init $DEVICE_INIT_VERSION verified (signed by $signer)"

"$dir/ironflock-init" bake --root "$ROOT" --arch "$ARCH" --download-base "$IRONFLOCK_DL_BASE"
[ -f "$ROOT/usr/lib/ironflock/image.json" ] || die "ironflock-init bake wrote no image.json"
cp "$ROOT/usr/lib/ironflock/image.json" "$OUT/$NAME.ironflock.json"
log "baked: $(jq -r '"agent \(.agent_version), ironflock-init \(.init_version)"' "$ROOT/usr/lib/ironflock/image.json")"
