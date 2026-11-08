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

@test "data-layout mirrors the slot's /var/log skeleton into /data/log, modes kept" {
  mkdir -p "$tmp/varlog/journal" "$tmp/varlog/private" "$tmp/varlog/apt"
  chmod 0700 "$tmp/varlog/private"
  echo old-image-log >"$tmp/varlog/apt/history.log"
  FLOCKOS_DATA=$tmp/data FLOCKOS_VAR_LOG=$tmp/varlog run sh "$lib/data-layout"
  [ "$status" -eq 0 ]
  for d in log/journal log/private log/apt; do
    [ -d "$tmp/data/$d" ]
  done
  [ "$(stat -c %a "$tmp/data/log/private")" = 700 ]
  # directories only: the image's own log files stay in the slot
  [ ! -e "$tmp/data/log/apt/history.log" ]
  # a later run keeps what /data/log holds and adds what a newer image brings
  echo kept >"$tmp/data/log/apt/term.log"
  mkdir -p "$tmp/varlog/newpkg"
  FLOCKOS_DATA=$tmp/data FLOCKOS_VAR_LOG=$tmp/varlog run sh "$lib/data-layout"
  [ "$status" -eq 0 ]
  [ "$(cat "$tmp/data/log/apt/term.log")" = kept ]
  [ -d "$tmp/data/log/newpkg" ]
}

@test "fstab puts all of /var/log on /data" {
  grep -qE '^/data/log +/var/log +none +bind,x-systemd.requires=flockos-data-layout.service' "$BATS_TEST_DIRNAME/../../overlay/etc/fstab"
  ! grep -q '/var/log/journal' "$BATS_TEST_DIRNAME/../../overlay/etc/fstab"
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

@test "fwupd-shim puts the booted shim where fwupd looks for it" {
  mkdir -p "$tmp/EFI/BOOT" "$tmp/EFI/debian"
  echo shim >"$tmp/EFI/BOOT/BOOTX64.EFI"
  FLOCKOS_ESP=$tmp run sh "$lib/fwupd-shim"
  [ "$status" -eq 0 ]
  cmp "$tmp/EFI/BOOT/BOOTX64.EFI" "$tmp/EFI/debian/shimx64.efi"
  [ ! -e "$tmp/EFI/debian/shimaa64.efi" ]
  [ ! -e "$tmp/EFI/debian/shimx64.efi.new" ]
}

@test "fwupd-shim covers arm64" {
  mkdir -p "$tmp/EFI/BOOT" "$tmp/EFI/debian"
  echo shim >"$tmp/EFI/BOOT/BOOTAA64.EFI"
  FLOCKOS_ESP=$tmp run sh "$lib/fwupd-shim"
  [ "$status" -eq 0 ]
  cmp "$tmp/EFI/BOOT/BOOTAA64.EFI" "$tmp/EFI/debian/shimaa64.efi"
}

@test "fwupd-shim replaces a stale copy and leaves a current one alone" {
  mkdir -p "$tmp/EFI/BOOT" "$tmp/EFI/debian"
  echo new >"$tmp/EFI/BOOT/BOOTX64.EFI"
  echo old >"$tmp/EFI/debian/shimx64.efi"
  FLOCKOS_ESP=$tmp run sh "$lib/fwupd-shim"
  [ "$status" -eq 0 ]
  cmp "$tmp/EFI/BOOT/BOOTX64.EFI" "$tmp/EFI/debian/shimx64.efi"
  touch -d @1000 "$tmp/EFI/debian/shimx64.efi"
  FLOCKOS_ESP=$tmp run sh "$lib/fwupd-shim"
  [ "$status" -eq 0 ]
  [ "$(stat -c %Y "$tmp/EFI/debian/shimx64.efi")" = 1000 ]
}

@test "fwupd-shim does nothing on a partition without the OS's folder" {
  mkdir -p "$tmp/EFI/BOOT"
  echo nvidia >"$tmp/EFI/BOOT/BOOTAA64.EFI"
  FLOCKOS_ESP=$tmp run sh "$lib/fwupd-shim"
  [ "$status" -eq 0 ]
  [ ! -e "$tmp/EFI/debian" ]
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
