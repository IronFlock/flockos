#!/usr/bin/env bash
# Build one FlockOS image inside the build container (master plan, section
# 3.3): rootfs (mmdebstrap), customisation, disk image (genimage), RAUC bundle.
#   build.sh TARGET VARIANT KERNEL
#
# Env (set by build/run-in-builder.sh): FLOCKOS_VERSION, FLOCKOS_COMMIT,
# FLOCKOS_DIRTY, SOURCE_DATE_EPOCH, FLOCKOS_SIGNING (dev|release),
# FLOCKOS_HOST_UID/GID (owner of the artefacts). /src is the repository
# (read-only), /work the scratch space, /out the artefact directory.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/.." && pwd)
# shellcheck source=build/lib.sh
. "$here/lib.sh"

[ "$#" -eq 3 ] || die "usage: build.sh TARGET VARIANT KERNEL"
TARGET=$1 VARIANT=$2 KERNEL=$3
valid_target "$TARGET" || die "unknown target $TARGET"
valid_variant "$VARIANT" || die "unknown variant $VARIANT"
valid_kernel "$KERNEL" || die "unknown kernel $KERNEL"
case "$VARIANT" in
  base) ;;
  nvidia) die "the nvidia variant arrives with Phase 4 (WP-4.1)" ;;
  installer) die "the installer variant arrives with Phase 3 (WP-3.2)" ;;
esac
[ "$KERNEL" = std ] || die "the rt kernel arrives with Phase 4b (WP-4b.1)"

: "${FLOCKOS_VERSION:?}" "${FLOCKOS_COMMIT:?}" "${SOURCE_DATE_EPOCH:?}"
FLOCKOS_DIRTY=${FLOCKOS_DIRTY:-}
FLOCKOS_SIGNING=${FLOCKOS_SIGNING:-dev}

load_conf "$src/targets/$TARGET/target.conf"
load_conf "$src/profiles/base/versions"
[ "$(dpkg --print-architecture)" = "$ARCH" ] || die "target $TARGET is $ARCH; this build container is $(dpkg --print-architecture)"

IMAGE_ID=$(image_id "$TARGET" "$VARIANT" "$KERNEL")
slot_var="SLOT_SIZE_${VARIANT^^}"
SLOT_SIZE=${!slot_var:?no $slot_var in target.conf}
NAME="$IMAGE_ID-$FLOCKOS_VERSION"
export TARGET VARIANT KERNEL ARCH IMAGE_ID SLOT_SIZE NAME

WORK=/work/$IMAGE_ID
OUT=/out/$IMAGE_ID
ROOT=$WORK/rootfs
rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT"
export WORK OUT ROOT

log "$NAME: signing keys ($FLOCKOS_SIGNING)"
bash "$here/signing.sh" "$WORK/pki"

log "$NAME: rootfs"
bash "$here/mkrootfs.sh"

log "$NAME: customisation"
bash "$here/customize.sh"

log "$NAME: disk image"
case "$BOOTLOADER" in
  grub-efi) bash "$here/mkimage.sh" ;;
  rpi) bash "$here/mkimage-rpi.sh" ;;
  *) die "unknown BOOTLOADER $BOOTLOADER in target.conf" ;;
esac

log "$NAME: RAUC bundle"
bash "$here/mkbundle.sh"

log "$NAME: checksums"
(
  cd "$OUT"
  sha256sum -- *.img.gz *.raucb >SHA256SUMS
  cat SHA256SUMS
)
chown -R "${FLOCKOS_HOST_UID:-0}:${FLOCKOS_HOST_GID:-0}" "$OUT"
log "$NAME: done"
ls -l "$OUT" >&2
