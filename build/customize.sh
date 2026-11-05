#!/usr/bin/env bash
# Stage 2: turn the Debian tree in $ROOT into FlockOS (master plan, sections
# 3.1, 3.2, 3.5, 3.9). Works on the tree from outside, without a chroot.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/.." && pwd)
# shellcheck source=build/lib.sh
. "$here/lib.sh"
: "${ROOT:?}" "${WORK:?}" "${OUT:?}" "${TARGET:?}" "${VARIANT:?}" "${KERNEL:?}" "${BOOTLOADER:?}"
: "${IMAGE_ID:?}" "${SLOT_SIZE:?}" "${NAME:?}" "${FLOCKOS_VERSION:?}" "${FLOCKOS_COMMIT:?}" "${SOURCE_DATE_EPOCH:?}"
target_dir=$src/targets/$TARGET
[ -d "$ROOT/usr" ] || die "$ROOT is not a root filesystem"

# copy_tree DIR: DIR's files into $ROOT, owned by root, modes as in git,
# existing directories untouched.
copy_tree() {
  tar -C "$1" --owner=0 --group=0 --numeric-owner -cf - . |
    tar -C "$ROOT" --no-overwrite-dir -xf -
}

# --- overlay ---------------------------------------------------------------
copy_tree "$src/overlay"
[ -d "$target_dir/overlay" ] && copy_tree "$target_dir/overlay"
[ "$VARIANT" != base ] && [ -d "$src/profiles/$VARIANT/overlay" ] && copy_tree "$src/profiles/$VARIANT/overlay"
[ "$KERNEL" = rt ] && copy_tree "$src/profiles/kernel-rt/overlay"

