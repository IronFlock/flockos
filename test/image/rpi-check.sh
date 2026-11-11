#!/usr/bin/env bash
# Checks of a built rpi-arm64 image without a Raspberry Pi (WP-5.1): the
# partition layout, autoboot.txt, the firmware's boot files and cmdline.txt
# of boot-a, and slot A's root filesystem, inspected read-only and through a
# chroot (native on an arm64 host). The boot itself is a hardware check
# (docs/testing.md).
#   sudo test/image/rpi-check.sh IMAGE.img.gz
set -euo pipefail
[ "$#" -eq 1 ] || {
  echo "usage: rpi-check.sh IMAGE.img.gz" >&2
  exit 2
}
[ "$(id -u)" = 0 ] || {
  echo "rpi-check: needs root (losetup, mount, chroot)" >&2
  exit 2
}
[ "$(uname -m)" = aarch64 ] || {
  echo "rpi-check: runs the image's binaries in a chroot, so it needs an arm64 host" >&2
  exit 2
}
image=$1
work=$(mktemp -d)
dev=""
cleanup() {
  for m in "$work/root/proc" "$work/root" "$work/boot" "$work/ironflockos"; do
    mountpoint -q "$m" && umount "$m"
  done
  [ -z "$dev" ] || losetup -d "$dev"
  rm -rf "$work"
}
trap cleanup EXIT
fails=0
ok() { printf 'ok   %s\n' "$*"; }
bad() {
  printf 'FAIL %s\n' "$*"
  fails=$((fails + 1))
}
check() { # check DESCRIPTION COMMAND...
  local what=$1
  shift
  if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi
}

gunzip -c "$image" >"$work/disk.img"
dev=$(losetup --find --show --partscan --read-only "$work/disk.img")
! command -v udevadm >/dev/null || udevadm settle || true

# --- layout (low-level probes: no udev needed) ------------------------------
probe() { blkid -p -o value -s "$2" "${dev}p$1" 2>/dev/null || true; }
layout=$(for n in 1 2 3 4; do echo "$n $(probe "$n" PART_ENTRY_NAME) $(probe "$n" TYPE)"; done)
want=$'1 IRONFLOCKOS vfat\n2 boot-a vfat\n3 boot-b \n4 rootfs-a ext4'
if [ "$layout" = "$want" ] && [ ! -e "${dev}p5" ]; then
  ok "GPT layout: IRONFLOCKOS, boot-a, boot-b (empty), rootfs-a"
else
  bad "GPT layout:"$'\n'"$layout"
fi
root_partuuid=$(probe 4 PART_ENTRY_UUID)

mkdir -p "$work/ironflockos" "$work/boot" "$work/root"
mount -o ro "${dev}p1" "$work/ironflockos"
mount -o ro "${dev}p2" "$work/boot"
mount -o ro "${dev}p4" "$work/root"

# --- IRONFLOCKOS ---------------------------------------------------------------
check "autoboot.txt: boot-a by default, boot-b on tryboot" \
  bash -c "[ \"\$(tr '\n' ' ' <'$work/ironflockos/autoboot.txt')\" = '[all] tryboot_a_b=1 boot_partition=2 [tryboot] boot_partition=3 ' ]"

# --- boot-a ----------------------------------------------------------------
for f in start4.elf fixup4.dat kernel8.img kernel_2712.img initramfs8 initramfs_2712 \
  bcm2711-rpi-4-b.dtb bcm2712-rpi-5-b.dtb overlays/vc4-kms-v3d.dtbo config.txt cmdline.txt; do
  check "boot-a has $f" test -s "$work/boot/$f"
done
check "config.txt: 64-bit, initramfs by model, UART" \
  bash -c "grep -qx arm_64bit=1 '$work/boot/config.txt' && grep -qx auto_initramfs=1 '$work/boot/config.txt' && grep -qx enable_uart=1 '$work/boot/config.txt'"
