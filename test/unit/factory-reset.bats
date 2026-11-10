#!/usr/bin/env bats
# Factory reset (docs/build.md, "Factory reset"; ADR-0015): requested by
# factory-reset.conf on the FLOCKOS partition, run at boot before /data is
# mounted, against a fake device: folders stand for the data partition and the
# root slots, fakes for mount, mkfs.ext4, lsblk and grub-editenv. A fake can
# kill the reset at its n-th call, as a power loss would.

repo="$BATS_TEST_DIRNAME/../.."
reset="$repo/overlay/usr/lib/flockos/factory-reset"
units="$repo/overlay/usr/lib/systemd/system"

setup() {
  tmp=$(mktemp -d)
  export T=$tmp
  mkdir -p "$tmp/bin" "$tmp/dev"
  for d in data rootfs-a rootfs-b; do : >"$tmp/dev/$d"; done
  fakes
  device
  export PATH="$tmp/bin:$PATH" FLOCKOS_ESP=$tmp/esp FLOCKOS_ROOT=$tmp/disk/rootfs-a \
    FLOCKOS_ROOT_DEV=$tmp/dev/rootfs-a FLOCKOS_SYSTEM_CONF=$tmp/system.conf \
    FLOCKOS_PROC_CMDLINE=$tmp/cmdline FLOCKOS_DATA_DEV=$tmp/dev/data FLOCKOS_RUN=$tmp/run \
    FLOCKOS_BOOTLOADER_DT=$tmp/dt FLOCKOS_RESET_WAIT=0
  slot=$tmp/disk/rootfs-a other=$tmp/disk/rootfs-b data=$tmp/disk/data esp=$tmp/esp
}

teardown() { rm -rf "$tmp"; }

# The fakes. hook.sh counts the calls that change something; the
# FAKE_KILL_AT-th kills the reset after (or, for mkfs.ext4, halfway through)
# its work.
fakes() {
  cat >"$tmp/bin/hook.sh" <<'SH'
n=$(($(cat "$T/count" 2>/dev/null || echo 0) + 1))
echo "$n" >"$T/count"
killing=no
if [ "${FAKE_KILL_AT:-0}" = "$n" ]; then killing=yes; fi
power_loss() {
  kill -9 "$PPID"
  exit 137
}
SH
  # mount [-t TYPE] [-o OPTIONS] DEVICE DIR: DIR becomes a link to the folder
  # that stands for DEVICE; a "broken-<device>" file makes it fail.
  cat >"$tmp/bin/mount" <<'SH'
#!/bin/bash
opts="" args=()
while [ $# -gt 0 ]; do
  case "$1" in -t) shift ;; -o) opts=$2; shift ;; *) args+=("$1") ;; esac
  shift
done
dev=$(basename "${args[0]}") dir=${args[1]}
echo "mount $opts $dev" >>"$T/calls"
if [ -e "$T/broken-$dev" ] || [ ! -d "$T/disk/$dev" ]; then exit 32; fi
. "$T/bin/hook.sh"
rmdir "$dir" && ln -s "$T/disk/$dev" "$dir"
[ "$killing" = no ] || power_loss
SH
  cat >"$tmp/bin/umount" <<'SH'
#!/bin/bash
dir=${!#}
[ -L "$dir" ] || exit 32
echo "umount $(basename "$(readlink "$dir")")" >>"$T/calls"
. "$T/bin/hook.sh"
rm "$dir" && mkdir "$dir"
[ "$killing" = no ] || power_loss
SH
  cat >"$tmp/bin/mkfs.ext4" <<'SH'
#!/bin/bash
dev=$(basename "${!#}")
echo "mkfs.ext4 $* " | sed "s|$T/dev/||" >>"$T/calls"
if [ -e "$T/broken-mkfs" ]; then exit 1; fi
. "$T/bin/hook.sh"
if [ "$killing" = yes ]; then
  # Half a new filesystem: some of the old files are gone, some are not.
  rm -rf "$T/disk/$dev/rauc" "$T/disk/$dev/network"
  power_loss
fi
rm -rf "$T/disk/$dev" "$T/broken-$dev"
mkdir -p "$T/disk/$dev/lost+found"
SH
  # lsblk -ndo PKNAME -- DEVICE: the disk; "elsewhere-<device>" puts it on another one.
  cat >"$tmp/bin/lsblk" <<'SH'
#!/bin/bash
if [ -e "$T/elsewhere-$(basename "${!#}")" ]; then echo sdb; else echo vda; fi
SH
  # findmnt: nothing is mounted unless "mounted" says so.
  cat >"$tmp/bin/findmnt" <<'SH'
#!/bin/bash
[ -e "$T/mounted" ]
SH
  # grub-editenv FILE list | set KEY=VALUE | unset KEY, on a plain KEY=VALUE file.
  cat >"$tmp/bin/grub-editenv" <<'SH'
#!/bin/bash
f=$1
case "$2" in
  list) cat "$f" ;;
  set)
    echo "grub-editenv set $3" >>"$T/calls"
    . "$T/bin/hook.sh"
    key=${3%%=*}
    { grep -v "^$key=" "$f"; echo "$3"; } >"$f.new"
    mv "$f.new" "$f"
    [ "$killing" = no ] || power_loss
    ;;
  unset)
    echo "grub-editenv unset $3" >>"$T/calls"
    . "$T/bin/hook.sh"
    grep -v "^$3=" "$f" >"$f.new"
    mv "$f.new" "$f"
    [ "$killing" = no ] || power_loss
    ;;