if [ "$VARIANT" != installer ]; then
  # --- RAUC ----------------------------------------------------------------
  # shellcheck disable=SC1091 # written by build/signing.sh
  . "$WORK/pki/signing.env"
  mkdir -p "$ROOT/etc/rauc"
  COMPATIBLE=$IMAGE_ID render "$target_dir/system.conf" >"$ROOT/etc/rauc/system.conf"
  install -m 0644 "$KEYRING" "$ROOT/etc/rauc/keyring.pem"

  # --- partitions created on the first boot (systemd-repart) ----------------
  # Not on Jetson: NVIDIA's flash tools write the whole layout.
  if [ -d "$target_dir/repart.d" ]; then
    mkdir -p "$ROOT/usr/lib/repart.d"
    for f in "$target_dir"/repart.d/*.conf; do
      render "$f" >"$ROOT/usr/lib/repart.d/$(basename "$f")"
    done
  fi
else
  # --- the installer: the images it writes, nothing of a device -------------
  # Each payload with its size (the installer checks the target disk by it).
  payload_dir=$ROOT/usr/share/flockos/payload
  mkdir -p "$payload_dir"
  for p in $FLOCKOS_INSTALLER_PAYLOADS; do
    base=flockos-$TARGET-$p-$FLOCKOS_VERSION
    pigz -dc "/out/flockos-$TARGET-$p/$base.img.gz" >"$WORK/payload.img"
    stat -c %s "$WORK/payload.img" >"$payload_dir/$base.img.zst.size"
    zstd -q -T0 -12 -o "$payload_dir/$base.img.zst" "$WORK/payload.img"
    rm -f "$WORK/payload.img"
    log "installer payload: $base ($(du -h "$payload_dir/$base.img.zst" | cut -f1))"
  done
fi

# --- identity --------------------------------------------------------------
commit=${FLOCKOS_COMMIT}
bash "$here/osrelease.sh" "$FLOCKOS_VERSION" "$TARGET" "$VARIANT" "$KERNEL" "${commit:0:12}" "$SOURCE_DATE_EPOCH" >"$ROOT/usr/lib/os-release"
if [ -n "${FLOCKOS_DIRTY:-}" ]; then
  sed -i 's/^BUILD_ID=\(.*\)$/BUILD_ID=\1-dirty/' "$ROOT/usr/lib/os-release"
fi
ln -sf ../usr/lib/os-release "$ROOT/etc/os-release"
# Every device generates its own machine-id on its first boot; RAUC's
# post-install handler carries it into the other slot.
printf 'uninitialized\n' >"$ROOT/etc/machine-id"
rm -f "$ROOT/var/lib/dbus/machine-id"
# SSH host keys are made per device, on /data (flockos-ssh-hostkeys.service).
rm -f "$ROOT"/etc/ssh/ssh_host_*

# --- accounts: no default user, root locked (section 3.9) ------------------
# Debian's base gives root no usable password ("*"); keep it that way.
sed -i 's/^root:[^:]*:/root:*:/' "$ROOT/etc/shadow"
if awk -F: '$1 != "root" && $3 >= 1000 && $3 < 60000 { found=1 } END { exit !found }' "$ROOT/etc/passwd"; then
  die "the image has a login account besides root"
fi

mapfile -t kernels < <(cd "$ROOT/boot" && ls vmlinuz-* 2>/dev/null)
case "$BOOTLOADER" in
  grub-efi)
    # --- kernel at a fixed path inside the slot (GRUB loads /vmlinuz) ------
    [ "${#kernels[@]}" -eq 1 ] || die "expected one kernel in /boot, found ${#kernels[@]}"
    kver=${kernels[0]#vmlinuz-}
    [ -f "$ROOT/boot/initrd.img-$kver" ] || die "no initramfs for kernel $kver"
    ln -sfn "boot/vmlinuz-$kver" "$ROOT/vmlinuz"
    ln -sfn "boot/initrd.img-$kver" "$ROOT/initrd.img"
    rm -f "$ROOT/vmlinuz.old" "$ROOT/initrd.img.old"
    ;;
  rpi)
    # --- the Pi firmware's boot files (build/mkimage-rpi.sh makes boot-a) --
    # What raspi-firmware's kernel and initramfs hooks put into
    # /boot/firmware, made here from the packages' files, so it does not
    # depend on the order dpkg configured them in: the firmware, both
    # kernels with their initramfs (kernel8.img for rpi-v8, kernel_2712.img
    # for rpi-2712), the device trees and the overlays.
    [ "${#kernels[@]}" -eq 2 ] || die "expected the rpi-v8 and rpi-2712 kernels in /boot, found ${#kernels[@]}"
    kver="${kernels[*]#vmlinuz-}"
    fw=$ROOT/boot/firmware
    rm -rf "$fw"
    mkdir -p "$fw/overlays"
    cp -r "$ROOT/usr/lib/raspi-firmware/." "$fw/"
    for k in "${kernels[@]}"; do
      v=${k#vmlinuz-}
      case "$v" in
        *-rpi-v8) suffix=8 ;;
        *-rpi-2712) suffix=_2712 ;;
        *) die "unexpected Pi kernel $v" ;;
      esac
      [ -f "$ROOT/boot/initrd.img-$v" ] || die "no initramfs for kernel $v"
      cp "$ROOT/boot/vmlinuz-$v" "$fw/kernel$suffix.img"
      cp "$ROOT/boot/initrd.img-$v" "$fw/initramfs$suffix"
      dtb=$ROOT/usr/lib/linux-image-$v
      cp "$dtb/broadcom/"bcm27*.dtb "$fw/"
      cp "$dtb/overlays/"*.dtb* "$dtb/overlays/README" "$fw/overlays/"
    done
    for f in start4.elf fixup4.dat kernel8.img kernel_2712.img initramfs8 initramfs_2712 \
      bcm2711-rpi-4-b.dtb bcm2711-rpi-400.dtb bcm2711-rpi-cm4.dtb bcm2712-rpi-5-b.dtb bcm2712-rpi-cm5-cm5io.dtb \
      overlays/vc4-kms-v3d.dtbo; do
      [ -s "$fw/$f" ] || die "the Pi boot files lack $f (/boot/firmware)"
    done
    ;;
  tegra)
    # --- NVIDIA's kernel and initrd, where L4TLauncher loads them ----------
    # nvidia-l4t-kernel installs /boot/Image, nvidia-l4t-initrd /boot/initrd;
    # extlinux.conf comes with the partition layout (WP-6.2).
    [ -s "$ROOT/boot/Image" ] || die "no /boot/Image (nvidia-l4t-kernel)"
    [ -s "$ROOT/boot/initrd" ] || die "no /boot/initrd (nvidia-l4t-initrd)"
    mapfile -t kvers < <(cd "$ROOT/usr/lib/modules" && ls)
    [ "${#kvers[@]}" -eq 1 ] || die "expected one kernel's modules, found: ${kvers[*]}"
    kver=${kvers[0]}
    [[ "$kver" == *-tegra ]] || die "unexpected kernel $kver: not NVIDIA's"
    compgen -G "$ROOT/usr/lib/modules/$kver/updates/nvgpu.ko*" >/dev/null ||
      die "no nvgpu module for $kver (nvidia-l4t-kernel-nvgpu)"
    [ ! -e "$ROOT/opt/nvidia/l4t-packages/.nv-l4t-disable-boot-fw-update-in-preinstall" ] ||
      die "the L4T preinstall marker is still in the tree"
    ;;
  *) die "unknown BOOTLOADER $BOOTLOADER in target.conf" ;;
esac

# --- mount points of /etc/fstab --------------------------------------------
mkdir -p "$ROOT/boot/efi" "$ROOT/data" "$ROOT/opt/ironflock" "$ROOT/var/cache/flockos" \
  "$ROOT/var/lib/fwupd" "$ROOT/var/log/journal" "$ROOT/etc/NetworkManager/system-connections"
chmod 0700 "$ROOT/etc/NetworkManager/system-connections"

# --- units -----------------------------------------------------------------
if [ "$VARIANT" = installer ]; then
  # The installer runs on the console and nothing else: no device services,
  # no /data, no slots, no SSH.
  systemctl --root="$ROOT" enable flockos-installer.service NetworkManager.service
  systemctl --root="$ROOT" disable flockos-ssh-hostkeys.service flockos-mark-good.service \
    flockos-enroll.service ssh.service docker.service containerd.service 2>/dev/null || true
  systemctl --root="$ROOT" mask flockos-enroll.service flockos-mark-good.service \
    flockos-ssh-hostkeys.service docker.service docker.socket containerd.service ssh.service \
    systemd-repart.service
else
  systemctl --root="$ROOT" enable flockos-ssh-hostkeys.service flockos-mark-good.service \
    flockos-enroll.service ssh.service docker.service NetworkManager.service systemd-timesyncd.service
  # The device's own enroll settings live on /data, so they outlive updates.
  mkdir -p "$ROOT/etc/flockos"
  ln -sfn /data/flockos/enroll.conf "$ROOT/etc/flockos/enroll.conf"
fi
if [ "$KERNEL" = rt ]; then
  systemctl --root="$ROOT" enable flockos-rt-tuning.service
  mkdir -p "$ROOT/etc/flockos"
  ln -sfn /data/flockos/rt.conf "$ROOT/etc/flockos/rt.conf"
fi
# Nothing changes the OS behind RAUC's back, nothing asks questions on the
# console, nothing fetches firmware metadata on its own (sections 3.9, 3.10).
# rauc-mark-good would mark every slot good at boot: the health gate is
# flockos-mark-good (Phase 1) and the device-agent (Phase 2). sshd-keygen
# would make host keys in /etc/ssh on every slot; they live on /data.
# NetworkManager owns the network: systemd-networkd and its wait unit would
# hold network-online.target for two minutes and fail.
systemctl --root="$ROOT" mask apt-daily.timer apt-daily-upgrade.timer fwupd-refresh.timer \
  systemd-firstboot.service rauc-mark-good.service sshd-keygen.service \
  systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service
# sshd listens on the network only; systemd's SSH generator (vsock, AF_UNIX)
# fails on machines without vsock.
mkdir -p "$ROOT/etc/systemd/system-generators"
ln -sfn /dev/null "$ROOT/etc/systemd/system-generators/systemd-ssh-generator"
if [ "$VARIANT" = installer ]; then
  systemctl --root="$ROOT" is-enabled flockos-installer.service >/dev/null || die "flockos-installer.service is not enabled"
else
  for unit in flockos-ssh-hostkeys.service flockos-mark-good.service flockos-enroll.service; do
    systemctl --root="$ROOT" is-enabled "$unit" >/dev/null || die "$unit is not enabled"
  done
  [ -f "$ROOT/usr/share/dbus-1/system-services/de.pengutronix.rauc.service" ] ||
    die "RAUC's D-Bus service is missing (package rauc-service)"
fi
if [ "$VARIANT" = nvidia ]; then
  # nvidia-persistenced fails without a GPU: udev starts it where the nvidia
  # module loads (71-flockos-nvidia.rules). nvidia-powerd is for notebooks.
  # 10-flockos-nvidia.preset keeps both off on each slot's first boot.
  systemctl --root="$ROOT" disable nvidia-persistenced.service nvidia-powerd.service
  compgen -G "$ROOT/usr/lib/modules/$kver/updates/nvidia/nvidia.ko*" >/dev/null ||
    die "no NVIDIA kernel module for $kver in the image"
  [ -x "$ROOT/usr/bin/nvidia-container-runtime" ] || die "nvidia-container-runtime is missing"
fi
if [ "$BOOTLOADER" = tegra ]; then
  # NVIDIA's boot-time services stay off: nv-l4t-bootloader-config updates
  # the QSPI firmware on its own (FlockOS's lane 2 does, WP-6.5), and
  # nv-rootfs-validation-config marks the root slot good (FlockOS's health
  # gate does, WP-6.3). NVIDIA puts the units into /etc/systemd/system, where
  # the mask goes: the files make way (/opt/nvidia keeps NVIDIA's copies).
  for u in nv-l4t-bootloader-config.service nv-rootfs-validation-config.service; do
    rm -f "$ROOT/etc/systemd/system/$u" "$ROOT/etc/systemd/system/multi-user.target.wants/$u"
  done
  systemctl --root="$ROOT" mask nv-l4t-bootloader-config.service nv-rootfs-validation-config.service
  [ -x "$ROOT/usr/bin/nvidia-container-runtime" ] || die "nvidia-container-runtime is missing"
fi

# --- IronFlock: the agent and the host defaults, by device-init ----------
# The installer writes devices; it is not one.
if [ "$VARIANT" != installer ]; then
  bash "$here/bake.sh"
fi
if [ "$VARIANT" = nvidia ]; then
  # bake adds the nvidia runtime where nvidia-container-runtime exists.
  jq -e '.runtimes.nvidia.path == "/usr/bin/nvidia-container-runtime"' "$ROOT/etc/docker/daemon.json" >/dev/null ||
    die "daemon.json has no nvidia runtime"
fi

# --- record what is in the image, then clean ------------------------------
dpkg-query --admindir="$ROOT/var/lib/dpkg" -W -f '${Package}\t${Version}\t${Architecture}\n' |
  sort >"$OUT/$NAME.packages.tsv"
cp "$ROOT/usr/lib/os-release" "$OUT/$NAME.os-release"
rm -rf "$ROOT"/var/lib/apt/lists/* "$ROOT"/var/cache/apt/*.bin "$ROOT"/var/cache/apt/archives/*.deb
rm -rf "$ROOT"/tmp/* "$ROOT"/var/tmp/* "$ROOT"/var/log/*.log "$ROOT"/var/log/apt/*
rm -f "$ROOT/etc/resolv.conf"
# NetworkManager writes resolv.conf on the device.
ln -sfn ../run/NetworkManager/resolv.conf "$ROOT/etc/resolv.conf"

# Reproducible timestamps: nothing newer than the commit.
find "$ROOT" -xdev -newermt "@$SOURCE_DATE_EPOCH" -print0 |
  xargs -0r touch --no-dereference --date="@$SOURCE_DATE_EPOCH"

log "customised: kernel $kver, $(wc -l <"$OUT/$NAME.packages.tsv") packages, $(du -sh --apparent-size "$ROOT" | cut -f1)"
