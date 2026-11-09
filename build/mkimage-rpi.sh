#!/usr/bin/env bash
# Stage 3 for the Raspberry Pi (master plan, sections 3.2 and 3.7; WP-5.1):
# the FLOCKOS partition (autoboot.txt), boot-a (the firmware's boot files of
# the tree, config.txt, cmdline.txt), an empty boot-b and slot A, assembled
# by genimage, compressed for FlockFlasher.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/.." && pwd)
# shellcheck source=build/lib.sh
. "$here/lib.sh"
: "${ROOT:?}" "${WORK:?}" "${OUT:?}" "${TARGET:?}" "${IMAGE_ID:?}" "${SLOT_SIZE:?}" "${NAME:?}" "${SOURCE_DATE_EPOCH:?}"
: "${FLOCKOS_SIZE:?}" "${BOOT_SIZE:?}" "${FAT_PART_TYPE:?}" "${ROOT_PART_TYPE:?}" "${CONSOLE_CMDLINE:?}"
require mkfs.vfat mmd mcopy mke2fs dumpe2fs genimage pigz
target_dir=$src/targets/$TARGET
img=$WORK/image
rm -rf "$img"
mkdir -p "$img/input" "$img/tmp" "$img/root"
export MTOOLS_SKIP_CHECK=1

# vfat FILE SIZE LABEL ID DIR: a FAT32 filesystem of SIZE holding DIR's tree.
vfat() {
  local file=$1 size=$2 label=$3 id=$4 dir=$5 entry
  mkfs.vfat -F 32 -n "$label" -i "$id" --invariant -C "$file" $(($(size_bytes "$size") / 1024)) >/dev/null
  for entry in "$dir"/* "$dir"/.[!.]*; do
    [ -e "$entry" ] || continue
    mcopy -i "$file" -s -m "$entry" ::/
  done
}
volid() { printf '%08x' $(((SOURCE_DATE_EPOCH + $1) & 0xffffffff)); }

root_a_uuid=$(uuid_for rootfs-a)

# --- boot-a: the firmware's files from the tree, and this slot's config ------
# They leave the root filesystem: /boot/firmware stays as an empty directory.
boot_dir=$img/boot-a
mkdir -p "$boot_dir"
mv "$ROOT/boot/firmware/"* "$boot_dir/"
SLOT=A render "$target_dir/boot/config.txt" >"$boot_dir/config.txt"
# cmdline.txt is one line (the unit tests keep the template so).
SLOT=A ROOT_PARTUUID=$root_a_uuid render "$target_dir/boot/cmdline.txt" >"$boot_dir/cmdline.txt"
find "$boot_dir" -exec touch --date="@$SOURCE_DATE_EPOCH" {} +
vfat "$img/input/boot-a.vfat" "$BOOT_SIZE" BOOT-A "$(volid 2)" "$boot_dir"

# --- FLOCKOS: autoboot.txt and the place for the .flock ----------------------
flockos_dir=$img/flockos
mkdir -p "$flockos_dir"
cp "$target_dir/boot/autoboot.txt" "$flockos_dir/autoboot.txt"
cat >"$flockos_dir/README.txt" <<'TXT'
IronFlockOS
===========

This is the FLOCKOS partition of a IronFlockOS disk. FlockFlasher puts the
device's .flock file here; on its first boot the device enrolls with it and
removes it from this partition.

Do not change autoboot.txt: it tells the Raspberry Pi firmware which boot
partition to start.
TXT
find "$flockos_dir" -exec touch --date="@$SOURCE_DATE_EPOCH" {} +
vfat "$img/input/flockos.vfat" "$FLOCKOS_SIZE" FLOCKOS "$(volid 1)" "$flockos_dir"

# --- slot A: ext4 of the full slot size from the tree ----------------------
rootfs=$img/input/rootfs.ext4
fs_uuid=$(uuid_for rootfs-fs)
E2FSPROGS_FAKE_TIME=$SOURCE_DATE_EPOCH mke2fs -q -t ext4 -L flockos-root -U "$fs_uuid" \
  -m 1 -E "root_owner=0:0,hash_seed=$fs_uuid,lazy_itable_init=0,lazy_journal_init=0" \
  -d "$ROOT" "$rootfs" "$SLOT_SIZE"
e2fsck -fn "$rootfs" >/dev/null || die "e2fsck found problems in the root filesystem image"
check_slot_fill "$rootfs" "$NAME"

# --- the disk image --------------------------------------------------------
IMAGE_NAME=$NAME.img
DISK_UUID=$(uuid_for disk)
FLOCKOS_UUID=$(uuid_for flockos)
BOOT_A_UUID=$(uuid_for boot-a)
BOOT_B_UUID=$(uuid_for boot-b)
ROOT_A_UUID=$root_a_uuid
export IMAGE_NAME DISK_UUID FLOCKOS_UUID BOOT_A_UUID BOOT_B_UUID ROOT_A_UUID
render "$target_dir/genimage.cfg" >"$img/genimage.cfg"
genimage --config "$img/genimage.cfg" --inputpath "$img/input" --outputpath "$img/output" \
  --tmppath "$img/tmp" --rootpath "$img/root" >/dev/null
disk=$img/output/$NAME.img
[ -f "$disk" ] || die "genimage made no $NAME.img"

pigz --no-name -6 -c "$disk" >"$OUT/$NAME.img.gz"
log "image: $(du -h --apparent-size "$disk" | cut -f1) raw, $(du -h "$OUT/$NAME.img.gz" | cut -f1) compressed"
