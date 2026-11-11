#!/usr/bin/env bash
# The flash package of a jetson-orin image for an Orin on NVMe (WP-6.2 dry
# run, WP-6.4): NVIDIA's l4t_initrd_flash.sh --no-flash with IronFlockOS's
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
#   tree with the BSP's kernel and its own command line;
# - L4T_DIR/rootfs holds slot A's tree, as NVIDIA's tools expect (flash.sh
#   reads the board's compatible spec from it).
# The package lands in L4T_DIR/tools/kernel_flash/images. The BSP's copy in
# L4T_DIR is changed: its rootfs, bootloader/system.img*, the UUID files, and
# a fix of the initrd flash scripts' -r option (see fix_reuse_option).
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
  ironflockos-jetson-orin-*-*.rootfs.ext4.zst) ;;
  *) die "$slot_image is not a jetson-orin slot image" ;;
esac
IMAGE_ID=$(basename "$slot_image" | sed -E 's/^(ironflockos-jetson-orin-[a-z]+(-rt)?)-[0-9].*$/\1/')
export IMAGE_ID
uuid_a=$(uuid_for rootfs-a)
uuid_b=$(uuid_for rootfs-b)
bl=$l4t/bootloader
kf=$l4t/tools/kernel_flash
work=$(mktemp -d)
trap 'umount "$work/mnt" "$l4t/rootfs/proc" "$l4t/rootfs/dev" 2>/dev/null || true; rm -rf "$work"' EXIT

# --- NVIDIA's -r option ----------------------------------------------------
# l4t_initrd_flash.func and l4t_create_images_for_kernel_flash.sh declare
# -r (reuse the system images) with an argument in their getopts strings,
# though it takes none: -r swallows the next option, getopts stops at that
# option's value, and every option after it is dropped (the layout and
# --external-only among them). fix_reuse_option FILE OLD NEW makes -r a
# flag; it fails where the BSP's string is not the known one.
fix_reuse_option() {
  local file=$l4t/tools/kernel_flash/$1
  if grep -qF "opstr+=\"$3\"" "$file"; then return 0; fi
  grep -qF "opstr+=\"$2\"" "$file" || die "$1: its getopts string is not the known one ($2); check -r before flashing"
  sed -i "s|opstr+=\"$2\"|opstr+=\"$3\"|" "$file"
}
fix_reuse_option l4t_initrd_flash.func "u:p:P:v:c:r:-:S:k:i:" "u:p:P:v:c:r-:S:k:i:"
fix_reuse_option l4t_create_images_for_kernel_flash.sh "k:u:p:v:c:r:-:S:i:" "k:u:p:v:c:r-:S:i:"

# --- layout ----------------------------------------------------------------
layout=$kf/ironflockos_t234_nvme_rootfs_ab.xml
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
sh "$src/targets/jetson-orin/overlay/usr/lib/ironflockos/tegra-extlinux" "$work/extlinux.conf" "$uuid_b" B
debugfs -w -R "rm $ext" "$bl/system.img_b.raw" >/dev/null 2>&1
debugfs -w -R "write $work/extlinux.conf $ext" "$bl/system.img_b.raw" >/dev/null 2>&1
debugfs -R "cat $ext" "$bl/system.img_b.raw" 2>/dev/null | grep -q " root=PARTUUID=$uuid_b .*rauc.slot=B" ||
  die "APP_b's extlinux.conf does not boot slot B"
e2fsck -fn "$bl/system.img_b.raw" >/dev/null || die "APP_b's image is not a clean ext4 after the edit"
for s in system.img system.img_b; do
  (cd "$bl" && ./mksparse --fillpattern=0 "$s.raw" "$s") >/dev/null
done
log "slot images: APP ($uuid_a), APP_b ($uuid_b)"

# --- the tree NVIDIA's tools read: slot A's --------------------------------
mkdir -p "$work/mnt"
mount -o loop,ro "$bl/system.img.raw" "$work/mnt"
rm -rf "$l4t/rootfs"
mkdir -p "$l4t/rootfs"
cp -a "$work/mnt/." "$l4t/rootfs/"
umount "$work/mnt"
[ -f "$l4t/rootfs/opt/nvidia/l4t-bootloader-config/nv-l4t-board-config.sh" ] ||
  die "slot A's tree has no nv-l4t-board-config.sh (nvidia-l4t-bootloader-utils)"

