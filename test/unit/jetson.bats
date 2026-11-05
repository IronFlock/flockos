#!/usr/bin/env bats
# The jetson-orin target's root tree (WP-6.2; ADR-0008): its distribution,
# NVIDIA's repositories and key, the pins, the RAUC slots, and what the
# build refuses until the layout exists.

repo="$BATS_TEST_DIRNAME/../.."
t="$repo/targets/jetson-orin"

setup() {
  # shellcheck source=build/lib.sh
  . "$repo/build/lib.sh"
  load_conf "$t/target.conf"
}

@test "jetson-orin is arm64 on Ubuntu 24.04 with NVIDIA's boot chain" {
  [ "$ARCH" = arm64 ] && [ "$DISTRO" = ubuntu-noble ] && [ "$BOOTLOADER" = tegra ]
  [ -f "$repo/distros/$DISTRO/versions" ]
  [ -n "$SLOT_SIZE_BASE" ] && size_bytes "$SLOT_SIZE_BASE" >/dev/null
  [[ "$CONSOLE_CMDLINE" == *console=ttyTCU0,115200* ]]
}

@test "NVIDIA's apt key is the pinned one" {
  command -v gpg >/dev/null || skip "gpg is not installed"
  GNUPGHOME=$(mktemp -d)
  export GNUPGHOME
  fpr=$(gpg --show-keys --with-colons "$t/apt/jetson-ota-public.asc" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')
  rm -rf "$GNUPGHOME"
  [ "$fpr" = "$L4T_SIGNER_FINGERPRINT" ]
}

@test "the L4T pins belong to the BSP's release" {
  load_conf "$t/bsp.conf"
  [[ "$L4T_PACKAGE_VERSION" == "$L4T_VERSION-"* ]]
  [[ "$L4T_KERNEL_VERSION" == *"-tegra-$L4T_PACKAGE_VERSION" ]]
  [ "$L4T_SUITE" = "r${L4T_VERSION%.*}" ]
  [[ "$L4T_MIRROR" == https://* ]]
  [[ "$L4T_CONTAINER_TOOLKIT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ ]]
}

@test "the package list is Orin's L4T flavour, without what the build replaces" {
  mapfile -t pkgs < <(read_list "$t/packages")
  for p in nvidia-l4t-core nvidia-l4t-kernel nvidia-l4t-kernel-nvgpu nvidia-l4t-kernel-oot-modules \
    nvidia-l4t-initrd nvidia-l4t-cuda-nvgpu nvidia-l4t-bootloader-utils nvidia-container-toolkit; do
    printf '%s\n' "${pkgs[@]}" | grep -qx "$p"
  done
  ! printf '%s\n' "${pkgs[@]}" | grep -qE -- '-openrm$|^nvidia-l4t-(bootloader|extlinux|apt-source|configs)$|^linux-image-'
}

@test "mkrootfs pins every listed L4T package and keeps NVIDIA's archive below Ubuntu" {
  f=$repo/build/mkrootfs.sh
  grep -q 'pin "$name" "$L4T_KERNEL_VERSION"' "$f"
  grep -q 'pin "$name" "$L4T_PACKAGE_VERSION"' "$f"
  grep -q 'pin "$name" "$L4T_CONTAINER_TOOLKIT_VERSION"' "$f"
  grep -q 'Pin: origin %s\\nPin-Priority: 100' "$f"
  grep -q 'nv-l4t-disable-boot-fw-update-in-preinstall' "$f"
}

@test "RAUC: the custom backend over APP and APP_b" {
  run bash -c ". '$repo/build/lib.sh'; COMPATIBLE=flockos-jetson-orin-base render '$t/system.conf'"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'compatible=flockos-jetson-orin-base'
  printf '%s\n' "$output" | grep -qx 'bootloader=custom'
  printf '%s\n' "$output" | grep -A1 '^\[slot.rootfs.0\]' | grep -qx 'device=/dev/disk/by-partlabel/APP'
  printf '%s\n' "$output" | grep -A1 '^\[slot.rootfs.1\]' | grep -qx 'device=/dev/disk/by-partlabel/APP_b'
  [ ! -d "$t/repart.d" ]
}

@test "the build makes jetson-orin's root tree only, in the base variant" {
  export FLOCKOS_VERSION=0.0.0 FLOCKOS_COMMIT=0 SOURCE_DATE_EPOCH=0
  run bash "$repo/build/build.sh" jetson-orin base std
  [ "$status" -ne 0 ] && [[ "$output" == *"jetson-orin has no disk image yet"* ]]
  FLOCKOS_STAGES=rootfs run bash "$repo/build/build.sh" jetson-orin nvidia std
  [ "$status" -ne 0 ] && [[ "$output" == *"jetson-orin is built in the base variant only"* ]]
  FLOCKOS_STAGES=rootfs run bash "$repo/build/build.sh" jetson-orin base rt
  [ "$status" -ne 0 ] && [[ "$output" == *"the rt kernel is built for the EFI targets only"* ]]
}