esac
SH
  printf '#!/bin/sh\necho "$*" >>"%s/systemctl.log"\n' "$tmp" >"$tmp/bin/systemctl"
  chmod +x "$tmp/bin/"*
}

# enrolled_slot DIR HOSTNAME: a root slot after the enrollment, with what the
# agent, an app and the SSH user left in it.
enrolled_slot() {
  local r=$1
  mkdir -p "$r/usr/lib" "$r/usr/share/base-files" "$r/etc/sudoers.d" "$r/etc/systemd/system/multi-user.target.wants" \
    "$r/etc/systemd/system/ironflock-device-agent.service.d" "$r/etc/systemd/system/NetworkManager.service.d" \
    "$r/etc/docker" "$r/etc/flockos" "$r/var/lib/flockos" "$r/apps/prod/app1" "$r/var/lib/containerd/io.containerd.metadata.v1.bolt" \
    "$r/var/lib/NetworkManager" "$r/var/lib/sudo/lectured" "$r/var/tmp/tmp.app" "$r/root/.ssh" "$r/var/lib/chrony" "$r/usr/lib/flockos"
  printf 'NAME="IronFlockOS"\nID=flockos\nIMAGE_ID=flockos-amd64-efi-base\nIMAGE_VERSION=0.15.0\n' >"$r/usr/lib/os-release"
  cat >"$r/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
systemd-network:x:998:998:systemd Network Management:/:/usr/sbin/nologin
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
flockostest:x:1000:1000::/home/flockostest:/bin/bash
second:x:1001:1001::/home/second:/bin/bash
EOF
  cat >"$r/etc/shadow" <<'EOF'
root:*:20000:0:99999:7:::
daemon:*:20000:0:99999:7:::
systemd-network:!*:20000::::::
nobody:*:20000:0:99999:7:::
flockostest:!:20400:0:99999:7:::
second:!:20401:0:99999:7:::
EOF
  cat >"$r/etc/group" <<'EOF'
root:x:0:
sudo:x:27:flockostest
users:x:100:
docker:x:999:flockostest,second
systemd-network:x:998:
nogroup:x:65534:
flockostest:x:1000:
second:x:1001:
EOF
  cat >"$r/etc/gshadow" <<'EOF'
root:*::
sudo:*::flockostest
users:*::
docker:!:second:flockostest,second
systemd-network:!*::
nogroup:*::
flockostest:!::
second:!::
EOF
  printf 'flockostest:100000:65536\nsecond:165536:65536\n' >"$r/etc/subuid"
  cp "$r/etc/subuid" "$r/etc/subgid"
  chmod 0640 "$r/etc/shadow" "$r/etc/gshadow"
  printf 'flockostest ALL=(ALL) NOPASSWD:ALL\n' >"$r/etc/sudoers.d/ironflock-flockostest"
  echo '# the package README' >"$r/etc/sudoers.d/README"
  echo '[Unit]' >"$r/etc/systemd/system/ironflock-device-agent.service"
  ln -s ../ironflock-device-agent.service "$r/etc/systemd/system/multi-user.target.wants/ironflock-device-agent.service"
  echo '[Service]' >"$r/etc/systemd/system/ironflock-device-agent.service.d/10-ironflock-resources.conf"
  echo '[Slice]' >"$r/etc/systemd/system/ironflock.slice"
  echo '[Service]' >"$r/etc/systemd/system/NetworkManager.service.d/ironflock-restart.conf"
  echo "$2" >"$r/etc/hostname"
  printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n::1\tlocalhost ip6-localhost ip6-loopback\n' "$2" >"$r/etc/hosts"
  echo 0123456789abcdef0123456789abcdef >"$r/etc/machine-id"
  echo '{"data-root": "/opt/ironflock/device-agent/docker-apps"}' >"$r/etc/docker/daemon.json"
  ln -s /data/flockos/proxy.conf "$r/etc/flockos/proxy.conf"
  echo '#!/bin/sh' >"$r/usr/lib/flockos/enroll"
  date -u +%Y-%m-%dT%H:%M:%SZ >"$r/var/lib/flockos/enrolled"
  : >"$r/var/lib/flockos/slot-proven"
  echo 'the app data of the owner' >"$r/apps/prod/app1/data.txt"
  echo bolt >"$r/var/lib/containerd/io.containerd.metadata.v1.bolt/meta.db"
  echo key >"$r/var/lib/NetworkManager/secret_key"
  : >"$r/var/lib/sudo/lectured/flockostest"
  echo tmp >"$r/var/tmp/tmp.app/file"
  echo 'curl -u owner:secret' >"$r/root/.bash_history"
  echo 'alias owner=1' >"$r/root/.bashrc"
  echo 'ssh-ed25519 AAAA owner' >"$r/root/.ssh/authorized_keys"
  echo '# ~/.bashrc of the image' >"$r/usr/share/base-files/dot.bashrc"
  echo '# ~/.profile of the image' >"$r/usr/share/base-files/dot.profile"
  echo 12.3 >"$r/var/lib/chrony/chrony.drift"
}