# --- what the flashing initrd takes from the tree --------------------------
# l4t_initrd_flash_internal.sh builds the initrd the Jetson flashes itself
# from with tools out of L4T_DIR/rootfs: flash_erase and mtd_debug
# (mtd-utils), file, partprobe (parted), nvluks-srv-app (nvidia-l4t-optee);
# flash.sh the recovery image's ramdisk (the fallback boot) with busybox,
# sfdisk (fdisk), sgdisk (gdisk), libnsl, libpcre and dhclient-script.
# The image never flashes itself and does not carry them; this copy of its
# tree gets them, from the image's own sources and pins, in a chroot through
# qemu-user (NVIDIA's prerequisites install it). The slot images stay as
# built (-r).
tree=$l4t/rootfs
mount --bind /dev "$tree/dev"
mount -t proc proc "$tree/proc"
rm -f "$tree/etc/resolv.conf"
cp -L /etc/resolv.conf "$tree/etc/resolv.conf"
mkdir -p "$tree/opt/nvidia/l4t-packages"
touch "$tree/opt/nvidia/l4t-packages/.nv-l4t-disable-boot-fw-update-in-preinstall"
chroot "$tree" apt-get -qq update
chroot "$tree" env DEBIAN_FRONTEND=noninteractive apt-get -y -qq install --no-install-recommends \
  mtd-utils file parted "nvidia-l4t-optee=$L4T_PACKAGE_VERSION" \
  busybox fdisk gdisk libnsl2 libpcre3 isc-dhcp-client >/dev/null
rm -f "$tree/opt/nvidia/l4t-packages/.nv-l4t-disable-boot-fw-update-in-preinstall"
umount "$tree/proc" "$tree/dev"
for f in usr/sbin/flash_erase usr/sbin/mtd_debug usr/bin/file sbin/partprobe usr/sbin/nvluks-srv-app \
  usr/bin/busybox usr/sbin/sfdisk usr/sbin/sgdisk usr/lib/aarch64-linux-gnu/libnsl.so.2 \
  usr/lib/aarch64-linux-gnu/libpcre.so.3 sbin/dhclient-script; do
  [ -e "$tree/$f" ] || die "the flashing initrd's $f is not in the tree"
done
log "the flashing initrd's and the recovery ramdisk's tools are in $tree"

# --- the slots' PARTUUIDs, as extlinux.conf names them --------------------
printf '%s\n' "$uuid_a" >"$bl/l4t-rootfs-uuid.txt_ext"
printf '%s\n' "$uuid_b" >"$bl/l4t-rootfs-uuid.txt_b_ext"

# --- the package -----------------------------------------------------------
slot_bytes=$(size_bytes "$SLOT_SIZE_BASE")
(
  cd "$l4t"
  BOARDID=$board_id BOARDSKU=$board_sku FAB=000 ROOTFS_AB=1 \
    ./tools/kernel_flash/l4t_initrd_flash.sh --no-flash -r \
    --external-device nvme0n1 -c "$layout" -S "$slot_bytes" \
    --external-only "$board" external
)
# --- what the package holds: IronFlockOS's layout -------------------------------
# flash.idx lists each partition: "<n>, <dev>:<name>, <start>, <size>, <file>,
# <file size>, <fixed|expand>-<reserved>-<gpt entry>, <sha1>".
idx=$kf/images/external/flash.idx
[ -f "$idx" ] || die "the package has no flash index ($idx)"
for slot in APP APP_b; do
  grep -qE "^[0-9]+, [0-9]+:[0-9]+:$slot, [0-9]+, $slot_bytes, " "$idx" ||
    die "the package's $slot is not $SLOT_SIZE_BASE ($slot_bytes bytes)"
done
grep -qE '^[0-9]+, [0-9]+:[0-9]+:data, [0-9]+, [0-9]+, , , expand-' "$idx" ||
  die "the package's data partition does not grow to the end of the disk"
grep -qx 'external_device=nvme0n1' "$kf/images/external/flash.cfg" ||
  die "the package does not flash nvme0n1"
log "flash package: $kf/images (APP and APP_b $SLOT_SIZE_BASE, data to the end of nvme0n1)"
