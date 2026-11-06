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

@test "each EFI target brings its kernel and GRUB's environment tool" {
  for t in amd64-efi arm64-efi; do
    mapfile -t pkgs < <(read_list "$repo/targets/$t/packages")
    printf '%s\n' "${pkgs[@]}" | grep -q '^linux-image-'
    printf '%s\n' "${pkgs[@]}" | grep -qx grub-common
  done
  ! read_list "$repo/profiles/base/packages" "$repo/profiles/base/packages.amd64" "$repo/profiles/base/packages.arm64" | grep -q '^linux-image-'
}

@test "each EFI target brings Debian's signed boot chain of its architecture (ADR-0011)" {
  for t in amd64-efi arm64-efi; do
    (
      load_conf "$repo/targets/$t/target.conf"
      mapfile -t pkgs < <(read_list "$repo/targets/$t/packages")
      for p in shim-signed "shim-helpers-$ARCH-signed" "grub-efi-$ARCH-signed" "fwupd-$ARCH-signed"; do
        printf '%s\n' "${pkgs[@]}" | grep -qx "$p"
      done
      # The firmware's removable-media path is BOOT<arch>.EFI, and shim
      # starts grub<arch>.efi next to it.
      [ "$EFI_LOADER" = "BOOT${EFI_ARCH^^}.EFI" ]
    )
  done
  [ "$(load_conf "$repo/targets/amd64-efi/target.conf" && echo "$EFI_ARCH $GRUB_FORMAT")" = "x64 x86_64-efi" ]
  [ "$(load_conf "$repo/targets/arm64-efi/target.conf" && echo "$EFI_ARCH $GRUB_FORMAT")" = "aa64 arm64-efi" ]
}

@test "the disk image boots shim and Debian's GRUB, which finds the A/B script" {
  img=$repo/build/mkimage.sh
  # shim at the removable-media path, GRUB and MokManager next to it, from
  # the image's packages; no GRUB of the build's own, no shim fallback.
  grep -q 'shim=$ROOT/usr/lib/shim/shim$EFI_ARCH.efi.signed$' "$img"
  grep -q 'grub=$ROOT/usr/lib/grub/$GRUB_FORMAT-signed/grub$EFI_ARCH.efi.signed$' "$img"
  grep -q 'install -m 0644 "$shim" "$esp_dir/EFI/BOOT/$EFI_LOADER"$' "$img"
  grep -q 'install -m 0644 "$grub" "$esp_dir/EFI/BOOT/grub$EFI_ARCH.efi"$' "$img"
  ! grep -q 'grub-mkimage\|fb\$EFI_ARCH' "$img"
  ! read_list "$repo/build/builder-packages" "$repo/build/builder-packages.amd64" "$repo/build/builder-packages.arm64" | grep -q '^grub-efi-'
  # Debian's GRUB reads /EFI/debian/grub.cfg; it hands over to the A/B
  # script in /EFI/BOOT, whose ${prefix}/grubenv is RAUC's.
  stub=$(sed -n "/^cat >\"\$esp_dir\/EFI\/debian\/grub.cfg\" <<'CFG'$/,/^CFG$/p" "$img")
  [[ "$stub" == *$'\nset prefix=($root)/EFI/BOOT\nsource ${prefix}/grub.cfg\nCFG' ]]
  load_conf "$repo/targets/amd64-efi/target.conf"
  COMPATIBLE=x render "$repo/targets/amd64-efi/system.conf" | grep -qx 'grubenv=/boot/efi/EFI/BOOT/grubenv'
  grep -q 'load_env --file ${prefix}/grubenv' "$repo/targets/amd64-efi/grub/grub.cfg"
}

@test "the rt kernel is offered for base on the EFI targets only" {
  export FLOCKOS_VERSION=0.0.0 FLOCKOS_COMMIT=0 SOURCE_DATE_EPOCH=0
  run bash "$repo/build/build.sh" rpi-arm64 base rt
  [ "$status" -ne 0 ] && [[ "$output" == *"the rt kernel is built for the EFI targets only; rpi-arm64 boots with rpi"* ]]
  run bash "$repo/build/build.sh" amd64-efi nvidia rt
  [ "$status" -ne 0 ] && [[ "$output" == *"the rt kernel is built for the base variant only"* ]]
}

@test "GRUB's console and serial terminal are the one GRUB_SERIAL makes" {
  for t in amd64-efi arm64-efi; do
    out=$(load_conf "$repo/targets/$t/target.conf" && render "$repo/targets/$t/grub/grub.cfg")
    terminal=$(load_conf "$repo/targets/$t/target.conf" && echo "$GRUB_TERMINAL")
    echo "$out" | grep -qx "terminal_input console $terminal"
    echo "$out" | grep -qx "terminal_output console $terminal"
  done
  # GRUB names a port's terminal serial_<port>; com0 (unit 0) is also "serial".
  [ "$(load_conf "$repo/targets/amd64-efi/target.conf" && echo "$GRUB_TERMINAL")" = serial ]
  [ "$(load_conf "$repo/targets/arm64-efi/target.conf" && echo "$GRUB_SERIAL $GRUB_TERMINAL")" = "serial efi0 serial_efi0" ]
}
