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

@test "slot B has slot A's size on every variant" {
  for v in BASE NVIDIA; do
    var=SLOT_SIZE_$v
    SLOT_SIZE=${!var} run render "$repo/targets/amd64-efi/repart.d/30-rootfs-b.conf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SizeMinBytes=${!var}"* ]]
    [[ "$output" == *"SizeMaxBytes=${!var}"* ]]
  done
}

@test "the genimage layout gives slot A the slot size" {
  IMAGE_NAME=x.img DISK_UUID=u ESP_UUID=u ROOT_A_UUID=u ROOT_PART_TYPE=$ROOT_PART_TYPE SLOT_SIZE=4G \
    run render "$repo/targets/amd64-efi/genimage.cfg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"partition rootfs-a"* ]]
  [[ "$output" == *"size = 4G"* ]]
  [[ "$output" == *"partition FLOCKOS"* ]]
}
