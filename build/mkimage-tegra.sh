#!/usr/bin/env bash
# Stage 3 on Jetson (BOOTLOADER=tegra; WP-6.2): slot A's filesystem image.
# NVIDIA's flash tools write the disk from the BSP (the partition layout from
# build/tegra-layout.py), so this stage makes what they take for a root
# slot: the ext4 of APP from $ROOT, whose extlinux.conf boots slot A. The
# flash package points a copy at slot B for APP_b (tegra-extlinux); the
# bundle stage puts it into the RAUC bundle.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=build/lib.sh
. "$here/lib.sh"
: "${ROOT:?}" "${WORK:?}" "${OUT:?}" "${IMAGE_ID:?}" "${SLOT_SIZE:?}" "${NAME:?}" "${SOURCE_DATE_EPOCH:?}"
require mke2fs e2fsck dumpe2fs zstd
img=$WORK/image
rm -rf "$img"
mkdir -p "$img/input"

grep -q "root=PARTUUID=$(uuid_for rootfs-a) " "$ROOT/boot/extlinux/extlinux.conf" ||
  die "extlinux.conf does not boot slot A ($(uuid_for rootfs-a))"

# --- slot A: ext4 of the full slot size from the tree ----------------------
# As on the EFI targets: metadata_csum_seed and orphan_file are left out,
# for the firmware's ext4 reader (L4TLauncher).
rootfs=$img/input/rootfs.ext4
fs_uuid=$(uuid_for rootfs-fs)
E2FSPROGS_FAKE_TIME=$SOURCE_DATE_EPOCH mke2fs -q -t ext4 -L flockos-root -U "$fs_uuid" \
  -O ^metadata_csum_seed,^orphan_file -m 1 \
  -E "root_owner=0:0,hash_seed=$fs_uuid,lazy_itable_init=0,lazy_journal_init=0" \
  -d "$ROOT" "$rootfs" "$SLOT_SIZE"
e2fsck -fn "$rootfs" >/dev/null || die "e2fsck found problems in the root filesystem image"
check_slot_fill "$rootfs" "$NAME"

# Keep rootfs.ext4 for the bundle stage; publish it compressed for the
# flash package.
zstd -q -T0 -10 -o "$OUT/$NAME.rootfs.ext4.zst" "$rootfs"
log "slot image: $(du -h --apparent-size "$rootfs" | cut -f1) raw, $(du -h "$OUT/$NAME.rootfs.ext4.zst" | cut -f1) compressed"
