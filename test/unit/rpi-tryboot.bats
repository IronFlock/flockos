#!/usr/bin/env bats
# The Raspberry Pi's RAUC backend (WP-5.2): every command against fixture
# autoboot.txt files, a fake /chosen/bootloader device-tree node and a fake
# vcmailbox that records what it was asked.

repo="$BATS_TEST_DIRNAME/../.."
backend="$repo/targets/rpi-arm64/overlay/usr/lib/ironflockos/rpi-tryboot"

setup() {
  dir=$(mktemp -d)
  export IRONFLOCKOS_AUTOBOOT=$dir/autoboot.txt
  export IRONFLOCKOS_BOOTLOADER_DT=$dir/dt
  export IRONFLOCKOS_TRYBOOT_STATE=$dir/data/rauc/state
  export IRONFLOCKOS_VCMAILBOX=$dir/vcmailbox
  mkdir -p "$IRONFLOCKOS_BOOTLOADER_DT"
  printf '#!/bin/sh\necho "$*" >>%s/mailbox.log\n' "$dir" >"$IRONFLOCKOS_VCMAILBOX"
  chmod +x "$IRONFLOCKOS_VCMAILBOX"
  autoboot 2
  booted 2 0
}

teardown() { rm -rf "$dir"; }

# autoboot PRIMARY: the file as the image ships it (PRIMARY 2) or after a
# commit of slot B (PRIMARY 3).
autoboot() {
  local other=3
  [ "$1" = 2 ] || other=2
  printf '[all]\ntryboot_a_b=1\nboot_partition=%s\n[tryboot]\nboot_partition=%s\n' "$1" "$other" >"$IRONFLOCKOS_AUTOBOOT"
}
# booted PARTITION TRYBOOT: what the firmware reports, as 32-bit big-endian cells.
booted() {
  printf "\\x00\\x00\\x00\\x0$1" >"$IRONFLOCKOS_BOOTLOADER_DT/partition"
  printf "\\x00\\x00\\x00\\x0$2" >"$IRONFLOCKOS_BOOTLOADER_DT/tryboot"
}
section() { # section NAME: boot_partition of [NAME]
  awk -v s="[$1]" '/^\[.*\]$/ { in_s = ($0 == s); next } in_s && /^boot_partition=/ { sub(/^boot_partition=/, ""); print }' "$IRONFLOCKOS_AUTOBOOT"
}
mailbox() { cat "$dir/mailbox.log" 2>/dev/null || true; }
state() { sed -n "s/^$1=//p" "$IRONFLOCKOS_TRYBOOT_STATE" 2>/dev/null || true; }

@test "the image's autoboot.txt is what the backend writes for slot A" {
  run diff "$repo/targets/rpi-arm64/boot/autoboot.txt" "$IRONFLOCKOS_AUTOBOOT"
  [ "$status" -eq 0 ]
}

@test "get-primary reads [all] boot_partition" {
  run "$backend" get-primary
  [ "$status" -eq 0 ] && [ "$output" = A ]
  autoboot 3
  run "$backend" get-primary
  [ "$status" -eq 0 ] && [ "$output" = B ]
}

@test "get-primary fails on a missing or foreign autoboot.txt" {
  printf '[all]\nboot_partition=5\n' >"$IRONFLOCKOS_AUTOBOOT"
  run "$backend" get-primary
  [ "$status" -ne 0 ]
  rm "$IRONFLOCKOS_AUTOBOOT"
  run "$backend" get-primary
  [ "$status" -ne 0 ]
}

@test "get-current is the partition the firmware booted" {
  run "$backend" get-current
  [ "$status" -eq 0 ] && [ "$output" = A ]
  booted 3 1
  run "$backend" get-current
  [ "$status" -eq 0 ] && [ "$output" = B ]
}

@test "get-current fails without the firmware's device-tree node" {
  rm -r "$IRONFLOCKOS_BOOTLOADER_DT"
  run "$backend" get-current
  [ "$status" -ne 0 ]
  [[ "$output" == *"not started by the Raspberry Pi firmware"* ]]
}

