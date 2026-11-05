#!/usr/bin/env bash
# The flash package of a jetson-orin image for an Orin on NVMe (WP-6.2 dry
# run, WP-6.4): NVIDIA's l4t_initrd_flash.sh --no-flash with FlockOS's
# partition layout and slot images, on the flashing host (x86_64 Ubuntu with
# the BSP's prerequisites, tools/l4t_flash_prerequisites.sh). No Jetson is
# needed: the board is named by its IDs (offline mode).
#   sudo tegra-flash-package.sh L4T_DIR SLOT_IMAGE BOARD BOARDID BOARDSKU
#
# L4T_DIR is the BSP's Linux_for_Tegra (build/fetch-bsp.sh), SLOT_IMAGE the
# build's <image-id>-<version>.rootfs.ext4.zst, BOARD an NVIDIA board config
# (jetson-orin-nano-devkit, jetson-agx-orin-devkit), BOARDID and BOARDSKU
# the module's (README_initrd_flash.txt: 3767 0003 is an Orin Nano 8GB).
#
# - the layout: build/tegra-layout.py from the BSP's NVMe rootfs A/B layout;
# - APP: the slot image, which boots slot A; APP_b: the same image pointed at
#   slot B (tegra-extlinux on its extlinux.conf, through debugfs);
# - their PARTUUIDs: the ones the image's extlinux.conf files name
#   (uuid_for rootfs-a and rootfs-b), through flash.sh's UUID files;
# - flash.sh reuses the slot images (-r) instead of building them from a
#   tree with the BSP's kernel and its own command line.
# The package lands in L4T_DIR/tools/kernel_flash/images.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/.." && pwd)
# shellcheck source=build/lib.sh
. "$here/lib.sh"

[ "$#" -eq 5 ] || die "usage: tegra-flash-package.sh L4T_DIR SLOT_IMAGE BOARD BOARDID BOARDSKU"
l4t=$(cd "$1" && pwd) slot_image=$2 board=$3 board_id=$4 board_sku=$5
[ "$(id -u)" = 0 ] || die "needs root (NVIDIA's flash tools mount and loop images)"
[ "$(uname -m)" = x86_64 ] || die "NVIDIA's flash tools run on x86_64 hosts"
[ -x "$l4t/tools/kernel_flash/l4t_initrd_flash.sh" ] || die "$l4t is not an unpacked BSP (no tools/kernel_flash/l4t_initrd_flash.sh)"
[ -f "$l4t/$board.conf" ] || die "the BSP has no board $board"
[[ "$board_id" =~ ^[0-9]{4}$ && "$board_sku" =~ ^[0-9]{4}$ ]] || die "BOARDID and BOARDSKU are four digits"
require zstd debugfs e2fsck python3
load_conf "$src/targets/jetson-orin/target.conf"
case "$(basename "$slot_image")" in
  flockos-jetson-orin-*-*.rootfs.ext4.zst) ;;
  *) die "$slot_image is not a jetson-orin slot image" ;;
esac
IMAGE_ID=$(basename "$slot_image" | sed -E 's/^(flockos-jetson-orin-[a-z]+(-rt)?)-[0-9].*$/\1/')
export IMAGE_ID
uuid_a=$(uuid_for rootfs-a)
uuid_b=$(uuid_for rootfs-b)
bl=$l4t/bootloader
kf=$l4t/tools/kernel_flash
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- layout ----------------------------------------------------------------
layout=$kf/flockos_t234_nvme_rootfs_ab.xml
python3 -I "$here/tegra-layout.py" "$kf/flash_l4t_t234_nvme_rootfs_ab.xml" "$layout"
log "layout: $layout"

# --- slot images: APP boots slot A, APP_b slot B ---------------------------
zstd -q -d -f -o "$bl/system.img.raw" "$slot_image"
e2fsck -fn "$bl/system.img.raw" >/dev/null || die "$slot_image is not a clean ext4"
ext=/boot/extlinux/extlinux.conf
debugfs -R "dump $ext $work/extlinux.conf" "$bl/system.img.raw" 2>/dev/null
grep -q " root=PARTUUID=$uuid_a " "$work/extlinux.conf" ||
  die "the slot image's extlinux.conf does not boot slot A ($uuid_a)"
cp --sparse=always "$bl/system.img.raw" "$bl/system.img_b.raw"
sh "$src/targets/jetson-orin/overlay/usr/lib/flockos/tegra-extlinux" "$work/extlinux.conf" "$uuid_b" B
debugfs -w -R "rm $ext" "$bl/system.img_b.raw" >/dev/null 2>&1
debugfs -w -R "write $work/extlinux.conf $ext" "$bl/system.img_b.raw" >/dev/null 2>&1
debugfs -R "cat $ext" "$bl/system.img_b.raw" 2>/dev/null | grep -q " root=PARTUUID=$uuid_b .*rauc.slot=B" ||
  die "APP_b's extlinux.conf does not boot slot B"
e2fsck -fn "$bl/system.img_b.raw" >/dev/null || die "APP_b's image is not a clean ext4 after the edit"
for s in system.img system.img_b; do
  (cd "$bl" && ./mksparse --fillpattern=0 "$s.raw" "$s") >/dev/null
done
log "slot images: APP ($uuid_a), APP_b ($uuid_b)"

# --- the slots' PARTUUIDs, as extlinux.conf names them --------------------
printf '%s\n' "$uuid_a" >"$bl/l4t-rootfs-uuid.txt_ext"
printf '%s\n' "$uuid_b" >"$bl/l4t-rootfs-uuid.txt_b_ext"

# --- the package -----------------------------------------------------------
slot_bytes=$(size_bytes "$SLOT_SIZE_BASE")
(
  cd "$l4t"
  # "-r 1": l4t_initrd_flash.func declares -r with an argument (getopts
  # "r:") though it takes none; without one, -r swallows the next option
  # and getopts stops at its value, dropping every option after it.
  BOARDID=$board_id BOARDSKU=$board_sku FAB=000 ROOTFS_AB=1 \
    ./tools/kernel_flash/l4t_initrd_flash.sh --no-flash \
    --external-device nvme0n1 -c "$layout" -S "$slot_bytes" \
    --external-only -r 1 "$board" external
)
log "flash package: $kf/images"