cmdline=$(cat "$work/boot/cmdline.txt")
check "cmdline.txt is one line" test "$(wc -l <"$work/boot/cmdline.txt")" -eq 1
check "cmdline.txt mounts slot A by PARTUUID ($root_partuuid)" grep -q "root=PARTUUID=$root_partuuid " <<<"$cmdline"
check "cmdline.txt names RAUC slot A" grep -q 'rauc.slot=A' <<<"$cmdline"
for k in kernel8.img:rpi-v8 kernel_2712.img:rpi-2712; do
  img=${k%%:*} flavour=${k#*:}
  kver=$(find "$work/root/boot" -maxdepth 1 -name "vmlinuz-*-$flavour" -printf '%f\n' | sed 's/^vmlinuz-//')
  check "$img is the tree's $flavour kernel ($kver)" cmp -s "$work/boot/$img" "$work/root/boot/vmlinuz-$kver"
  check "slot A has the modules of $kver" test -s "$work/root/usr/lib/modules/$kver/modules.dep"
done

# --- slot A ----------------------------------------------------------------
check "os-release names ironflockos-rpi-arm64-base" grep -qx 'IMAGE_ID=ironflockos-rpi-arm64-base' "$work/root/usr/lib/os-release"
check "/boot/firmware is empty in the slot (the files are on boot-a)" \
  bash -c "[ -d '$work/root/boot/firmware' ] && [ -z \"\$(ls -A '$work/root/boot/firmware')\" ]"
check "RAUC: compatible, the tryboot backend, boot partitions grouped with their root slots" \
  bash -c "c='$work/root/etc/rauc/system.conf'; grep -qx compatible=ironflockos-rpi-arm64-base \$c && grep -qx bootloader=custom \$c && grep -qx bootloader-custom-backend=/usr/lib/ironflockos/rpi-tryboot \$c && grep -qx parent=rootfs.0 \$c && grep -qx parent=rootfs.1 \$c"
for tool in rpi-tryboot rpi-cmdline rauc-post-install; do
  check "$tool is executable" test -x "$work/root/usr/lib/ironflockos/$tool"
done
check "the backend reads the image's autoboot.txt: slot A is primary" \
  bash -c "[ \"\$(IRONFLOCKOS_AUTOBOOT='$work/ironflockos/autoboot.txt' '$work/root/usr/lib/ironflockos/rpi-tryboot' get-primary)\" = A ]"
check "repart.d: rootfs-b and data come on the first boot" \
  test -f "$work/root/usr/lib/repart.d/60-data.conf"
check "fstab mounts IRONFLOCKOS and /data" bash -c "grep -q '^PARTLABEL=IRONFLOCKOS ' '$work/root/etc/fstab' && grep -q '^PARTLABEL=data ' '$work/root/etc/fstab'"
check "the apps' data is /data/apps, the mount point in the image" \
  bash -c "grep -q '^/data/apps  *[/]apps  *none  *bind,.*nofail' '$work/root/etc/fstab' && test -d '$work/root/apps'"
for unit in ironflockos-ssh-hostkeys.service ironflockos-enroll.service ssh.service \
  docker.service NetworkManager.service chrony.service ironflockos-ptp.service ironflockos-ptp.path \
  ironflockos-ptp4l.service ironflockos-phc2sys.service ironflockos-proxy.service ironflockos-proxy.path \
  ironflockos-apps-check.service ironflockos-network-profiles.service ironflockos-network-profiles-trial.service; do
  check "$unit is enabled" systemctl --root="$work/root" -q is-enabled "$unit"
done
check "chrony keeps the time, not systemd-timesyncd" test ! -e "$work/root/usr/lib/systemd/system/systemd-timesyncd.service"
check "a factory reset runs before /data is mounted, and no mount stops the boot (ADR-0015)" \
  bash -c "test -x '$work/root/usr/lib/ironflockos/factory-reset' && test -e '$work/root/usr/lib/systemd/system/data.mount.wants/ironflockos-factory-reset.service' && test -e '$work/root/usr/lib/systemd/system/data.mount.wants/ironflockos-data-missing.service' && ! grep -v '^#' '$work/root/etc/fstab' | grep . | grep -v nofail"
for setting in ptp.conf proxy.conf; do
  check "$setting is the device's, on /data" bash -c "[ \"\$(readlink '$work/root/etc/ironflockos/$setting')\" = /data/ironflockos/$setting ]"
done
check "rauc-mark-good is masked" bash -c "[ \"\$(systemctl --root='$work/root' is-enabled rauc-mark-good.service)\" = masked ]"
check "no unit marks the slot good at boot (the device-agent does, once online)" \
  test ! -e "$work/root/usr/lib/systemd/system/ironflockos-mark-good.service"
check "the agent is baked in" test -x "$work/root/usr/lib/ironflock/device-agent"
# shellcheck disable=SC2016 # an awk program
check "no account has a password" awk -F: '$2 !~ /^[!*]/ { bad = 1 } END { exit bad }' "$work/root/etc/shadow"

# The image's own binaries, in a chroot (the slot stays read-only).
mount -t proc proc "$work/root/proc"
in_root() { chroot "$work/root" "$@"; }
check "chroot: systemd runs" in_root /usr/bin/systemctl --version
check "chroot: Docker's CLI runs" in_root /usr/bin/docker --version
check "chroot: RAUC runs" in_root /usr/bin/rauc --version
check "rpi-eeprom-update is there" test -x "$work/root/usr/bin/rpi-eeprom-update"
check "chroot: ironflock-init runs" in_root /usr/sbin/ironflock-init version
check "chroot: the WiFi firmware has the Pi 4's NVRAM file" \
  bash -c "ls '$work/root/usr/lib/firmware/brcm/' | grep -q 'brcmfmac43455-sdio.raspberrypi,4-model-b'"

echo
if [ "$fails" -eq 0 ]; then
  echo "rpi-check: all checks passed"
else
  echo "rpi-check: $fails checks failed"
  exit 1
fi