@test "set-primary of the other slot arms one tryboot of it" {
  run "$backend" set-primary B
  [ "$status" -eq 0 ]
  [ "$(mailbox)" = "0x00038064 4 0 1" ]
  [ "$(section all)" = 2 ] && [ "$(section tryboot)" = 3 ]
  [ "$(state B)" = trying ]
  [ ! -e "$IRONFLOCKOS_AUTOBOOT.new" ]
}

@test "set-primary of the primary drops a pending tryboot" {
  run "$backend" set-primary A
  [ "$status" -eq 0 ]
  [ "$(mailbox)" = "0x00038064 4 0 0" ]
  [ "$(section all)" = 2 ]
}

@test "set-primary of the slot running from tryboot commits it" {
  booted 3 1
  run "$backend" set-primary B
  [ "$status" -eq 0 ]
  [ "$(section all)" = 3 ] && [ "$(section tryboot)" = 2 ]
  [ -z "$(mailbox)" ]
}

@test "get-state: the running slot is good, an unknown or tried one bad" {
  run "$backend" get-state A
  [ "$output" = good ]
  run "$backend" get-state B
  [ "$output" = bad ]
  "$backend" set-primary B
  run "$backend" get-state B
  [ "$output" = bad ]
  booted 3 1
  run "$backend" get-state B
  [ "$output" = good ]
}

@test "set-state good on the slot running from tryboot commits it" {
  "$backend" set-primary B
  booted 3 1
  run "$backend" set-state B good
  [ "$status" -eq 0 ]
  [ "$(section all)" = 3 ] && [ "$(section tryboot)" = 2 ]
  [ "$(state B)" = good ]
  # After the commit B boots without tryboot; A is still known good.
  booted 3 0
  run "$backend" get-primary
  [ "$output" = B ]
  run "$backend" get-state B
  [ "$output" = good ]
}

@test "set-state good on a slot that does not run changes nothing" {
  run "$backend" set-state B good
  [ "$status" -eq 0 ]
  [ -z "$(state B)" ]
  [ "$(section all)" = 2 ]
}

@test "set-state good on the primary that runs records it, nothing else" {
  run "$backend" set-state A good
  [ "$status" -eq 0 ]
  [ "$(state A)" = good ]
  [ "$(section all)" = 2 ] && [ -z "$(mailbox)" ]
}

@test "set-state bad on the other slot drops its tryboot" {
  "$backend" set-primary B
  run "$backend" set-state B bad
  [ "$status" -eq 0 ]
  [ "$(state B)" = bad ]
  [ "$(mailbox | tail -n 1)" = "0x00038064 4 0 0" ]
  [ "$(section all)" = 2 ]
}

@test "set-state bad on the primary hands the next boot to the running slot" {
  # B runs from tryboot and a new install targets A, the primary.
  booted 3 1
  run "$backend" set-state A bad
  [ "$status" -eq 0 ]
  [ "$(section all)" = 3 ]
  [ "$(state A)" = bad ]
}

@test "set-state bad refuses to strand the device on an untested slot" {
  run "$backend" set-state A bad
  [ "$status" -ne 0 ]
  [[ "$output" == *"only one known to boot"* ]]
  [ "$(section all)" = 2 ]
  [ -z "$(state A)" ]
}

@test "an update that fails to come up falls back and reads as bad" {
  # rauc install on A: the target B is marked bad, written, made primary.
  "$backend" set-state B bad
  "$backend" set-primary B
  # B panics; the next boot is A again, without tryboot.
  booted 2 0
  run "$backend" get-current
  [ "$output" = A ]
  run "$backend" get-state B
  [ "$output" = bad ]
  run "$backend" get-primary
  [ "$output" = A ]
}

@test "an update that comes up and is marked good stays" {
  "$backend" set-state B bad
  "$backend" set-primary B
  booted 3 1
  "$backend" set-state B good
  booted 3 0
  run "$backend" get-primary
  [ "$output" = B ]
  run "$backend" get-state B
  [ "$output" = good ]
}

