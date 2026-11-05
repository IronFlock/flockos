#!/usr/bin/env bats
# Every EFI target loads, renders its templates without holes, and names the
# root partition type of its architecture (Discoverable Partitions
# Specification).

repo="$BATS_TEST_DIRNAME/../.."

setup() {
  # shellcheck source=build/lib.sh
  . "$repo/build/lib.sh"
}

@test "amd64-efi and arm64-efi render grub.cfg, system.conf and repart.d" {
  for t in amd64-efi arm64-efi; do
    (
      load_conf "$repo/targets/$t/target.conf"
      out=$(render "$repo/targets/$t/grub/grub.cfg")
      [[ "$out" != *"@"*"@"* ]]
      [[ "$out" == *"$CONSOLE_CMDLINE"* ]]
      COMPATIBLE=flockos-$t-base render "$repo/targets/$t/system.conf" | grep -qx "compatible=flockos-$t-base"
      for f in "$repo/targets/$t"/repart.d/*.conf; do
        SLOT_SIZE=$(size_bytes "$SLOT_SIZE_BASE") ESP_SIZE=$(size_bytes "$ESP_SIZE") render "$f" >/dev/null
      done
    )
  done
}

@test "the root slots have the root type of the target's architecture" {
  load_conf "$repo/targets/amd64-efi/target.conf"
  [ "$ARCH" = amd64 ] && [ "$ROOT_PART_TYPE" = 4f68bce3-e8cd-4db1-96e7-fbcaf984b709 ]
  load_conf "$repo/targets/arm64-efi/target.conf"
  [ "$ARCH" = arm64 ] && [ "$ROOT_PART_TYPE" = b921b045-1df0-41c3-af44-4c6f280d3fae ]
  [ "$EFI_LOADER" = BOOTAA64.EFI ] && [ "$GRUB_FORMAT" = arm64-efi ]
}

@test "arm64-efi shares amd64-efi's A/B files" {
  for f in grub/grub.cfg system.conf genimage.cfg repart.d; do
    [ "$(readlink -f "$repo/targets/arm64-efi/$f")" = "$(readlink -f "$repo/targets/amd64-efi/$f")" ]
  done
}

@test "arm64-efi has no nvidia slot size" {
  load_conf "$repo/targets/arm64-efi/target.conf"
  [ -z "${SLOT_SIZE_NVIDIA:-}" ]
}
