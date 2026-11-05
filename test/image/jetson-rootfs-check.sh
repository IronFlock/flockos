#!/usr/bin/env bash
# Checks of jetson-orin's root tree without a Jetson (WP-6.2): Ubuntu 24.04
# with NVIDIA's L4T packages at the pinned versions, FlockOS on top, and the
# tree's own binaries run in a chroot (native on an arm64 host). The tree is
# what `just rootfs jetson-orin base` leaves in FLOCKOS_WORK; the boot is a
# hardware check once the layout and flash package exist (WP-6.4, WP-6.6).
#   sudo test/image/jetson-rootfs-check.sh ROOT
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/../.." && pwd)
# shellcheck source=build/lib.sh
. "$src/build/lib.sh"
[ "$#" -eq 1 ] || {
  echo "usage: jetson-rootfs-check.sh ROOT" >&2
  exit 2
}
[ "$(id -u)" = 0 ] || {
  echo "jetson-rootfs-check: needs root (chroot)" >&2
  exit 2
}
[ "$(uname -m)" = aarch64 ] || {
  echo "jetson-rootfs-check: runs the tree's binaries in a chroot, so it needs an arm64 host" >&2
  exit 2
}
root=$(cd "$1" && pwd)
[ -d "$root/usr" ] || {
  echo "jetson-rootfs-check: $root is not a root tree" >&2
  exit 2
}
load_conf "$src/targets/jetson-orin/target.conf"
cleanup() {
  for m in "$root/dev" "$root/proc"; do
    ! mountpoint -q "$m" || umount "$m"
  done
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
version_of() { dpkg-query --admindir="$root/var/lib/dpkg" -W -f '${Version}' "$1" 2>/dev/null; }

# --- identity --------------------------------------------------------------
osr=$root/usr/lib/os-release
check "os-release names flockos-jetson-orin-base" grep -qx 'IMAGE_ID=flockos-jetson-orin-base' "$osr"
check "os-release: ID_LIKE is Ubuntu's" grep -qx 'ID_LIKE="ubuntu debian"' "$osr"
check "the distribution is Ubuntu 24.04" grep -qx 'DISTRIB_CODENAME=noble' "$root/etc/lsb-release"

# --- L4T at the pinned versions ---------------------------------------------
for p in nvidia-l4t-core nvidia-l4t-init nvidia-l4t-cuda nvidia-l4t-firmware nvidia-l4t-tools nvidia-l4t-bootloader-utils; do
  check "$p is $L4T_PACKAGE_VERSION" test "$(version_of "$p")" = "$L4T_PACKAGE_VERSION"
done
for p in nvidia-l4t-kernel nvidia-l4t-kernel-nvgpu nvidia-l4t-kernel-oot-modules nvidia-l4t-display-kernel; do
  check "$p is $L4T_KERNEL_VERSION" test "$(version_of "$p")" = "$L4T_KERNEL_VERSION"
done
check "nvidia-container-toolkit is $L4T_CONTAINER_TOOLKIT_VERSION" \
  test "$(version_of nvidia-container-toolkit)" = "$L4T_CONTAINER_TOOLKIT_VERSION"
installed() { dpkg-query --admindir="$root/var/lib/dpkg" -W -f '${db:Status-Abbrev} ${Package}\n' "$@" 2>/dev/null | awk '$1 == "ii" { print $2 }'; }
check "none of the L4T packages kept out (bootloader payloads, extlinux, desktop configs, apt source)" \
  test -z "$(installed nvidia-l4t-bootloader nvidia-l4t-extlinux nvidia-l4t-configs nvidia-l4t-apt-source)"
check "no Ubuntu kernel next to NVIDIA's" test -z "$(installed 'linux-image-*')"
check "the preinstall marker is gone" test ! -e "$root/opt/nvidia/l4t-packages/.nv-l4t-disable-boot-fw-update-in-preinstall"

# --- kernel ----------------------------------------------------------------
check "/boot/Image and /boot/initrd" bash -c "[ -s '$root/boot/Image' ] && [ -s '$root/boot/initrd' ]"
mapfile -t kvers < <(ls "$root/usr/lib/modules")
kver=${kvers[0]:-}
check "one kernel's modules: $kver" test "${#kvers[@]}" -eq 1
check "the GPU driver (nvgpu) for $kver" bash -c "compgen -G '$root/usr/lib/modules/$kver/updates/nvgpu.ko*'"
check "modules.dep is current" test -s "$root/usr/lib/modules/$kver/modules.dep"
ext=$root/boot/extlinux/extlinux.conf
check "extlinux.conf boots /boot/Image with /boot/initrd" \
  bash -c "grep -qE '^[[:space:]]+LINUX /boot/Image\$' '$ext' && grep -qE '^[[:space:]]+INITRD /boot/initrd\$' '$ext'"
check "extlinux.conf mounts slot A by PARTUUID and names it for RAUC" \
  bash -c "grep -E '^[[:space:]]+APPEND ' '$ext' | grep -E ' root=PARTUUID=[0-9a-f-]{36} ' | grep -q ' rauc.slot=A'"
check "tegra-extlinux is executable (rauc-post-install points written slots at themselves)" \
  test -x "$root/usr/lib/flockos/tegra-extlinux"

# --- apt -------------------------------------------------------------------
sl=$root/etc/apt/sources.list.d
check "sources: Ubuntu, Docker, NVIDIA's L4T" \
  bash -c "[ -f '$sl/ubuntu.sources' ] && [ -f '$sl/docker.sources' ] && [ -f '$sl/nvidia-l4t.sources' ] && [ ! -e '$sl/debian.sources' ]"
check "Ubuntu's sources are signed by ubuntu-archive-keyring" \
  grep -qx 'Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg' "$sl/ubuntu.sources"
check "the keyring is in the tree" test -s "$root/usr/share/keyrings/ubuntu-archive-keyring.gpg"
check "the L4T pins are kept" grep -q "Pin: version $L4T_PACKAGE_VERSION" "$root/etc/apt/preferences.d/flockos-l4t.pref"

# --- FlockOS ---------------------------------------------------------------
check "RAUC: compatible, the custom backend, APP and APP_b" \
  bash -c "c='$root/etc/rauc/system.conf'; grep -qx compatible=flockos-jetson-orin-base \$c && grep -qx bootloader=custom \$c && grep -qx device=/dev/disk/by-partlabel/APP \$c && grep -qx device=/dev/disk/by-partlabel/APP_b \$c"
check "no repart.d (NVIDIA's flash writes the layout)" test ! -e "$root/usr/lib/repart.d"
check "fstab: /boot/efi is NVIDIA's ESP, /data the layout's data partition" \
  bash -c "grep -q '^PARTLABEL=esp  *[/]boot[/]efi  *vfat ' '$root/etc/fstab' && grep -q '^PARTLABEL=data  *[/]data ' '$root/etc/fstab' && ! grep -q '^PARTLABEL=FLOCKOS' '$root/etc/fstab'"
for unit in flockos-ssh-hostkeys.service flockos-enroll.service ssh.service \
  docker.service NetworkManager.service systemd-timesyncd.service; do
  check "$unit is enabled" systemctl --root="$root" -q is-enabled "$unit"
done
check "no unit marks the slot good at boot (the device-agent does, once online)" \
  test ! -e "$root/usr/lib/systemd/system/flockos-mark-good.service"
for unit in rauc-mark-good.service nv-l4t-bootloader-config.service nv-rootfs-validation-config.service; do
  check "$unit is masked" bash -c "[ \"\$(systemctl --root='$root' is-enabled $unit)\" = masked ]"
done
check "the agent is baked in" test -x "$root/usr/lib/ironflock/device-agent"
check "Docker has the nvidia runtime" \
  jq -e '.runtimes.nvidia.path == "/usr/bin/nvidia-container-runtime"' "$root/etc/docker/daemon.json"
check "NVIDIA's container CSVs (the host files a GPU container gets)" \
  test -s "$root/etc/nvidia-container-runtime/host-files-for-container.d/drivers.csv"
# shellcheck disable=SC2016 # an awk program
check "no account has a password" awk -F: '$2 !~ /^[!*]/ { bad = 1 } END { exit bad }' "$root/etc/shadow"

# --- the tree's binaries, in a chroot ----------------------------------------
mount -t proc proc "$root/proc"
mount --bind /dev "$root/dev"
in_root() { chroot "$root" "$@"; }
check "chroot: dpkg reports nothing half-installed" bash -c "[ -z \"\$(chroot '$root' dpkg --audit)\" ]"
check "chroot: apt's dependencies hold" in_root apt-get check -qq
check "chroot: systemd runs" in_root /usr/bin/systemctl --version
check "chroot: Docker's CLI runs" in_root /usr/bin/docker --version
check "chroot: containerd runs" in_root /usr/bin/containerd --version
check "chroot: RAUC runs" in_root /usr/bin/rauc --version
check "chroot: ironflock-init runs" in_root /usr/sbin/ironflock-init version
check "chroot: nvidia-ctk runs" in_root /usr/bin/nvidia-ctk --version
check "chroot: nvidia-container-cli runs" in_root /usr/bin/nvidia-container-cli --version
check "nvbootctrl is there (the RAUC backend's tool, WP-6.3)" test -x "$root/usr/sbin/nvbootctrl"
check "chroot: the linker finds libnvidia-ml" bash -c "chroot '$root' ldconfig -p | grep -q 'libnvidia-ml.so.1 '"
# libcuda of both GPU flavours is under /opt/nvidia/l4t-gpu-libs; NVIDIA's
# nv-load-gpu-libs links the board's (nvgpu on Orin) into the linker's path
# and the container CSVs on each boot.
check "Orin's libcuda (nvgpu flavour)" test -f "$root/opt/nvidia/l4t-gpu-libs/nvgpu/libcuda.so.1.1"
check "nv-load-gpu-libs links it on boot" systemctl --root="$root" -q is-enabled nv-load-gpu-libs.service

echo
if [ "$fails" -eq 0 ]; then
  echo "jetson-rootfs-check: all checks passed"
else
  echo "jetson-rootfs-check: $fails checks failed"
  exit 1
fi