@test "usage errors" {
  run "$backend"
  [ "$status" -ne 0 ]
  run "$backend" frobnicate
  [ "$status" -ne 0 ] && [[ "$output" == *"unknown command"* ]]
  run "$backend" set-primary C
  [ "$status" -ne 0 ] && [[ "$output" == *"unknown slot"* ]]
  run "$backend" set-state B maybe
  [ "$status" -ne 0 ]
  run "$backend" get-state
  [ "$status" -ne 0 ] && [[ "$output" == *"usage: rpi-tryboot get-state SLOT"* ]]
  run "$backend" get-primary A
  [ "$status" -ne 0 ]
}

cmdline_tool="$repo/targets/rpi-arm64/overlay/usr/lib/ironflockos/rpi-cmdline"

@test "rpi-cmdline points the bundle's cmdline.txt at slot B" {
  printf 'console=serial0,115200 console=tty1 root=PARTUUID=029565df-068d-4b3e-8d32-fc21d85f7d1e rootfstype=ext4 rootwait rw rauc.slot=A\n' >"$dir/cmdline.txt"
  run "$cmdline_tool" "$dir/cmdline.txt" 5c0ffee0-1234-4abc-8def-0123456789ab B
  [ "$status" -eq 0 ]
  [ "$(cat "$dir/cmdline.txt")" = "console=serial0,115200 console=tty1 root=PARTUUID=5c0ffee0-1234-4abc-8def-0123456789ab rootfstype=ext4 rootwait rw rauc.slot=B" ]
  [ "$(wc -l <"$dir/cmdline.txt")" -eq 1 ]
  [ ! -e "$dir/cmdline.txt.new" ]
}

@test "rpi-cmdline refuses what it cannot rewrite" {
  printf 'console=tty1 rootwait\n' >"$dir/cmdline.txt"
  run "$cmdline_tool" "$dir/cmdline.txt" 5c0ffee0-1234-4abc-8def-0123456789ab B
  [ "$status" -ne 0 ] && [[ "$output" == *"no root="* ]]
  printf 'root=PARTUUID=x rauc.slot=A\n' >"$dir/cmdline.txt"
  run "$cmdline_tool" "$dir/cmdline.txt" 'x y' B
  [ "$status" -ne 0 ]
  run "$cmdline_tool" "$dir/cmdline.txt" 5c0ffee0 C
  [ "$status" -ne 0 ]
  run "$cmdline_tool" "$dir/missing.txt" 5c0ffee0 B
  [ "$status" -ne 0 ]
  [ "$(cat "$dir/cmdline.txt")" = "root=PARTUUID=x rauc.slot=A" ]
}

@test "rauc-post-install needs the boot slot's root slot" {
  RAUC_SLOTS="0 1" RAUC_TARGET_SLOTS="1" RAUC_SLOT_CLASS_1=boot RAUC_SLOT_DEVICE_1=/dev/null \
    RAUC_SLOT_PARENT_1=rootfs.1 RAUC_SLOT_NAME_0=rootfs.0 RAUC_SLOT_DEVICE_0=/dev/null RAUC_SLOT_BOOTNAME_0=A \
    RAUC_MOUNT_PREFIX=$dir run sh "$repo/overlay/usr/lib/ironflockos/rauc-post-install"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no root slot 'rootfs.1'"* ]]
}

@test "rauc-post-install refuses a root slot of a boot slot that is not a block device" {
  RAUC_SLOTS="0 1" RAUC_TARGET_SLOTS="1" RAUC_SLOT_CLASS_1=boot RAUC_SLOT_DEVICE_1=/dev/null \
    RAUC_SLOT_PARENT_1=rootfs.1 RAUC_SLOT_NAME_0=rootfs.1 RAUC_SLOT_DEVICE_0=$dir/nope RAUC_SLOT_BOOTNAME_0=B \
    RAUC_MOUNT_PREFIX=$dir run sh "$repo/overlay/usr/lib/ironflockos/rauc-post-install"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not a block device"* ]]
}