# device: an enrolled amd64-efi device booted from slot A, slot B written by an
# update, the data partition in use, a new .flock and proxy.conf waiting on
# the FLOCKOS partition.
device() {
  enrolled_slot "$tmp/disk/rootfs-a" owner-device
  enrolled_slot "$tmp/disk/rootfs-b" owner-device-before
  local d=$tmp/disk/data
  mkdir -p "$d/ironflock/device-agent/docker-apps/containers/abc" "$d/ironflock/device-init" "$d/home/flockostest/.ssh" \
    "$d/network/connections" "$d/flockos" "$d/rauc" "$d/etc/ssh" "$d/log/journal/0123" "$d/log/ironflock" \
    "$d/cache" "$d/fwupd" "$d/pstore" "$d/lost+found"
  echo '{"name": "owner-device", "secret": "s3cret"}' >"$d/ironflock/device-agent/device-config.flock"
  echo db >"$d/ironflock/device-agent/device-agent.db"
  : >"$d/ironflock/device-agent/enrolled"
  echo '{"Name": "/owner-app"}' >"$d/ironflock/device-agent/docker-apps/containers/abc/config.v2.json"
  echo '{"user": {"name": "flockostest"}}' >"$d/ironflock/device-init/installed.json"
  echo 'ssh-ed25519 AAAA owner-key' >"$d/home/flockostest/.ssh/authorized_keys"
  printf '[connection]\nid=OwnerWiFi\n[wifi-security]\npsk=wifi-password\n' >"$d/network/connections/ironflock-wifi.nmconnection"
  printf '[connection]\nid=site-lan\n' >"$d/network/connections/site-lan.nmconnection"
  printf 'http_proxy=http://user:proxy-password@proxy.owner.example:3128\n' >"$d/flockos/proxy.conf"
  printf 'interface=enp88s0\n' >"$d/flockos/ptp.conf"
  printf 'hostname-from-flock=no\n' >"$d/flockos/enroll.conf"
  printf 'isolate=2-3\n' >"$d/flockos/rt.conf"
  chmod 0700 "$d/network/connections"
  chmod 0600 "$d/network/connections/"* "$d/flockos/proxy.conf"
  printf '[slot.rootfs.1]\nbundle.version=0.15.0\n' >"$d/rauc/central.raucs"
  echo 'A=good B=good' >"$d/rauc/flockos-rpi-tryboot.state"
  echo key >"$d/etc/ssh/ssh_host_ed25519_key"
  echo journal >"$d/log/journal/0123/system.journal"
  echo 'agent log of owner-device' >"$d/log/ironflock/device-agent.log"
  echo bundle >"$d/cache/flockos.raucb"
  echo pending >"$d/fwupd/pending.db"
  echo crash >"$d/pstore/dmesg.txt"
  echo 'left by the owner' >"$d/owner-notes.txt"
  mkdir -p "$tmp/esp/EFI/BOOT" "$tmp/run"
  printf 'ORDER=A B\nA_OK=1\nA_TRY=1\nB_OK=1\nB_TRY=0\nFLOCKOS_CMDLINE=systemd.debug_shell=ttyS1\nFLOCKOS_RT_CMDLINE=isolcpus=2-3\n' \
    >"$tmp/esp/EFI/BOOT/grubenv"
  echo shim >"$tmp/esp/EFI/BOOT/BOOTX64.EFI"
  echo '{"name": "new-device", "secret": "new"}' >"$tmp/esp/new-device.flock"
  printf 'http_proxy=http://new-proxy:3128\n' >"$tmp/esp/proxy.conf"
  cat >"$tmp/system.conf" <<EOF
[system]
compatible=flockos-amd64-efi-base
bootloader=grub
grubenv=$tmp/esp/EFI/BOOT/grubenv
data-directory=/data/rauc

[slot.rootfs.0]
device=$tmp/dev/rootfs-a
type=ext4
bootname=A

[slot.rootfs.1]
device=$tmp/dev/rootfs-b
type=ext4
bootname=B
EOF
  echo 'BOOT_IMAGE=/vmlinuz root=PARTUUID=x rauc.slot=A rw' >"$tmp/cmdline"
}

