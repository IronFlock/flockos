#!/usr/bin/env bash
# Stage 3: the disk image (master plan, sections 3.2 and 3.3): the IRONFLOCKOS
# partition (ESP with the boot chain and GRUB's A/B script) and slot A (ext4
# from $ROOT), assembled by genimage, compressed for FlockFlasher.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/.." && pwd)
# shellcheck source=build/lib.sh
. "$here/lib.sh"
: "${ROOT:?}" "${WORK:?}" "${OUT:?}" "${TARGET:?}" "${IMAGE_ID:?}" "${SLOT_SIZE:?}" "${NAME:?}" "${SOURCE_DATE_EPOCH:?}"
: "${GRUB_FORMAT:?}" "${EFI_ARCH:?}" "${EFI_LOADER:?}" "${ESP_SIZE:?}" "${ROOT_PART_TYPE:?}" "${CONSOLE_CMDLINE:?}" "${GRUB_SERIAL:?}" "${GRUB_TERMINAL:?}"
: "${ESP_PART_NAME:?}" "${ROOT_PART_NAME:?}"
require grub-editenv mkfs.vfat mmd mcopy mke2fs dumpe2fs genimage pigz
target_dir=$src/targets/$TARGET
img=$WORK/image
rm -rf "$img"
mkdir -p "$img/input" "$img/tmp" "$img/root"

# --- the boot chain: shim, GRUB, the A/B script, grubenv --------------------
# Secure Boot (ADR-0011): the firmware starts Debian's shim, which Microsoft
# signed, from the removable-media path, so no boot entry is needed. shim
# checks and starts Debian's signed GRUB next to it, and GRUB has shim check
# the kernel, which Debian signed too. With Secure Boot off the same chain
# boots without the checks. The binaries are the image's own packages
# (targets/<target>/packages), so packages.tsv and the SBOM list them.
# MokManager is there for shim to start when a check fails; shim's fallback
# (fb*.efi) is not: it would write boot entries and reboot.
esp_dir=$img/esp
mkdir -p "$esp_dir/EFI/BOOT" "$esp_dir/EFI/debian"
shim=$ROOT/usr/lib/shim/shim$EFI_ARCH.efi.signed
mok_manager=$ROOT/usr/lib/shim/mm$EFI_ARCH.efi.signed
grub=$ROOT/usr/lib/grub/$GRUB_FORMAT-signed/grub$EFI_ARCH.efi.signed
for f in "$shim" "$mok_manager" "$grub"; do
  [ -s "$f" ] || die "the image has no ${f#"$ROOT"} (targets/$TARGET/packages)"
done
install -m 0644 "$shim" "$esp_dir/EFI/BOOT/$EFI_LOADER"
install -m 0644 "$mok_manager" "$esp_dir/EFI/BOOT/mm$EFI_ARCH.efi"
install -m 0644 "$grub" "$esp_dir/EFI/BOOT/grub$EFI_ARCH.efi"
# Debian's signed GRUB has its modules built in. It reads the A/B script
# next to itself (/EFI/BOOT/grub.cfg, Debian's fw_path patch) before
# /EFI/debian/grub.cfg (its built-in prefix); that file sources the same
# script, for a GRUB without the patch. The script and grubenv stay in
# /EFI/BOOT, where RAUC's system.conf, rt-tuning and the devices flashed
# before ADR-0011 have them.
cat >"$esp_dir/EFI/debian/grub.cfg" <<'CFG'
# IronFlockOS: the A/B script is in /EFI/BOOT, next to the boot loader. Debian's
# GRUB reads it there first; this file is for a GRUB that reads only its
# prefix, /EFI/debian.
source ($root)/EFI/BOOT/grub.cfg
CFG
render "$target_dir/grub/grub.cfg" >"$esp_dir/EFI/BOOT/grub.cfg"
grub-editenv "$esp_dir/EFI/BOOT/grubenv" create
grub-editenv "$esp_dir/EFI/BOOT/grubenv" set "ORDER=A B" A_OK=1 A_TRY=0 B_OK=0 B_TRY=0 IRONFLOCKOS_CMDLINE=
# The installer talks to the person at the screen: it boots on text, as
# before the splash (docs/build.md, "The screen"). A device boots with the
# splash unless its display.conf says otherwise.
if [ "${VARIANT:?}" = installer ]; then
  grub-editenv "$esp_dir/EFI/BOOT/grubenv" set IRONFLOCKOS_BOOT=text
fi
# What GRUB draws at the start of the splash: the background colour (the
# theme's default, black) and no picture until a device has taken one from
# its screen. ironflockos-splash writes it from the device's splash.conf.
grub-editenv "$esp_dir/EFI/BOOT/splash.env" create
grub-editenv "$esp_dir/EFI/BOOT/splash.env" set "IRONFLOCKOS_SPLASH_BACKGROUND=#000000"
cat >"$esp_dir/README.txt" <<'TXT'
IronFlockOS
===========

This is the IRONFLOCKOS partition of an IronFlockOS disk. FlockFlasher puts the
device's .flock file here; on its first boot the device enrolls with it and
removes it from this partition.

Do not change the EFI folder: it holds the boot loader and its A/B state.
TXT
find "$esp_dir" -exec touch --date="@$SOURCE_DATE_EPOCH" {} +

esp=$img/input/esp.vfat
esp_kib=$(($(size_bytes "$ESP_SIZE") / 1024))
volid=$(printf '%08x' $((SOURCE_DATE_EPOCH & 0xffffffff)))
mkfs.vfat -F 32 -n IRONFLOCKOS -i "$volid" --invariant -C "$esp" "$esp_kib" >/dev/null
export MTOOLS_SKIP_CHECK=1
mmd -i "$esp" ::/EFI ::/EFI/BOOT ::/EFI/debian
mcopy -i "$esp" -m "$esp_dir/README.txt" ::/README.txt
mcopy -i "$esp" -m "$esp_dir/EFI/BOOT/$EFI_LOADER" "$esp_dir/EFI/BOOT/mm$EFI_ARCH.efi" "$esp_dir/EFI/BOOT/grub$EFI_ARCH.efi" \
  "$esp_dir/EFI/BOOT/grub.cfg" "$esp_dir/EFI/BOOT/grubenv" "$esp_dir/EFI/BOOT/splash.env" ::/EFI/BOOT/
mcopy -i "$esp" -m "$esp_dir/EFI/debian/grub.cfg" ::/EFI/debian/

# --- slot A: ext4 of the full slot size from the tree ----------------------
# metadata_csum_seed and orphan_file are left out: GRUB has to read this
# filesystem.
rootfs=$img/input/rootfs.ext4
fs_uuid=$(uuid_for rootfs-fs)
E2FSPROGS_FAKE_TIME=$SOURCE_DATE_EPOCH mke2fs -q -t ext4 -L ironflockos-root -U "$fs_uuid" \
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
# Its raw size and the smallest disk it becomes a device on, for the release
# catalog (tools/catalog). The installer makes no partitions.
repart_dir=$ROOT/usr/lib/repart.d
[ "${VARIANT:?}" != installer ] || repart_dir=""
write_sizes "$disk" "$repart_dir" "$OUT/$NAME.sizes"
