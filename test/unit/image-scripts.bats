#!/usr/bin/env bats
# The image's own scripts in overlay/usr/lib/flockos, run against a temporary
# directory instead of a device.

lib="$BATS_TEST_DIRNAME/../../overlay/usr/lib/flockos"

setup() { tmp=$(mktemp -d); }
teardown() { rm -rf "$tmp"; }

@test "data-layout creates the /data tree with private network profiles" {
  FLOCKOS_DATA=$tmp run sh "$lib/data-layout"
  [ "$status" -eq 0 ]
  for d in ironflock home cache fwupd pstore flockos rauc etc/ssh apps network/connections log/journal; do
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

@test "data-layout makes /data/apps, the apps' data, kept as it is" {
  FLOCKOS_DATA=$tmp run sh "$lib/data-layout"
  [ "$status" -eq 0 ]
  [ -d "$tmp/apps" ]
  mkdir -p "$tmp/apps/prod/my-app"
  echo kept >"$tmp/apps/prod/my-app/state"
  FLOCKOS_DATA=$tmp run sh "$lib/data-layout"
  [ "$status" -eq 0 ]
  [ "$(cat "$tmp/apps/prod/my-app/state")" = kept ]
}

@test "fstab: /apps is /data/apps, nofail, and Docker, the agent and enroll wait for it" {
  fstab=$BATS_TEST_DIRNAME/../../overlay/etc/fstab
  line=$(grep -E '^/data/apps +/apps +none ' "$fstab")
  opts=$(echo "$line" | awk '{ print $4 }')
  # A mount that fails does not stop the boot (the lifeline: the agent starts).
  [[ ",$opts," == *",nofail,"* ]]
  [[ ",$opts," == *",bind,"* ]]
  [[ ",$opts," == *",x-systemd.requires=flockos-data-layout.service,"* ]]
  # nofail drops the order before local-fs.target: whoever writes under /apps
  # is ordered after the mount itself.
  for unit in docker.service ironflock-device-agent.service flockos-enroll.service; do
    [[ ",$opts," == *",x-systemd.before=$unit,"* ]]
  done
  # Never required: a failed mount keeps nothing from starting.
  [[ "$opts" != *"x-systemd.required-by"* ]]
  ! grep -rqE '^(Requires|BindsTo|Requisite|RequiresMountsFor)=.*(apps\.mount|/apps)' "$BATS_TEST_DIRNAME/../../overlay"
  # The mount point is in the image.
  grep -q '"$ROOT/etc/NetworkManager/system-connections" "$ROOT/apps"' "$BATS_TEST_DIRNAME/../../build/customize.sh"
}

# apps_check: apps-check against $tmp/data and $tmp/apps.
apps_check() {
  FLOCKOS_APPS=$tmp/apps FLOCKOS_DATA=$tmp/data FLOCKOS_RUN=$tmp/run run sh "$lib/apps-check"
}

@test "apps-check: /apps bound from /data/apps passes quietly and clears an old mark" {
  mkdir -p "$tmp/data/apps" "$tmp/run"
  # A bind mount has the folder's device and inode; a link stands in here.
  ln -s "$tmp/data/apps" "$tmp/apps"
  echo old >"$tmp/run/apps-not-persistent"
  apps_check
  [ "$status" -eq 0 ]
  [[ "$output" == *"/apps is /data/apps"* ]]
  [ ! -e "$tmp/run/apps-not-persistent" ]
}

@test "apps-check: the slot's own /apps, or no /data/apps, fails loudly and leaves a mark, and changes nothing else" {
  mkdir -p "$tmp/data/apps" "$tmp/apps"
  apps_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"/apps is not /data/apps: the apps run, but their data is lost at the next OS update"* ]]
  grep -q 'is not /data/apps' "$tmp/run/apps-not-persistent"
  [ -z "$(ls -A "$tmp/apps")" ]
  rmdir "$tmp/data/apps"
  apps_check
  [ "$status" -eq 1 ]
  [ ! -e "$tmp/data/apps" ]
}