# request CONTENT: factory-reset.conf on the FLOCKOS partition.
request() { printf '%b' "$1" >"$tmp/esp/factory-reset.conf"; }

# reboot: /run is gone, the fakes start counting again.
reboot() { rm -rf "$tmp/run" "$tmp/count"; }

mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
value() { sed -n "s/^$1=//p" "$tmp/esp/factory-reset.log"; }
grubenv() { cat "$tmp/esp/EFI/BOOT/grubenv"; }

# state: every file, link and folder of the disks and the FLOCKOS partition,
# with the content of files; the record without its time.
state() {
  (cd "$tmp" && find disk esp | LC_ALL=C sort | while IFS= read -r f; do
    if [ -L "$f" ]; then
      echo "$f -> $(readlink "$f")"
    elif [ -d "$f" ]; then
      echo "$f/"
    elif [ "$f" = esp/factory-reset.log ]; then
      grep -v '^time=' "$f" | sed "s|^|$f: |"
    else
      echo "$f $(cksum <"$f")"
    fi
  done)
}

# outside: state without what the reset may change: the data partition, the
# request and the record, grubenv, and in the root slots the paths of
# clean_slot.
outside() {
  state | grep -vE '^disk/data|^esp/factory-reset\.|^esp/EFI/BOOT/grubenv|^disk/rootfs-./(apps|root|var/tmp|var/lib/(containerd|NetworkManager|sudo/lectured))/|^disk/rootfs-./etc/(passwd|shadow|group|gshadow|subuid|subgid|hostname|hosts|machine-id) |^disk/rootfs-./etc/sudoers\.d/ironflock-|^disk/rootfs-./etc/systemd/system/(ironflock-device-agent\.service|ironflock\.slice|[^/]*\.wants/ironflock-device-agent\.service)|^disk/rootfs-./var/lib/flockos/enrolled '
}

@test "plain reset: the data partition holds RAUC's state alone, then the device restarts" {
  request ''
  run bash "$reset"
  [ "$status" -eq 0 ]
  [[ "$output" == *"resetting the device (keep network: no)"* ]]
  [ "$(cd "$data" && find . | LC_ALL=C sort | tr '\n' ' ')" = ". ./lost+found ./rauc ./rauc/central.raucs ./rauc/flockos-rpi-tryboot.state " ]
  grep -qx 'bundle.version=0.15.0' "$data/rauc/central.raucs"
  [ ! -e "$esp/factory-reset.conf" ] && [ ! -e "$esp/factory-reset.keep" ] && [ ! -e "$esp/.factory-reset.keep.part" ]
  [ "$(cat "$tmp/systemctl.log")" = "--no-block reboot" ]
  # The old filesystem was read only, the new one has the name repart gives it.
  grep -qx 'mount ro,nodev,nosuid,noexec data' "$tmp/calls"
  grep -q '^mkfs.ext4 -F -q -L data -m 0 data' "$tmp/calls"
}

@test "keep-network=yes keeps the network profiles, proxy.conf and ptp.conf with their modes; nothing else of /data" {
  request 'keep-network=yes\n'
  run bash "$reset"
  [ "$status" -eq 0 ]
  [ "$(cd "$data" && find . -type f | LC_ALL=C sort | tr '\n' ' ')" = "./flockos/proxy.conf ./flockos/ptp.conf ./network/connections/ironflock-wifi.nmconnection ./network/connections/site-lan.nmconnection ./rauc/central.raucs ./rauc/flockos-rpi-tryboot.state " ]
  grep -qx 'psk=wifi-password' "$data/network/connections/ironflock-wifi.nmconnection"
  grep -q 'proxy-password' "$data/flockos/proxy.conf"
  [ "$(mode "$data/network/connections")" = 700 ]
  [ "$(mode "$data/network/connections/ironflock-wifi.nmconnection")" = 600 ]
  [ "$(mode "$data/flockos/proxy.conf")" = 600 ]
  [ "$(mode "$data/flockos")" = 755 ]
  [ "$(value keep-network)" = yes ]
  [ "$(value kept)" = "rauc network/connections flockos/proxy.conf flockos/ptp.conf" ]
}

