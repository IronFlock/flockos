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

# enroll runs a fake ironflock-init that records its arguments.
enroll_env() {
  mkdir -p "$tmp/esp" "$tmp/agent" "$tmp/state"
  printf '#!/bin/bash\necho "$*" >>%s/init-calls\n' "$tmp" >"$tmp/ironflock-init"
  chmod +x "$tmp/ironflock-init"
  export FLOCKOS_ESP=$tmp/esp FLOCKOS_AGENT_DIR=$tmp/agent FLOCKOS_STATE=$tmp/state \
    FLOCKOS_INIT=$tmp/ironflock-init FLOCKOS_ENROLL_CONF=$tmp/enroll.conf
}

@test "enroll without any .flock leaves the device unenrolled" {
  enroll_env
  run bash "$lib/enroll"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stays unenrolled"* ]]
  [ ! -e "$tmp/init-calls" ]
  [ ! -e "$tmp/state/enrolled" ]
}

@test "enroll uses the newest .flock on the FLOCKOS partition and shreds it" {
  enroll_env
  echo old >"$tmp/esp/old.flock"
  touch -d '2020-01-01' "$tmp/esp/old.flock"
  echo new >"$tmp/esp/new.flock"
  echo agent >"$tmp/agent/device-config.flock"
  run bash "$lib/enroll"
  [ "$status" -eq 0 ]
  [ "$(cat "$tmp/init-calls")" = "enroll -c $tmp/esp/new.flock --shred-source --hostname-from-flock" ]
  [ -s "$tmp/state/enrolled" ]
}

@test "enroll on a new slot uses the agent's own copy on /data" {
  enroll_env
  echo agent >"$tmp/agent/device-config.flock"
  run bash "$lib/enroll"
  [ "$status" -eq 0 ]
  [ "$(cat "$tmp/init-calls")" = "enroll -c $tmp/agent/device-config.flock --shred-source --hostname-from-flock" ]
}

@test "enroll keeps the hostname when enroll.conf says hostname-from-flock=no" {
  enroll_env
  echo x >"$tmp/esp/a.flock"
  printf '# this device keeps its name\nhostname-from-flock=no\n' >"$tmp/enroll.conf"
  run bash "$lib/enroll"
  [ "$status" -eq 0 ]
  [ "$(cat "$tmp/init-calls")" = "enroll -c $tmp/esp/a.flock --shred-source" ]
  printf 'hostname-from-flock=yes\n' >"$tmp/enroll.conf"
  rm "$tmp/init-calls"
  run bash "$lib/enroll"
  [[ "$(cat "$tmp/init-calls")" == *"--hostname-from-flock"* ]]
}

@test "enroll fails when ironflock-init fails, and does not mark the slot" {
  enroll_env
  echo x >"$tmp/esp/a.flock"
  printf '#!/bin/bash\nexit 3\n' >"$tmp/ironflock-init"
  run bash "$lib/enroll"
  [ "$status" -ne 0 ]
  [ ! -e "$tmp/state/enrolled" ]
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
