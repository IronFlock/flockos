#!/usr/bin/env bash
# Stage 3: the disk image (master plan, sections 3.2 and 3.3): the FLOCKOS
# partition (ESP with GRUB and its A/B script) and slot A (ext4 from $ROOT),
# assembled by genimage, compressed for FlockFlasher.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/.." && pwd)
# shellcheck source=build/lib.sh
. "$here/lib.sh"
: "${ROOT:?}" "${WORK:?}" "${OUT:?}" "${TARGET:?}" "${IMAGE_ID:?}" "${SLOT_SIZE:?}" "${NAME:?}" "${SOURCE_DATE_EPOCH:?}"
: "${GRUB_FORMAT:?}" "${EFI_LOADER:?}" "${ESP_SIZE:?}" "${ROOT_PART_TYPE:?}" "${CONSOLE_CMDLINE:?}" "${GRUB_SERIAL:?}" "${GRUB_TERMINAL:?}"
: "${ESP_PART_NAME:?}" "${ROOT_PART_NAME:?}"
require grub-mkimage grub-editenv mkfs.vfat mmd mcopy mke2fs dumpe2fs genimage pigz
target_dir=$src/targets/$TARGET
img=$WORK/image
rm -rf "$img"
mkdir -p "$img/input" "$img/tmp" "$img/root"

# --- GRUB: one EFI binary with its modules, the A/B script, grubenv ---------
esp_dir=$img/esp
mkdir -p "$esp_dir/EFI/BOOT"
grub-mkimage -O "$GRUB_FORMAT" -o "$esp_dir/EFI/BOOT/$EFI_LOADER" -p /EFI/BOOT \
  part_gpt part_msdos fat ext2 normal configfile linux loadenv test regexp probe \
  echo gzio serial terminal all_video search search_fs_uuid search_label \
  sleep reboot halt cat ls minicmd
render "$target_dir/grub/grub.cfg" >"$esp_dir/EFI/BOOT/grub.cfg"
grub-editenv "$esp_dir/EFI/BOOT/grubenv" create
grub-editenv "$esp_dir/EFI/BOOT/grubenv" set "ORDER=A B" A_OK=1 A_TRY=0 B_OK=0 B_TRY=0 FLOCKOS_CMDLINE=
cat >"$esp_dir/README.txt" <<'TXT'
FlockOS
=======

This is the FLOCKOS partition of a FlockOS disk. FlockFlasher puts the
device's .flock file here; on its first boot the device enrolls with it and
removes it from this partition.

Do not change the EFI folder: it holds the boot loader and its A/B state.
TXT
find "$esp_dir" -exec touch --date="@$SOURCE_DATE_EPOCH" {} +

esp=$img/input/esp.vfat
esp_kib=$(($(size_bytes "$ESP_SIZE") / 1024))
volid=$(printf '%08x' $((SOURCE_DATE_EPOCH & 0xffffffff)))
mkfs.vfat -F 32 -n FLOCKOS -i "$volid" --invariant -C "$esp" "$esp_kib" >/dev/null
export MTOOLS_SKIP_CHECK=1
mmd -i "$esp" ::/EFI ::/EFI/BOOT
mcopy -i "$esp" -m "$esp_dir/README.txt" ::/README.txt
mcopy -i "$esp" -m "$esp_dir/EFI/BOOT/$EFI_LOADER" "$esp_dir/EFI/BOOT/grub.cfg" "$esp_dir/EFI/BOOT/grubenv" ::/EFI/BOOT/

# --- slot A: ext4 of the full slot size from the tree ----------------------
# metadata_csum_seed and orphan_file are left out: GRUB has to read this
# filesystem.
rootfs=$img/input/rootfs.ext4
fs_uuid=$(uuid_for rootfs-fs)
E2FSPROGS_FAKE_TIME=$SOURCE_DATE_EPOCH mke2fs -q -t ext4 -L flockos-root -U "$fs_uuid" \
  -O ^metadata_csum_seed,^orphan_file -m 1 \
  -E "root_owner=0:0,hash_seed=$fs_uuid,lazy_itable_init=0,lazy_journal_init=0" \
  -d "$ROOT" "$rootfs" "$SLOT_SIZE"
e2fsck -fn "$rootfs" >/dev/null || die "e2fsck found problems in the root filesystem image"
check_slot_fill "$rootfs" "$NAME"

# --- the disk image --------------------------------------------------------
IMAGE_NAME=$NAME.img \
  DISK_UUID=$(uuid_for disk) ESP_UUID=$(uuid_for esp) ROOT_A_UUID=$(uuid_for rootfs-a) \
  ROOT_PART_TYPE=$ROOT_PART_TYPE SLOT_SIZE=$SLOT_SIZE \
  render "$target_dir/genimage.cfg" >"$img/genimage.cfg"
genimage --config "$img/genimage.cfg" --inputpath "$img/input" --outputpath "$img/output" \
  --tmppath "$img/tmp" --rootpath "$img/root" >/dev/null
disk=$img/output/$NAME.img
[ -f "$disk" ] || die "genimage made no $NAME.img"

# Keep rootfs.ext4 for the bundle stage; publish the compressed disk.
pigz --no-name -6 -c "$disk" >"$OUT/$NAME.img.gz"
log "image: $(du -h --apparent-size "$disk" | cut -f1) raw, $(du -h "$OUT/$NAME.img.gz" | cut -f1) compressed"
