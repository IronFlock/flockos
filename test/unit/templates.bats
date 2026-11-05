#!/usr/bin/env bats
# Target templates render completely, and the GRUB script keeps the A/B
# contract RAUC's grub backend relies on.

repo="$BATS_TEST_DIRNAME/../.."

setup() {
  # shellcheck source=build/lib.sh
  . "$repo/build/lib.sh"
  load_conf "$repo/targets/amd64-efi/target.conf"
}

@test "grub.cfg renders without holes and passes the slot to RAUC" {
  run render "$repo/targets/amd64-efi/grub/grub.cfg"
  [ "$status" -eq 0 ]
  [[ "$output" != *"@"*"@"* ]]
  [[ "$output" == *"rauc.slot=\${slot}"* ]]
  [[ "$output" == *"save_env --file \${prefix}/grubenv A_TRY A_OK B_TRY B_OK ORDER"* ]]
  [[ "$output" == *"console=ttyS0,115200n8"* ]]
}

@test "system.conf names the slots by GPT name and uses verity bundles only" {
  COMPATIBLE=flockos-amd64-efi-base run render "$repo/targets/amd64-efi/system.conf"
  [ "$status" -eq 0 ]
  [[ "$output" == *"compatible=flockos-amd64-efi-base"* ]]
  [[ "$output" == *"device=/dev/disk/by-partlabel/rootfs-a"* ]]
  [[ "$output" == *"device=/dev/disk/by-partlabel/rootfs-b"* ]]
  [[ "$output" == *"bundle-formats=verity"* ]]
  [[ "$output" == *"use-bundle-signing-time=true"* ]]
}

@test "both slots have the variant's fixed size, the ESP its own; only /data grows" {
  for v in BASE NVIDIA; do
    var=SLOT_SIZE_$v
    for f in 20-rootfs-a 30-rootfs-b; do
      SLOT_SIZE=${!var} run render "$repo/targets/amd64-efi/repart.d/$f.conf"
      [ "$status" -eq 0 ]
      [[ "$output" == *"SizeMinBytes=${!var}"* ]]
      [[ "$output" == *"SizeMaxBytes=${!var}"* ]]
    done
  done
  run render "$repo/targets/amd64-efi/repart.d/10-esp.conf"
  [[ "$output" == *"SizeMaxBytes=$ESP_SIZE"* ]]
  ! grep -q SizeMaxBytes "$repo/targets/amd64-efi/repart.d/40-data.conf"
}

@test "the genimage layout gives slot A the slot size" {
  IMAGE_NAME=x.img DISK_UUID=u ESP_UUID=u ROOT_A_UUID=u ROOT_PART_TYPE=$ROOT_PART_TYPE SLOT_SIZE=4G \
    ESP_PART_NAME=FLOCKOS ROOT_PART_NAME=rootfs-a run render "$repo/targets/amd64-efi/genimage.cfg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"partition rootfs-a"* ]]
  [[ "$output" == *"size = 4G"* ]]
  [[ "$output" == *"partition FLOCKOS"* ]]
}

@test "the installer's partitions have names of their own" {
  run grep -c 'PARTLABEL=FLOCKOS\|PARTLABEL=rootfs' "$repo/profiles/installer/overlay/etc/fstab"
  [ "$output" = 0 ]
  grep -q 'PARTLABEL=flockos-installer-esp' "$repo/profiles/installer/overlay/etc/fstab"
  grep -q 'ESP_PART_NAME=flockos-installer-esp ROOT_PART_NAME=flockos-installer' "$repo/build/build.sh"
}