@test "the booted slot: the enrollment, the agent's unit and what apps and users left are gone; the system and slot-proven stay" {
  request ''
  run bash "$reset"
  [ "$status" -eq 0 ]
  [ "$(cut -d: -f1 "$slot/etc/passwd" | tr '\n' ' ')" = "root daemon systemd-network nobody " ]
  [ "$(cut -d: -f1 "$slot/etc/shadow" | tr '\n' ' ')" = "root daemon systemd-network nobody " ]
  [ "$(tr '\n' ' ' <"$slot/etc/group")" = "root:x:0: sudo:x:27: users:x:100: docker:x:999: systemd-network:x:998: nogroup:x:65534: " ]
  [ "$(tr '\n' ' ' <"$slot/etc/gshadow")" = "root:*:: sudo:*:: users:*:: docker:!:: systemd-network:!*:: nogroup:*:: " ]
  [ ! -s "$slot/etc/subuid" ] && [ ! -s "$slot/etc/subgid" ]
  [ "$(mode "$slot/etc/shadow")" = 640 ] && [ "$(mode "$slot/etc/gshadow")" = 640 ]
  [ ! -e "$slot/etc/sudoers.d/ironflock-flockostest" ] && [ -e "$slot/etc/sudoers.d/README" ]
  [ ! -e "$slot/etc/systemd/system/ironflock-device-agent.service" ]
  [ ! -L "$slot/etc/systemd/system/multi-user.target.wants/ironflock-device-agent.service" ]
  [ ! -e "$slot/etc/systemd/system/ironflock-device-agent.service.d" ] && [ ! -e "$slot/etc/systemd/system/ironflock.slice" ]
  [ -e "$slot/etc/systemd/system/NetworkManager.service.d/ironflock-restart.conf" ]
  [ "$(cat "$slot/etc/hostname")" = flockos ]
  grep -qx "$(printf '127.0.1.1\tflockos')" "$slot/etc/hosts"
  grep -qx "$(printf '127.0.0.1\tlocalhost')" "$slot/etc/hosts"
  [ "$(cat "$slot/etc/machine-id")" = uninitialized ]
  [ ! -e "$slot/var/lib/flockos/enrolled" ] && [ -e "$slot/var/lib/flockos/slot-proven" ]
  [ ! -e "$slot/apps" ]
  for d in var/lib/containerd var/lib/NetworkManager var/lib/sudo/lectured var/tmp; do
    [ -d "$slot/$d" ] && [ -z "$(ls -A "$slot/$d")" ]
  done
  [ "$(ls -A "$slot/root" | tr '\n' ' ')" = ".bashrc .profile " ]
  [ "$(cat "$slot/root/.bashrc")" = '# ~/.bashrc of the image' ]
  [ -e "$slot/etc/docker/daemon.json" ] && [ -L "$slot/etc/flockos/proxy.conf" ] && [ -e "$slot/var/lib/chrony/chrony.drift" ]
}

@test "the other slot is cleared the same way; the booted one is never mounted" {
  request ''
  run bash "$reset"
  [ "$status" -eq 0 ]
  [ "$(cut -d: -f1 "$other/etc/passwd" | tr '\n' ' ')" = "root daemon systemd-network nobody " ]
  [ "$(cat "$other/etc/hostname")" = flockos ]
  [ "$(cat "$other/etc/machine-id")" = uninitialized ]
  [ ! -e "$other/var/lib/flockos/enrolled" ] && [ -e "$other/var/lib/flockos/slot-proven" ]
  [ ! -e "$other/apps" ] && [ ! -e "$other/etc/systemd/system/ironflock-device-agent.service" ]
  grep -qx 'mount nodev,nosuid rootfs-b' "$tmp/calls"
  ! grep -q 'rootfs-a' "$tmp/calls"
  [ "$(value other-slot)" = cleaned ]
}

@test "an empty slot B, a slot on another disk and a slot without IronFlockOS are left alone" {
  rm -rf "$other"
  request ''
  run bash "$reset"
  [ "$status" -eq 0 ]
  [ "$(value other-slot)" = "none (no filesystem)" ]
  [ "$(value result)" = done ]

  reboot
  enrolled_slot "$other" owner-device-before
  touch "$tmp/elsewhere-rootfs-b"
  request ''
  run bash "$reset"
  [ "$status" -eq 0 ]
  [ "$(value other-slot)" = "not cleaned (on another disk)" ]
  [ "$(cat "$other/etc/hostname")" = owner-device-before ]

  reboot
  rm "$tmp/elsewhere-rootfs-b"
  echo 'ID=debian' >"$other/usr/lib/os-release"
  request ''
  run bash "$reset"
  [ "$status" -eq 0 ]
  [ "$(value other-slot)" = "not cleaned (no IronFlockOS)" ]
  [ "$(cat "$other/etc/hostname")" = owner-device-before ]
}

