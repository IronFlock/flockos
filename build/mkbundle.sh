#!/usr/bin/env bash
# Stage 4: the RAUC bundle (master plan, section 3.5; ADR-0006): slot A's
# filesystem image in a verity bundle, compatible with this image only, signed
# with the build's signer: throwaway on pull requests; on releases a sealing
# key of this build, replaced by the Cloud KMS signature in release.yml's sign
# job (build/sign-bundles.sh), which the sealing CA next to the bundle lets
# it check first.
# On the Raspberry Pi the bundle also carries the boot partition (boot.vfat):
# RAUC writes both images of a slot group in one install (WP-5.2).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=build/lib.sh
. "$here/lib.sh"
: "${WORK:?}" "${OUT:?}" "${IMAGE_ID:?}" "${NAME:?}" "${IRONFLOCKOS_VERSION:?}" "${TARGET:?}" "${VARIANT:?}"
require rauc mksquashfs
# shellcheck disable=SC1091 # written by build/signing.sh
. "$WORK/pki/signing.env"

rootfs=$WORK/image/input/rootfs.ext4
[ -f "$rootfs" ] || die "no root filesystem image: run the image stage first"
build_id=$(sed -n 's/^BUILD_ID=//p' "$OUT/$NAME.os-release")

content=$WORK/bundle
rm -rf "$content"
mkdir -p "$content"
ln "$rootfs" "$content/rootfs.ext4" 2>/dev/null || cp --sparse=always "$rootfs" "$content/rootfs.ext4"
boot=$WORK/image/input/boot-a.vfat
boot_image=""
if [ -f "$boot" ]; then
  ln "$boot" "$content/boot.vfat" 2>/dev/null || cp "$boot" "$content/boot.vfat"
  boot_image=$'\n[image.boot]\nfilename=boot.vfat'
fi
cat >"$content/manifest.raucm" <<MANIFEST
[update]
compatible=$IMAGE_ID
version=$IRONFLOCKOS_VERSION
build=$build_id
description=IronFlockOS $IRONFLOCKOS_VERSION ($TARGET, $VARIANT)

[bundle]
format=verity

[image.rootfs]
filename=rootfs.ext4
$boot_image
MANIFEST

bundle=$OUT/$NAME.raucb
rm -f "$bundle"
rauc bundle --cert="$CERT" --key="$KEY" \
  --mksquashfs-args="-comp zstd -Xcompression-level 15 -b 1M" \
  "$content" "$bundle"

# Verify the way the device does: its keyring, the code-signing purpose and
# the signing time (system.conf); rauc's default purpose would be S/MIME.
cat >"$WORK/verify.conf" <<CONF
[system]
compatible=$IMAGE_ID
bootloader=noop

[keyring]
path=$BUNDLE_KEYRING
use-bundle-signing-time=true
check-purpose=codesign
CONF
rauc --conf="$WORK/verify.conf" info "$bundle" >"$WORK/bundle-info.txt"
grep -q "Compatible:.*'$IMAGE_ID'" "$WORK/bundle-info.txt" || {
  cat "$WORK/bundle-info.txt" >&2
  die "the bundle does not carry compatible $IMAGE_ID"
}
if [ "${SEALED:-0}" = 1 ]; then
  cp "$BUNDLE_KEYRING" "$OUT/$NAME.seal-ca.pem"
  log "bundle: $(du -h "$bundle" | cut -f1), sealed for the release signature (build/sign-bundles.sh)"
else
  log "bundle: $(du -h "$bundle" | cut -f1), signature verified against the image keyring"
fi
