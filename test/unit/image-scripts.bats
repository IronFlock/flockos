#!/usr/bin/env bats
# The image's own scripts in overlay/usr/lib/flockos, run against a temporary
# directory instead of a device.

lib="$BATS_TEST_DIRNAME/../../overlay/usr/lib/flockos"

setup() { tmp=$(mktemp -d); }
teardown() { rm -rf "$tmp"; }

@test "data-layout creates the /data tree with private network profiles" {
  FLOCKOS_DATA=$tmp run sh "$lib/data-layout"
  [ "$status" -eq 0 ]
  for d in ironflock home cache fwupd flockos rauc etc/ssh network/connections log/journal; do
    [ -d "$tmp/$d" ]
  done
  [ "$(stat -c %a "$tmp/network/connections")" = 700 ]
}

@test "data-layout is idempotent and keeps what is there" {
  FLOCKOS_DATA=$tmp sh "$lib/data-layout"
  echo keep >"$tmp/home/file"
  FLOCKOS_DATA=$tmp run sh "$lib/data-layout"
  [ "$status" -eq 0 ]
  [ "$(cat "$tmp/home/file")" = keep ]
}

@test "enroll without a .flock leaves the device unenrolled" {
  mkdir -p "$tmp/esp" "$tmp/state"
  FLOCKOS_ESP=$tmp/esp FLOCKOS_STATE=$tmp/state run bash "$lib/enroll"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stays unenrolled"* ]]
  [ ! -e "$tmp/state/enrolled" ]
}

@test "enroll runs the installer with the newest .flock, then removes it from the ESP" {
  mkdir -p "$tmp/esp" "$tmp/state"
  echo old >"$tmp/esp/old.flock"
  touch -d '2020-01-01' "$tmp/esp/old.flock"
  echo new >"$tmp/esp/new.flock"
  printf '#!/bin/bash\necho "installer -c $2: $(cat "$2")" >%s/ran\n' "$tmp" >"$tmp/installer.sh"
  FLOCKOS_ESP=$tmp/esp FLOCKOS_STATE=$tmp/state FLOCKOS_INSTALLER=$tmp/installer.sh run bash "$lib/enroll"
  [ "$status" -eq 0 ]
  [ "$(cat "$tmp/ran")" = "installer -c $tmp/state/enroll.flock: new" ]
  [ ! -e "$tmp/esp/new.flock" ]
  [ -e "$tmp/esp/old.flock" ]
  [ -e "$tmp/state/enrolled" ]
  [ "$(stat -c %a "$tmp/state/enroll.flock")" = 600 ]
}

@test "enroll refuses a plain-http installer" {
  mkdir -p "$tmp/esp" "$tmp/state"
  echo x >"$tmp/esp/a.flock"
  FLOCKOS_ESP=$tmp/esp FLOCKOS_STATE=$tmp/state FLOCKOS_INSTALLER=http://example.com/i.sh run bash "$lib/enroll"
  [ "$status" -ne 0 ]
  [ -e "$tmp/esp/a.flock" ]
}

@test "rauc-post-install ignores slots that are not root filesystems" {
  RAUC_TARGET_SLOTS="1" RAUC_SLOT_CLASS_1=efi RAUC_SLOT_DEVICE_1=/dev/null RAUC_MOUNT_PREFIX=$tmp \
    run sh "$lib/rauc-post-install"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "rauc-post-install refuses a slot device that is not a block device" {
  RAUC_TARGET_SLOTS="0" RAUC_SLOT_CLASS_0=rootfs RAUC_SLOT_DEVICE_0=$tmp/nope RAUC_MOUNT_PREFIX=$tmp \
    run sh "$lib/rauc-post-install"
  [ "$status" -ne 0 ]
}