@test "GRUB: the booted slot's try flag is cleared before anything else; the real-time tuning goes; the rest of grubenv stays" {
  request ''
  run bash "$reset"
  [ "$status" -eq 0 ]
  [ "$(grubenv | LC_ALL=C sort | tr '\n' ' ')" = "A_OK=1 A_TRY=0 B_OK=1 B_TRY=0 FLOCKOS_CMDLINE=systemd.debug_shell=ttyS1 ORDER=A B " ]
  [ "$(head -n 2 "$tmp/calls" | tr '\n' ' ')" = "grub-editenv set A_TRY=0 mount ro,nodev,nosuid,noexec data " ]
  [ "$(tail -n 1 "$tmp/calls")" = "grub-editenv unset FLOCKOS_RT_CMDLINE" ]
}

@test "GRUB: a booted slot that is not good, or a command line without a slot, leaves the try flags alone" {
  sed -i.bak 's/^A_OK=1$/A_OK=0/' "$esp/EFI/BOOT/grubenv"
  request ''
  run bash "$reset"
  [ "$status" -eq 0 ]
  grubenv | grep -qx A_TRY=1

  reboot
  printf 'A_OK=1\nA_TRY=1\n' >"$esp/EFI/BOOT/grubenv"
  echo 'root=PARTUUID=x rw' >"$tmp/cmdline"
  request ''
  run bash "$reset"
  [ "$status" -eq 0 ]
  grubenv | grep -qx A_TRY=1
  [ "$(value slot)" = unknown ]
}

@test "the request's forms: empty, comments, CRLF, a byte order mark, quotes and capitals" {
  for form in '' '# reset\n\n' 'keep-network=no\n' 'keep-network=yes' 'keep-network = "yes"  # keep WiFi\r\n' \
    '\xef\xbb\xbfkeep-network=yes\r\n' 'KEEP-NETWORK=Yes\n' 'keep-network=yes\nkeep-network=yes\n'; do
    printf '%b' "$form" >"$tmp/request"
    run bash "$reset" check "$tmp/request"
    [ "$status" -eq 0 ] || { echo "refused: $form: $output"; return 1; }
    case "$form" in
      *[Yy]es*) [ "$output" = keep-network=yes ] ;;
      *) [ "$output" = keep-network=no ] ;;
    esac
  done
  request '\xef\xbb\xbf# from Windows\r\nkeep-network=yes\r\n'
  run bash "$reset"
  [ "$status" -eq 0 ]
  [ -e "$data/flockos/proxy.conf" ]
}

@test "a request the device does not understand is refused: nothing changes, it is renamed and the record says why" {
  before=$(outside)
  for bad in 'keep-network=maybe\n' 'keep-apps=yes\n' 'keep-netwrk=yes\n' 'keep-network=yes\nkeep-apps=yes\n' \
    'reset now\n' 'keep-network="yes\n' 'keep-network=yes\nkeep-network=no\n' 'keep network=yes\n'; do
    data_before=$(state | grep '^disk/data')
    request "$bad"
    run bash "$reset"
    [ "$status" -eq 0 ] || { echo "status $status for: $bad"; return 1; }
    [[ "$output" == *"refused"* ]]
    [ ! -e "$esp/factory-reset.conf" ]
    [ "$(cat "$esp/factory-reset.conf.refused")" = "$(printf '%b' "$bad")" ]
    [ "$(value result)" = refused ]
    [ -n "$(value reason)" ]
    [ "$(state | grep '^disk/data')" = "$data_before" ]
    [ "$(outside | grep -v '^esp/factory-reset')" = "$(printf '%s\n' "$before" | grep -v '^esp/factory-reset')" ]
    grubenv | grep -qx A_TRY=1
    [ ! -e "$tmp/systemctl.log" ] && [ ! -e "$tmp/calls" ]
  done
  [ "$(value reason)" = "line 1 is not a key=value line" ]
  # Neither a folder nor a request on trial runs.
  mkdir "$esp/factory-reset.conf"
  run bash "$reset"
  [ "$status" -eq 0 ]
  [ -d "$esp/factory-reset.conf.refused" ]
  [ "$(value reason)" = "factory-reset.conf is not a file" ]
}

@test "check: says what a request asks for, or why it is refused, and changes nothing" {
  before=$(state)
  printf 'keep-network=yes\n' >"$tmp/request"
  run bash "$reset" check "$tmp/request"
  [ "$status" -eq 0 ] && [ "$output" = keep-network=yes ]
  printf 'keep-apps=yes\n' >"$tmp/request"
  run bash "$reset" check "$tmp/request"
  [ "$status" -eq 1 ]
  [[ "$output" == *"line 1: unknown key keep-apps"* ]]
  run bash "$reset" check
  [ "$status" -eq 2 ]
  [ "$(state)" = "$before" ]
}