@test "apps-check's unit: after the mount, before Docker and the agent, which need nothing of it" {
  u=$BATS_TEST_DIRNAME/../../overlay/usr/lib/systemd/system/flockos-apps-check.service
  grep -qx 'After=apps.mount' "$u"
  grep -qx 'Before=docker.service ironflock-device-agent.service' "$u"
  grep -qx 'ExecStart=/usr/lib/flockos/apps-check' "$u"
  grep -qx 'StandardError=journal+console' "$u"
  ! grep -qE '^(Requires|BindsTo|Requisite|RequiredBy|OnFailure|FailureAction)=' "$u"
  # Enabled on devices, masked on the installer, whose fstab has no /apps.
  grep -qx '  systemctl --root="$ROOT" enable flockos-apps-check.service' "$BATS_TEST_DIRNAME/../../build/customize.sh"
  grep -qx '  systemctl --root="$ROOT" mask flockos-apps-check.service' "$BATS_TEST_DIRNAME/../../build/customize.sh"
  ! grep -q '/apps' "$BATS_TEST_DIRNAME/../../profiles/installer/overlay/etc/fstab"
}

# slot_proven BOOTED ENV...: slot-proven on a booted slot and a grubenv.
slot_proven() {
  mkdir -p "$tmp/bin"
  printf '#!/bin/sh\nprintf "%%s\\n" %s\n' "$(printf "'%s' " "${@:2}")" >"$tmp/bin/grub-editenv"
  chmod +x "$tmp/bin/grub-editenv"
  printf 'root=PARTUUID=x rauc.slot=%s rw\n' "$1" >"$tmp/cmdline"
  PATH="$tmp/bin:$PATH" FLOCKOS_GRUBENV=$tmp/grubenv FLOCKOS_PROC_CMDLINE=$tmp/cmdline \
    FLOCKOS_SLOT_PROVEN=$tmp/flockos/slot-proven run sh "$lib/slot-proven"
}

@test "slot-proven: a booted slot marked good has proven itself" {
  slot_proven B A_OK=1 A_TRY=1 B_OK=1 B_TRY=0
  [ "$status" -eq 0 ]
  [ -e "$tmp/flockos/slot-proven" ]
}

@test "slot-proven: a slot on trial has not, whatever the other slot's state" {
  slot_proven B A_OK=1 A_TRY=0 B_OK=1 B_TRY=1
  [ "$status" -eq 0 ]
  [ ! -e "$tmp/flockos/slot-proven" ]
}

@test "slot-proven: a slot that is not good has not" {
  slot_proven A A_OK=0 A_TRY=0 B_OK=1 B_TRY=0
  [ "$status" -eq 0 ]
  [ ! -e "$tmp/flockos/slot-proven" ]
}

@test "slot-proven: nothing without a booted slot on the command line" {
  mkdir -p "$tmp/bin"
  printf 'root=PARTUUID=x rw\n' >"$tmp/cmdline"
  FLOCKOS_GRUBENV=$tmp/grubenv FLOCKOS_PROC_CMDLINE=$tmp/cmdline \
    FLOCKOS_SLOT_PROVEN=$tmp/flockos/slot-proven run sh "$lib/slot-proven"
  [ "$status" -eq 0 ]
  [ ! -e "$tmp/flockos/slot-proven" ]
}

@test "fstab keeps kernel crash records on /data, so an update does not lose them" {
  grep -qE '^/data/pstore +/var/lib/systemd/pstore +none +bind,x-systemd.requires=flockos-data-layout.service' "$BATS_TEST_DIRNAME/../../overlay/etc/fstab"
}

@test "a failed kernel restarts by itself: an oops and a lockup count, on every target" {
  repo="$BATS_TEST_DIRNAME/../.."
  conf="$repo/overlay/etc/sysctl.d/60-flockos-crash-recovery.conf"
  for key in kernel.panic_on_oops kernel.softlockup_panic kernel.hardlockup_panic; do
    grep -qx "$key = 1" "$conf"
  done
  for boot in targets/amd64-efi/grub/grub.cfg targets/rpi-arm64/boot/cmdline.txt targets/jetson-orin/boot/extlinux.conf; do
    grep -qE '(^|[[:space:]])panic=10([[:space:]]|$)' "$repo/$boot"
  done
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

@test "enroll removes the other .flock files of the FLOCKOS partition once it has enrolled from one" {
  enroll_env
  echo old >"$tmp/esp/old.flock"
  touch -t 202001010000 "$tmp/esp/old.flock"
  echo new >"$tmp/esp/new.flock"
  run bash "$lib/enroll"
  [ "$status" -eq 0 ]
  [ "$(cat "$tmp/init-calls")" = "enroll -c $tmp/esp/new.flock --shred-source --hostname-from-flock" ]
  # The one it used is ironflock-init's to shred; the other would enroll the
  # device again at the next boot.
  [ ! -e "$tmp/esp/old.flock" ] && [ -e "$tmp/esp/new.flock" ]
  [[ "$output" == *"removed old.flock"* ]]
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
