#!/usr/bin/env bats
# The rpi-arm64 target (WP-5.1): its boot files, partition layout and the
# Raspberry Pi archive's key.

repo="$BATS_TEST_DIRNAME/../.."
t="$repo/targets/rpi-arm64"

setup() {
  # shellcheck source=build/lib.sh
  . "$repo/build/lib.sh"
  load_conf "$t/target.conf"
}

@test "cmdline.txt is one line that mounts the slot by PARTUUID and names it for RAUC" {
  [ "$(wc -l <"$t/boot/cmdline.txt")" -eq 1 ]
  run env SLOT=A ROOT_PARTUUID=0b1d0e5e-0000-4000-8000-000000000004 bash -c ". '$repo/build/lib.sh'; render '$t/boot/cmdline.txt'"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *"root=PARTUUID=0b1d0e5e-0000-4000-8000-000000000004 "* ]]
  [[ "$output" == *"rauc.slot=A"* ]]
  [[ "$output" == *"console=serial0,115200"* ]]
}

@test "config.txt is 64-bit with the model's initramfs and the UART" {
  run env SLOT=A bash -c ". '$repo/build/lib.sh'; render '$t/boot/config.txt'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"slot A"* ]]
  for want in arm_64bit=1 auto_initramfs=1 enable_uart=1; do
    printf '%s\n' "$output" | grep -qx "$want"
  done
}

@test "autoboot.txt boots boot-a, partition 2 of the genimage layout" {
  grep -qx 'boot_partition=2' "$t/boot/autoboot.txt"
  run env IMAGE_NAME=x.img DISK_UUID=d FLOCKOS_UUID=f BOOT_A_UUID=a BOOT_B_UUID=b ROOT_A_UUID=r \
    SLOT_SIZE=4G bash -c ". '$repo/build/lib.sh'; load_conf '$t/target.conf'; render '$t/genimage.cfg'"
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -v '^#' | grep -q '@[A-Z_]*@'
  order=$(printf '%s\n' "$output" | sed -n 's/^\tpartition \([^ ]*\) {$/\1/p' | tr '\n' ' ')
  [ "$order" = "FLOCKOS boot-a boot-b rootfs-a " ]
}

@test "repart.d matches the image's four partitions in order and adds rootfs-b and data" {
  labels=""
  for f in "$t"/repart.d/*.conf; do
    out=$(SLOT_SIZE=4G render "$f")
    labels="$labels $(printf '%s\n' "$out" | sed -n 's/^Label=//p')"
  done
  [ "$labels" = " FLOCKOS boot-a boot-b rootfs-a rootfs-b data" ]
}

@test "RAUC: the noop backend until WP-5.2, slots by GPT name" {
  run env COMPATIBLE=flockos-rpi-arm64-base bash -c ". '$repo/build/lib.sh'; render '$t/system.conf'"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'bootloader=noop'
  printf '%s\n' "$output" | grep -qx 'device=/dev/disk/by-partlabel/rootfs-a'
  printf '%s\n' "$output" | grep -qx 'use-bundle-signing-time=true'
}

@test "the Raspberry Pi archive key is the pinned one" {
  command -v gpg >/dev/null || skip "gpg is not installed"
  GNUPGHOME=$(mktemp -d)
  export GNUPGHOME
  fpr=$(gpg --show-keys --with-colons "$t/apt/raspberrypi.asc" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')
  rm -rf "$GNUPGHOME"
  [ "$fpr" = "$RPI_SIGNER_FINGERPRINT" ]
}

@test "the Pi brings both kernels and no GRUB" {
  mapfile -t pkgs < <(read_list "$t/packages")
  printf '%s\n' "${pkgs[@]}" | grep -qx linux-image-rpi-v8
  printf '%s\n' "${pkgs[@]}" | grep -qx linux-image-rpi-2712
  ! printf '%s\n' "${pkgs[@]}" | grep -q grub
}