@test "the record: result, image, version, slot and what was kept, nothing of the owner" {
  request 'keep-network=yes\n'
  run bash "$reset"
  [ "$status" -eq 0 ]
  [ "$(value result)" = done ]
  [[ "$(value time)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  [ "$(value image)" = flockos-amd64-efi-base ]
  [ "$(value version)" = 0.15.0 ]
  [ "$(value slot)" = A ]
  [ "$(value other-slot)" = cleaned ]
  for owner in owner-device flockostest OwnerWiFi wifi-password proxy.owner.example proxy-password s3cret owner-app; do
    ! grep -q "$owner" "$esp/factory-reset.log" || { echo "the record names $owner"; return 1; }
  done
  ! grep -q -e owner-device -e flockostest -e OwnerWiFi <<<"$output"
}

@test "nothing outside the data partition and the paths of the reset changes; a new .flock and proxy.conf wait for the next boot" {
  before=$(outside)
  request 'keep-network=yes\n'
  run bash "$reset"
  [ "$status" -eq 0 ]
  [ "$(outside)" = "$before" ]
  [ "$(cat "$esp/new-device.flock")" = '{"name": "new-device", "secret": "new"}' ]
  grep -qx 'http_proxy=http://new-proxy:3128' "$esp/proxy.conf"
}

@test "a Raspberry Pi running an update on trial (tryboot) leaves the reset to its next normal boot" {
  mkdir -p "$tmp/dt"
  printf '\0\0\0\1' >"$tmp/dt/tryboot"
  printf '[system]\nbootloader=custom\n' >"$tmp/system.conf"
  request ''
  before=$(state)
  run bash "$reset"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tryboot"* ]]
  [ -e "$esp/factory-reset.conf" ]
  [ "$(state)" = "$before" ]
  # The next boot that is not a trial resets; without GRUB, grubenv stays.
  printf '\0\0\0\0' >"$tmp/dt/tryboot"
  run bash "$reset"
  [ "$status" -eq 0 ]
  [ "$(value result)" = done ]
  grubenv | grep -qx A_TRY=1
  grubenv | grep -qx FLOCKOS_RT_CMDLINE=isolcpus=2-3
  # Without a booted slot in system.conf the other slot stays as it was.
  [ "$(cat "$other/etc/hostname")" = owner-device-before ]
}

@test "a power loss at any step: the reset goes on at the next boot and ends as an uninterrupted one" {
  request 'keep-network=yes\n'
  run bash "$reset"
  [ "$status" -eq 0 ]
  want=$(state)
  steps=$(cat "$tmp/count")
  [ "$steps" -ge 9 ]
  for ((k = 1; k <= steps; k++)); do
    rm -rf "$tmp/disk" "$tmp/esp" "$tmp/calls" "$tmp/systemctl.log"
    reboot
    device
    request 'keep-network=yes\n'
    FAKE_KILL_AT=$k run bash "$reset"
    [ "$status" -eq 137 ] || { echo "step $k: status $status: $output"; return 1; }
    [ -e "$esp/factory-reset.conf" ] || { echo "step $k: the request is gone"; return 1; }
    reboot
    run bash "$reset"
    [ "$status" -eq 0 ] || { echo "after a power loss at step $k: $output"; return 1; }
    [ "$(state)" = "$want" ] || {
      diff <(echo "$want") <(state)
      echo "after a power loss at step $k"
      return 1
    }
  done
}

@test "a power loss after factory-reset.keep is gone and before the request is: the next boot ends the same" {
  request 'keep-network=yes\n'
  run bash "$reset"
  [ "$status" -eq 0 ]
  want=$(state)
  reboot
  request 'keep-network=yes\n'
  run bash "$reset"
  [ "$status" -eq 0 ]
  [ "$(state)" = "$want" ]
}

@test "factory-reset.keep alone finishes a reset that has begun, whatever the request says now" {
  request 'keep-network=yes\n'
  FAKE_KILL_AT=4 run bash "$reset"
  [ "$status" -eq 137 ]
  grep -q '^mkfs.ext4' "$tmp/calls"
  [ -e "$esp/factory-reset.keep" ]
  reboot
  rm "$esp/factory-reset.conf"
  run bash "$reset"
  [ "$status" -eq 0 ]
  [[ "$output" == *"going on with the reset begun before (keep network: yes)"* ]]
  [ -e "$data/flockos/proxy.conf" ] && [ -e "$data/rauc/central.raucs" ]
  [ ! -e "$esp/factory-reset.keep" ]
  [ "$(value keep-network)" = yes ]
}

@test "before the reset has begun, a failure clears nothing: the device boots as before and tries again" {
  before=$(outside)
  data_before=$(cd "$data" && find . | LC_ALL=C sort)
  touch "$tmp/elsewhere-data"
  request 'keep-network=yes\n'
  run bash "$reset"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not on the disk of the root slot; nothing was cleared"* ]]
  [ "$(value result)" = failed ] && [ "$(value begun)" = no ]
  [ -e "$esp/factory-reset.conf" ] && [ ! -e "$esp/factory-reset.keep" ]
  [ "$(cd "$data" && find . | LC_ALL=C sort)" = "$data_before" ]
  [ "$(outside)" = "$before" ]
  [ ! -e "$tmp/systemctl.log" ]
  rm "$tmp/elsewhere-data"

  # /data is mounted: not at boot.
  touch "$tmp/mounted"
  run bash "$reset"
  [ "$status" -eq 0 ]
  [[ "$(value reason)" == "the data partition is mounted"* ]]
  rm "$tmp/mounted"

  # No data partition.
  rm "$tmp/dev/data"
  run bash "$reset"
  [ "$status" -eq 0 ]
  [[ "$(value reason)" == "the data partition ("*") is missing" ]]
  grubenv | grep -qx A_TRY=1
  : >"$tmp/dev/data"

  # A FLOCKOS partition without room for factory-reset.keep: the try flag
  # this boot cleared is set again, so the boot counts as before.
  mkdir "$esp/.factory-reset.keep.part"
  run bash "$reset"
  [ "$status" -eq 0 ]
  [ "$(value reason)" = "cannot write factory-reset.keep to the FLOCKOS partition" ]
  grubenv | grep -qx A_TRY=1
  [ ! -L "$tmp/run/old" ]
  [ "$(cd "$data" && find . | LC_ALL=C sort)" = "$data_before" ]
  rmdir "$esp/.factory-reset.keep.part"

  run bash "$reset"
  [ "$status" -eq 0 ]
  [ "$(value result)" = done ]
}

@test "once the reset has begun, a failure keeps /data unmounted; the next boot finishes it" {
  touch "$tmp/broken-mkfs"
  request 'keep-network=yes\n'
  run bash "$reset"
  [ "$status" -eq 1 ]
  [[ "$output" == *"mkfs.ext4 failed"*"/data stays unmounted"* ]]
  [ "$(value result)" = failed ] && [ "$(value begun)" = yes ]
  [ -e "$esp/factory-reset.conf" ] && [ -e "$esp/factory-reset.keep" ]
  [ ! -e "$tmp/systemctl.log" ]
  reboot
  rm "$tmp/broken-mkfs"
  run bash "$reset"
  [ "$status" -eq 0 ]
  [ "$(value result)" = done ]
  [ -e "$data/network/connections/site-lan.nmconnection" ]
}

@test "a data partition that cannot be mounted is reset all the same, keeping nothing of it" {
  touch "$tmp/broken-data"
  request 'keep-network=yes\n'
  run bash "$reset"
  [ "$status" -eq 0 ]
  [ "$(value result)" = done ]
  [ "$(value kept)" = "" ]
  [ "$(value note)" = "the data partition could not be mounted: nothing of it was kept" ]
}

@test "the unit runs before /data, its fsck and its users; /etc/fstab requires it; the installer has no /data and does not pull it in" {
  u=$units/flockos-factory-reset.service
  grep -qx 'DefaultDependencies=no' "$u"
  grep -qx 'ConditionPathExists=|/boot/efi/factory-reset.conf' "$u"
  grep -qx 'ConditionPathExists=|/boot/efi/factory-reset.keep' "$u"
  grep -qx 'ExecStart=/usr/lib/flockos/factory-reset' "$u"
  grep -q '^After=boot-efi.mount .*systemd-repart.service' "$u"
  grep -qx 'Before=systemd-fsck@dev-disk-by\\x2dpartlabel-data.service data.mount local-fs.target' "$u"
  grep -qx 'Before=flockos-data-layout.service flockos-proxy.service flockos-ptp.service' "$u"
  ! grep -q '^\[Install\]' "$u"
  grep -qE '^PARTLABEL=data +/data +ext4 +.*x-systemd.requires=flockos-factory-reset.service' "$repo/overlay/etc/fstab"
  ! grep -q '/data' "$repo/profiles/installer/overlay/etc/fstab"
  # The installer carries the .flock and proxy.conf to the disk it writes,
  # never a request.
  ! grep -q 'factory-reset' "$repo/profiles/installer/overlay/usr/lib/flockos/installer"
  # The hostname the reset writes is the image's.
  [ "$(cat "$repo/overlay/etc/hostname")" = flockos ]
  grep -qx "$(printf '127.0.1.1\tflockos')" "$repo/overlay/etc/hosts"
  grep -qx 'image_hostname=flockos' "$reset"
  # What the reset keeps of /data is where the image puts it.
  grep -q 'data-directory=/data/rauc' "$repo/targets/amd64-efi/system.conf"
  grep -q '^/data/network/connections  */etc/NetworkManager/system-connections ' "$repo/overlay/etc/fstab"
  grep -q 'ln -sfn /data/flockos/proxy.conf "$ROOT/etc/flockos/proxy.conf"' "$repo/build/customize.sh"
  grep -q 'ln -sfn /data/flockos/ptp.conf "$ROOT/etc/flockos/ptp.conf"' "$repo/build/customize.sh"
}
