#!/usr/bin/env bats
# Factory reset (docs/build.md, "Factory reset"; ADR-0015): requested by
# factory-reset.conf on the IRONFLOCKOS partition, run at boot before /data is
# mounted, against a fake device: folders stand for the data partition and the
# root slots, fakes for mount, mkfs.ext4, lsblk, blkid, findmnt, grub-editenv,
# sync and timeout. A fake can cut the reset short at its n-th call, or at the
# first call of one command, as a power loss would, or make a command run out
# of time. Every failure must let the boot go on (exit 0), count its attempt,
# and say why.

repo="$BATS_TEST_DIRNAME/../.."
reset="$repo/overlay/usr/lib/ironflockos/factory-reset"
units="$repo/overlay/usr/lib/systemd/system"

setup() {
  tmp=$(mktemp -d)
  export T=$tmp
  mkdir -p "$tmp/bin"
  fakes
  device
  export PATH="$tmp/bin:$PATH" IRONFLOCKOS_ESP=$tmp/esp IRONFLOCKOS_ROOT=$tmp/disk/rootfs-a \
    IRONFLOCKOS_SYSTEM_CONF=$tmp/system.conf IRONFLOCKOS_PROC_CMDLINE=$tmp/cmdline IRONFLOCKOS_DATA_DEV=$tmp/dev/data \
    IRONFLOCKOS_RUN=$tmp/run IRONFLOCKOS_BOOTLOADER_DT=$tmp/dt IRONFLOCKOS_RESET_WAIT=0
  slot=$tmp/disk/rootfs-a other=$tmp/disk/rootfs-b data=$tmp/disk/vda4 esp=$tmp/esp
  state_file=$slot/var/lib/ironflockos/factory-reset.state hold_file=$tmp/run/factory-reset-hold
}

teardown() {
  chmod -R u+w "$tmp" 2>/dev/null || true
  rm -rf "$tmp"
}

# The fakes. hook.sh counts the calls that change something or sync; the
# FAKE_KILL_AT-th, or the first of the command FAKE_KILL_ON, cuts the reset
# short after (for mkfs.ext4: halfway through) its work: the attempt and the
# reset that runs it die at once.
fakes() {
  cat >"$tmp/bin/hook.sh" <<'SH'
n=$(($(cat "$T/count" 2>/dev/null || echo 0) + 1))
echo "$n" >"$T/count"
killing=no
if [ "${FAKE_KILL_AT:-0}" = "$n" ]; then killing=yes; fi
if [ -n "${FAKE_KILL_ON:-}" ] && [ "$FAKE_KILL_ON" = "$(basename "$0")" ] && [ ! -e "$T/killed" ]; then
  killing=yes
  : >"$T/killed"
fi
power_loss() {
  if [ -n "${IRONFLOCKOS_RESET_PID:-}" ]; then kill -9 "$IRONFLOCKOS_RESET_PID" 2>/dev/null; fi
  kill -9 "$PPID"
  exit 137
}
SH
  # timeout [-k N] SECONDS COMMAND...: COMMAND in its place. "hang-<name>", or
  # "hang-<name>-<next name>", makes it run out of time instead; the names
  # are those of the command and its first two arguments ("bash <script>
  # attempt" is "factory-reset-attempt").
  cat >"$tmp/bin/timeout" <<'SH'
#!/bin/bash
while [ "$1" = -k ]; do shift 2; done
shift
names=()
for a in "${@:1:3}"; do names+=("$(basename -- "$a")"); done
for ((i = 0; i < ${#names[@]}; i++)); do
  if [ -e "$T/hang-${names[i]}" ] || { [ -n "${names[i + 1]:-}" ] && [ -e "$T/hang-${names[i]}-${names[i + 1]}" ]; }; then
    echo "timeout ${names[i]}" >>"$T/calls"
    exit 124
  fi
done
exec "$@"
SH
  # mount [-t TYPE] [-o OPTIONS] DEVICE DIR: DIR becomes a link to the folder
  # that stands for DEVICE. "broken-<device>" makes every mount of it fail,
  # "unmountable-<device>" every one but read-only.
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
if [ -e "$T/unmountable-$dev" ] && [[ "$opts" != ro,* ]]; then exit 32; fi
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
echo "mkfs.ext4 ${*:1:$#-1} $dev" >>"$T/calls"
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
  # lsblk -ndo PKNAME|PARTLABEL -- DEVICE: from the table "blk" (name, disk,
  # partition name); a device that is not in it is no block device.
  cat >"$tmp/bin/lsblk" <<'SH'
#!/bin/bash
awk -v n="$(basename "${!#}")" -v c="$2" '$1 == n { print (c == "PKNAME" ? $2 : $3); f = 1 } END { exit !f }' "$T/blk"
SH
  # blkid -p -s TYPE -o value DEVICE: ext4 where a folder stands for it.
  cat >"$tmp/bin/blkid" <<'SH'
#!/bin/bash
if [ -d "$T/disk/$(basename "${!#}")" ]; then echo ext4; else exit 2; fi
SH
  # findmnt -rn --source DEVICE: mounted when "mounted-<device>" exists;
  # findmnt -nvo SOURCE TARGET: from the table "mounts" (target, device).
  cat >"$tmp/bin/findmnt" <<'SH'
#!/bin/bash
case "$1" in
  -rn) [ -e "$T/mounted-$(basename "$3")" ] ;;
  -nvo) [ "$2" = SOURCE ] && awk -v t="$3" '$1 == t { print $2; f = 1 } END { exit !f }' "$T/mounts" ;;
  *) exit 1 ;;
esac
SH
  # grub-editenv FILE list | set KEY=VALUE | unset KEY, on a plain KEY=VALUE
  # file; "broken-grubenv" makes it fail.
  cat >"$tmp/bin/grub-editenv" <<'SH'
#!/bin/bash
f=$1
if [ -e "$T/broken-grubenv" ]; then
  echo "grub-editenv: error: invalid environment block" >&2
  exit 1
fi
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
  cat >"$tmp/bin/sync" <<'SH'
#!/bin/bash
. "$T/bin/hook.sh"
[ "$killing" = no ] || power_loss
SH
  printf '#!/bin/sh\necho "$*" >>"%s/systemctl.log"\n' "$tmp" >"$tmp/bin/systemctl"
  chmod +x "$tmp/bin/"*
}

# enrolled_slot DIR HOSTNAME: a root slot after the enrollment, with what the
# agent, an app and the SSH user left in it.
enrolled_slot() {
  local r=$1 f
  mkdir -p "$r/usr/lib" "$r/usr/share/base-files" "$r/etc/sudoers.d" "$r/etc/systemd/system/multi-user.target.wants" \
    "$r/etc/systemd/system/ironflock-device-agent.service.d" "$r/etc/systemd/system/NetworkManager.service.d" \
    "$r/etc/docker" "$r/etc/ironflockos" "$r/var/lib/ironflockos" "$r/apps/prod/app1" "$r/var/lib/containerd/io.containerd.metadata.v1.bolt" \
    "$r/var/lib/NetworkManager" "$r/var/lib/sudo/lectured" "$r/var/tmp/tmp.app" "$r/root/.ssh" "$r/var/lib/chrony" "$r/usr/lib/ironflockos"
  printf 'NAME="IronFlockOS"\nID=ironflockos\nIMAGE_ID=ironflockos-amd64-efi-base\nIMAGE_VERSION=0.15.0\n' >"$r/usr/lib/os-release"
  cat >"$r/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
systemd-network:x:998:998:systemd Network Management:/:/usr/sbin/nologin
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
ironflockostest:x:1000:1000::/home/ironflockostest:/bin/bash
second:x:1001:1001::/home/second:/bin/bash
EOF
  cat >"$r/etc/shadow" <<'EOF'
root:*:20000:0:99999:7:::
daemon:*:20000:0:99999:7:::
systemd-network:!*:20000::::::
nobody:*:20000:0:99999:7:::
ironflockostest:!:20400:0:99999:7:::
second:!:20401:0:99999:7:::
EOF
  cat >"$r/etc/group" <<'EOF'
root:x:0:
sudo:x:27:ironflockostest
users:x:100:
docker:x:999:ironflockostest,second
systemd-network:x:998:
nogroup:x:65534:
ironflockostest:x:1000:
second:x:1001:
EOF
  cat >"$r/etc/gshadow" <<'EOF'
root:*::
sudo:*::ironflockostest
users:*::
docker:!:second:ironflockostest,second
systemd-network:!*::
nogroup:*::
ironflockostest:!::
second:!::
EOF
  printf 'ironflockostest:100000:65536\nsecond:165536:65536\n' >"$r/etc/subuid"
  cp "$r/etc/subuid" "$r/etc/subgid"
  chmod 0640 "$r/etc/shadow" "$r/etc/gshadow"
  # The backups shadow-utils keeps, as passwd --lock left them.
  for f in passwd shadow group gshadow subuid subgid; do cp -p "$r/etc/$f" "$r/etc/$f-"; done
  printf 'ironflockostest ALL=(ALL) NOPASSWD:ALL\n' >"$r/etc/sudoers.d/ironflock-ironflockostest"
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
  ln -s /data/ironflockos/proxy.conf "$r/etc/ironflockos/proxy.conf"
  echo '#!/bin/sh' >"$r/usr/lib/ironflockos/enroll"
  date -u +%Y-%m-%dT%H:%M:%SZ >"$r/var/lib/ironflockos/enrolled"
  : >"$r/var/lib/ironflockos/slot-proven"
  echo 'the app data of the owner' >"$r/apps/prod/app1/data.txt"
  echo bolt >"$r/var/lib/containerd/io.containerd.metadata.v1.bolt/meta.db"
  echo key >"$r/var/lib/NetworkManager/secret_key"
  : >"$r/var/lib/sudo/lectured/ironflockostest"
  echo tmp >"$r/var/tmp/tmp.app/file"
  echo 'curl -u owner:secret' >"$r/root/.bash_history"
  echo 'alias owner=1' >"$r/root/.bashrc"
  echo 'ssh-ed25519 AAAA owner' >"$r/root/.ssh/authorized_keys"
  echo '# ~/.bashrc of the image' >"$r/usr/share/base-files/dot.bashrc"
  echo '# ~/.profile of the image' >"$r/usr/share/base-files/dot.profile"
  echo 12.3 >"$r/var/lib/chrony/chrony.drift"
}

# device: an enrolled amd64-efi device booted from slot A, slot B written by an
# update, the data partition (vda4, which the link IRONFLOCKOS_DATA_DEV stands for
# /dev/disk/by-partlabel/data points at) in use, a new .flock and proxy.conf
# waiting on the IRONFLOCKOS partition.
device() {
  mkdir -p "$tmp/dev"
  : >"$tmp/dev/vda4"
  ln -sfn vda4 "$tmp/dev/data"
  : >"$tmp/dev/rootfs-a"
  : >"$tmp/dev/rootfs-b"
  : >"$tmp/dev/ironflockos"
  printf 'vda4 vda data\nrootfs-a vda rootfs-a\nrootfs-b vda rootfs-b\nironflockos vda IRONFLOCKOS\n' >"$tmp/blk"
  printf '/ %s\n%s %s\n' "$tmp/dev/rootfs-a" "$tmp/esp" "$tmp/dev/ironflockos" >"$tmp/mounts"
  enrolled_slot "$tmp/disk/rootfs-a" owner-device
  enrolled_slot "$tmp/disk/rootfs-b" owner-device-before
  local d=$tmp/disk/vda4
  mkdir -p "$d/ironflock/device-agent/docker-apps/containers/abc" "$d/ironflock/device-init" "$d/home/ironflockostest/.ssh" \
    "$d/network/connections" "$d/ironflockos" "$d/rauc" "$d/etc/ssh" "$d/log/journal/0123" "$d/log/ironflock" \
    "$d/cache" "$d/fwupd" "$d/pstore" "$d/lost+found"
  echo '{"name": "owner-device", "secret": "s3cret"}' >"$d/ironflock/device-agent/device-config.flock"
  echo db >"$d/ironflock/device-agent/device-agent.db"
  : >"$d/ironflock/device-agent/enrolled"
  echo '{"Name": "/owner-app"}' >"$d/ironflock/device-agent/docker-apps/containers/abc/config.v2.json"
  echo '{"user": {"name": "ironflockostest"}}' >"$d/ironflock/device-init/installed.json"
  echo 'ssh-ed25519 AAAA owner-key' >"$d/home/ironflockostest/.ssh/authorized_keys"
  printf '[connection]\nid=OwnerWiFi\n[wifi-security]\npsk=wifi-password\n' >"$d/network/connections/ironflock-wifi.nmconnection"
  printf '[connection]\nid=site-lan\n' >"$d/network/connections/site-lan.nmconnection"
  printf 'http_proxy=http://user:proxy-password@proxy.owner.example:3128\n' >"$d/ironflockos/proxy.conf"
  printf 'interface=enp88s0\n' >"$d/ironflockos/ptp.conf"
  printf 'hostname-from-flock=no\n' >"$d/ironflockos/enroll.conf"
  printf 'isolate=2-3\n' >"$d/ironflockos/rt.conf"
  chmod 0700 "$d/network/connections"
  chmod 0600 "$d/network/connections/"* "$d/ironflockos/proxy.conf"
  printf '[slot.rootfs.1]\nbundle.version=0.15.0\n' >"$d/rauc/central.raucs"
  echo 'A=good B=good' >"$d/rauc/ironflockos-rpi-tryboot.state"
  echo key >"$d/etc/ssh/ssh_host_ed25519_key"
  echo journal >"$d/log/journal/0123/system.journal"
  echo 'agent log of owner-device' >"$d/log/ironflock/device-agent.log"
  echo bundle >"$d/cache/ironflockos.raucb"
  echo pending >"$d/fwupd/pending.db"
  echo crash >"$d/pstore/dmesg.txt"
  echo 'left by the owner' >"$d/owner-notes.txt"
  mkdir -p "$tmp/esp/EFI/BOOT" "$tmp/run"
  printf 'ORDER=A B\nA_OK=1\nA_TRY=1\nB_OK=1\nB_TRY=0\nIRONFLOCKOS_CMDLINE=systemd.debug_shell=ttyS1\nIRONFLOCKOS_RT_CMDLINE=isolcpus=2-3\n' \
    >"$tmp/esp/EFI/BOOT/grubenv"
  echo shim >"$tmp/esp/EFI/BOOT/BOOTX64.EFI"
  echo '{"name": "new-device", "secret": "new"}' >"$tmp/esp/new-device.flock"
  printf 'http_proxy=http://new-proxy:3128\n' >"$tmp/esp/proxy.conf"
  cat >"$tmp/system.conf" <<EOF
[system]
compatible=ironflockos-amd64-efi-base
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

# request CONTENT [STAMP]: factory-reset.conf on the IRONFLOCKOS partition, written
# at STAMP (touch -t; the same by default, so a request is the same request
# in every test).
request() {
  printf '%b' "$1" >"$tmp/esp/factory-reset.conf"
  touch -t "${2:-202611110800}" "$tmp/esp/factory-reset.conf"
}

# boot: the next boot (/run is gone, the fakes count anew) runs the reset.
boot() {
  rm -rf "$tmp/run" "$tmp/count" "$tmp/killed" "$tmp/calls" "$tmp/systemctl.log"
  run bash "$reset"
}

# reboot: /run is gone, the fakes start counting again.
reboot() { rm -rf "$tmp/run" "$tmp/count" "$tmp/killed"; }

on_disk() {
  awk -v n="$1" -v d="$2" -v l="${3:-}" '$1 == n { $2 = d; if (l != "") $3 = l } { print }' "$tmp/blk" >"$tmp/blk.new"
  mv "$tmp/blk.new" "$tmp/blk"
}

mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
value() { sed -n "s/^$1=//p" "$tmp/esp/factory-reset.log"; }
copy_value() { sed -n "s/^$1=//p" "$slot/var/lib/ironflockos/factory-reset.log"; }
state_value() { sed -n "s/^$1=//p" "$state_file"; }
grubenv() { cat "$tmp/esp/EFI/BOOT/grubenv"; }
hold_mode() { cat "$hold_file" 2>/dev/null || echo none; }
not_root() { if [ "$(id -u)" = 0 ]; then skip "root ignores the folder modes this test relies on"; fi; }

# state: every file, link and folder of the disks and the IRONFLOCKOS partition,
# with the content of files; the records without their time, the attempt
# counts left out (a cut-short reset takes one more attempt).
state() {
  (cd "$tmp" && find disk esp | LC_ALL=C sort | while IFS= read -r f; do
    if [ -L "$f" ]; then
      echo "$f -> $(readlink "$f")"
    elif [ -d "$f" ]; then
      echo "$f/"
    elif [[ "$f" == *factory-reset.log || "$f" == *factory-reset.state || "$f" == */ironflockos/factory-reset.done ]]; then
      grep -vE '^(time|attempt|attempts|last-failure)=' "$f" | sed "s|^|$f: |"
    else
      echo "$f $(cksum <"$f")"
    fi
  done)
}

# outside: state without what the reset may change: the data partition, the
# request and the record, grubenv, and in the root slots the paths of
# clean_slot and the reset's own state.
outside() {
  state | grep -vE '^disk/vda4|^esp/factory-reset\.|^esp/EFI/BOOT/grubenv|^disk/rootfs-./(apps|root|var/tmp|var/lib/(containerd|NetworkManager|sudo/lectured))/|^disk/rootfs-./etc/(passwd|shadow|group|gshadow|subuid|subgid|hostname|hosts|machine-id)-? |^disk/rootfs-./etc/sudoers\.d/ironflock-|^disk/rootfs-./etc/systemd/system/(ironflock-device-agent\.service|ironflock\.slice|[^/]*\.wants/ironflock-device-agent\.service)|^disk/rootfs-./var/lib/ironflockos/(enrolled |factory-reset\.)'
}

# --- a reset that completes --------------------------------------------------

@test "plain reset: the data partition holds RAUC's state alone, the reset is marked done, the device restarts once" {
  request ''
  boot
  [ "$status" -eq 0 ]
  [[ "$output" == *"attempt 1 of 3: resetting the device (keep network: no)"* ]]
  [ "$(cd "$data" && find . | LC_ALL=C sort | tr '\n' ' ')" = ". ./ironflockos ./ironflockos/factory-reset.done ./lost+found ./rauc ./rauc/central.raucs ./rauc/ironflockos-rpi-tryboot.state " ]
  grep -qx 'bundle.version=0.15.0' "$data/rauc/central.raucs"
  [ ! -e "$esp/factory-reset.conf" ] && [ ! -e "$esp/factory-reset.keep" ] && [ ! -e "$esp/.factory-reset.keep.part" ]
  [ "$(cat "$tmp/systemctl.log")" = "--no-block reboot" ]
  [ "$(value result)" = done ] && [ -z "$(value failed-steps)" ]
  [ "$(value attempt)" = 1 ] && [ "$(value attempts-max)" = 3 ]
  [ "$(state_value outcome)" = done ] && [ "$(state_value attempts)" = 1 ]
  [ "$(value request)" = "$(state_value request)" ]
  grep -qx "request=$(value request)" "$data/ironflockos/factory-reset.done"
  [ "$(cat "$slot/etc/machine-id")" = uninitialized ]
  [ "$(hold_mode)" = none ]
  # The old filesystem was read only, without following links; the new one is
  # made on the device the link pointed at when it was checked, with the name
  # repart gives it.
  grep -qx 'mount ro,noexec,nodev,nosuid,nosymfollow vda4' "$tmp/calls"
  grep -qx 'mkfs.ext4 -F -q -L data -m 0 vda4' "$tmp/calls"
  grep -qx 'mount nodev,nosuid,nosymfollow vda4' "$tmp/calls"
  # The record is kept in the booted slot as well.
  cmp -s "$esp/factory-reset.log" "$slot/var/lib/ironflockos/factory-reset.log"
}

@test "keep-network=yes keeps the network profiles, proxy.conf and ptp.conf with their modes; nothing else of /data" {
  request 'keep-network=yes\n'
  boot
  [ "$status" -eq 0 ]
  [ "$(cd "$data" && find . -type f | LC_ALL=C sort | tr '\n' ' ')" = "./ironflockos/factory-reset.done ./ironflockos/proxy.conf ./ironflockos/ptp.conf ./network/connections/ironflock-wifi.nmconnection ./network/connections/site-lan.nmconnection ./rauc/central.raucs ./rauc/ironflockos-rpi-tryboot.state " ]
  grep -qx 'psk=wifi-password' "$data/network/connections/ironflock-wifi.nmconnection"
  [ "$(mode "$data/network/connections")" = 700 ]
  [ "$(mode "$data/network/connections/ironflock-wifi.nmconnection")" = 600 ]
  [ "$(mode "$data/ironflockos/proxy.conf")" = 600 ]
  [ "$(mode "$data/ironflockos")" = 755 ]
  [ "$(value keep-network)" = yes ]
  [ "$(value kept)" = "rauc network/connections ironflockos/proxy.conf ironflockos/ptp.conf" ]
}

@test "a kept file that cannot be read is a note, not a reason to stop" {
  not_root
  chmod 000 "$data/ironflockos/ptp.conf"
  request 'keep-network=yes\n'
  boot
  [ "$status" -eq 0 ]
  [ "$(value result)" = done ]
  [ "$(value kept)" = "rauc network/connections ironflockos/proxy.conf" ]
  [ "$(value note)" = "ironflockos/ptp.conf could not be read and was not kept" ]
}

@test "the booted slot: the enrollment, the agent's unit and what apps and users left are gone; the system and slot-proven stay" {
  request ''
  boot
  [ "$status" -eq 0 ]
  for f in passwd shadow passwd- shadow-; do
    [ "$(cut -d: -f1 "$slot/etc/$f" | tr '\n' ' ')" = "root daemon systemd-network nobody " ] || { echo "$f"; return 1; }
  done
  for f in group group-; do
    [ "$(tr '\n' ' ' <"$slot/etc/$f")" = "root:x:0: sudo:x:27: users:x:100: docker:x:999: systemd-network:x:998: nogroup:x:65534: " ]
  done
  for f in gshadow gshadow-; do
    [ "$(tr '\n' ' ' <"$slot/etc/$f")" = "root:*:: sudo:*:: users:*:: docker:!:: systemd-network:!*:: nogroup:*:: " ]
  done
  for f in subuid subgid subuid- subgid-; do [ ! -s "$slot/etc/$f" ]; done
  [ "$(mode "$slot/etc/shadow")" = 640 ] && [ "$(mode "$slot/etc/gshadow-")" = 640 ]
  [ ! -e "$slot/etc/sudoers.d/ironflock-ironflockostest" ] && [ -e "$slot/etc/sudoers.d/README" ]
  [ ! -e "$slot/etc/systemd/system/ironflock-device-agent.service" ]
  [ ! -L "$slot/etc/systemd/system/multi-user.target.wants/ironflock-device-agent.service" ]
  [ ! -e "$slot/etc/systemd/system/ironflock-device-agent.service.d" ] && [ ! -e "$slot/etc/systemd/system/ironflock.slice" ]
  [ -e "$slot/etc/systemd/system/NetworkManager.service.d/ironflock-restart.conf" ]
  [ "$(cat "$slot/etc/hostname")" = ironflockos ]
  grep -qx "$(printf '127.0.1.1\tironflockos')" "$slot/etc/hosts"
  [ ! -e "$slot/var/lib/ironflockos/enrolled" ] && [ -e "$slot/var/lib/ironflockos/slot-proven" ]
  [ ! -e "$slot/apps" ]
  for d in var/lib/containerd var/lib/NetworkManager var/lib/sudo/lectured var/tmp; do
    [ -d "$slot/$d" ] && [ -z "$(ls -A "$slot/$d")" ]
  done
  [ "$(ls -A "$slot/root" | tr '\n' ' ')" = ".bashrc .profile " ]
  [ "$(cat "$slot/root/.bashrc")" = '# ~/.bashrc of the image' ]
  [ -e "$slot/etc/docker/daemon.json" ] && [ -L "$slot/etc/ironflockos/proxy.conf" ] && [ -e "$slot/var/lib/chrony/chrony.drift" ]
}

@test "the account clean-up under mawk, as Debian's awk" {
  command -v mawk >/dev/null || skip "mawk is not installed"
  ln -s "$(command -v mawk)" "$tmp/bin/awk"
  request ''
  boot
  [ "$status" -eq 0 ]
  [ "$(cut -d: -f1 "$slot/etc/passwd" | tr '\n' ' ')" = "root daemon systemd-network nobody " ]
  [ "$(tr '\n' ' ' <"$slot/etc/group")" = "root:x:0: sudo:x:27: users:x:100: docker:x:999: systemd-network:x:998: nogroup:x:65534: " ]
  [ "$(tr '\n' ' ' <"$slot/etc/gshadow")" = "root:*:: sudo:*:: users:*:: docker:!:: systemd-network:!*:: nogroup:*:: " ]
  [ "$(value result)" = done ]
}

@test "the other slot is cleared the same way, mounted without following links, before the data partition; the booted one is never mounted" {
  request ''
  boot
  [ "$status" -eq 0 ]
  [ "$(cut -d: -f1 "$other/etc/passwd" | tr '\n' ' ')" = "root daemon systemd-network nobody " ]
  [ "$(cat "$other/etc/hostname")" = ironflockos ]
  [ "$(cat "$other/etc/machine-id")" = uninitialized ]
  [ ! -e "$other/var/lib/ironflockos/enrolled" ] && [ -e "$other/var/lib/ironflockos/slot-proven" ]
  [ ! -e "$other/apps" ] && [ ! -e "$other/etc/systemd/system/ironflock-device-agent.service" ]
  ! grep -q 'rootfs-a' "$tmp/calls"
  [ "$(grep -n 'mount nodev,nosuid,nosymfollow rootfs-b' "$tmp/calls" | cut -d: -f1)" -lt "$(grep -n '^mkfs.ext4' "$tmp/calls" | cut -d: -f1)" ]
  [ "$(value other-slot)" = cleaned ]
}

@test "an empty slot B, a slot on another disk and a slot without IronFlockOS are left alone; one that cannot be mounted is a failed step" {
  rm -rf "$other"
  request ''
  boot
  [ "$status" -eq 0 ]
  [ "$(value other-slot)" = "none (no filesystem)" ] && [ "$(value result)" = done ]

  enrolled_slot "$other" owner-device-before
  on_disk rootfs-b sdb
  request '' 202611110801
  boot
  [ "$(value other-slot)" = "not cleaned (on another disk)" ] && [ "$(value result)" = done ]
  [ "$(cat "$other/etc/hostname")" = owner-device-before ]

  on_disk rootfs-b vda
  echo 'ID=debian' >"$other/usr/lib/os-release"
  request '' 202611110802
  boot
  [ "$(value other-slot)" = "not cleaned (no IronFlockOS)" ]

  touch "$tmp/broken-rootfs-b"
  request '' 202611110803
  boot
  [ "$status" -eq 0 ]
  [ "$(value other-slot)" = "not cleaned (cannot mount)" ]
  [ "$(value result)" = incomplete ] && [ "$(value failed-steps)" = other-slot ]
  [ ! -e "$esp/factory-reset.conf" ]
  [ "$(cat "$tmp/systemctl.log")" = "--no-block reboot" ]
}

@test "GRUB: the booted slot's try flag is cleared just before the reset begins; the real-time tuning goes; the rest of grubenv stays" {
  request ''
  boot
  [ "$status" -eq 0 ]
  [ "$(grubenv | LC_ALL=C sort | tr '\n' ' ')" = "A_OK=1 A_TRY=0 B_OK=1 B_TRY=0 IRONFLOCKOS_CMDLINE=systemd.debug_shell=ttyS1 ORDER=A B " ]
  # The done mark is looked for first, then the kept files are read, then the
  # flag is cleared.
  [ "$(head -n 5 "$tmp/calls" | tr '\n' '|')" = "mount ro,noexec,nodev,nosuid,nosymfollow vda4|umount vda4|mount ro,noexec,nodev,nosuid,nosymfollow vda4|umount vda4|grub-editenv set A_TRY=0|" ]
  grep -qx 'grub-editenv unset IRONFLOCKOS_RT_CMDLINE' "$tmp/calls"
}

@test "GRUB: a booted slot that is not good, or a command line without a slot, leaves the try flags alone" {
  sed -i.bak 's/^A_OK=1$/A_OK=0/' "$esp/EFI/BOOT/grubenv"
  request ''
  boot
  [ "$status" -eq 0 ]
  grubenv | grep -qx A_TRY=1

  printf 'A_OK=1\nA_TRY=1\n' >"$esp/EFI/BOOT/grubenv"
  echo 'root=PARTUUID=x rw' >"$tmp/cmdline"
  request '' 202611110801
  boot
  [ "$status" -eq 0 ]
  grubenv | grep -qx A_TRY=1
  [ "$(value slot)" = unknown ]
}

# --- requests ----------------------------------------------------------------

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
  boot
  [ "$status" -eq 0 ]
  [ -e "$data/ironflockos/proxy.conf" ]
}

@test "the same answer in every locale: a no-break space is no space" {
  printf 'keep-network=yes\xc2\xa0\n' >"$tmp/request"
  for locale in C C.UTF-8 en_US.UTF-8; do
    LC_ALL=$locale run bash "$reset" check "$tmp/request"
    [ "$status" -eq 1 ] || { echo "accepted in $locale"; return 1; }
  done
}

@test "a request the device does not understand is refused, not counted: nothing changes, it is renamed, part files go" {
  before=$(outside)
  for bad in 'keep-network=maybe\n' 'keep-apps=yes\n' 'keep-netwrk=yes\n' 'keep-network=yes\nkeep-apps=yes\n' \
    'reset now\n' 'keep-network="yes\n' 'keep-network=yes\nkeep-network=no\n' 'keep network=yes\n' \
    'keep-\0network=yes\n' '\0\0\0\0'; do
    data_before=$(state | grep '^disk/vda4')
    request "$bad"
    : >"$esp/.factory-reset.flock.part"
    boot
    [ "$status" -eq 0 ] || { echo "status $status for: $bad"; return 1; }
    [[ "$output" == *"refused"* ]]
    [ ! -e "$esp/factory-reset.conf" ]
    cmp -s "$esp/factory-reset.conf.refused" <(printf '%b' "$bad")
    [ "$(value result)" = refused ] && [ -n "$(value reason)" ]
    [ ! -e "$esp/.factory-reset.flock.part" ] && [ ! -e "$state_file" ]
    [ "$(state | grep '^disk/vda4')" = "$data_before" ]
    [ "$(outside | grep -v '^esp/factory-reset')" = "$(printf '%s\n' "$before" | grep -v '^esp/factory-reset')" ]
    grubenv | grep -qx A_TRY=1
    [ ! -e "$tmp/systemctl.log" ] && [ ! -e "$tmp/calls" ] && [ "$(hold_mode)" = none ]
  done
  [ "$(value reason)" = "the request holds a NUL byte" ]
  mkdir "$esp/factory-reset.conf"
  boot
  [ "$status" -eq 0 ]
  [ "$(value reason)" = "the request is not a file" ]
}

@test "check: prints keep-network=yes or no, or the reason without the file's name, and changes nothing" {
  before=$(state)
  printf 'keep-network=yes\n' >"$tmp/.factory-reset.conf.part"
  run bash "$reset" check "$tmp/.factory-reset.conf.part"
  [ "$status" -eq 0 ] && [ "$output" = keep-network=yes ]
  printf 'keep-apps=yes\n' >"$tmp/.factory-reset.conf.part"
  run bash "$reset" check "$tmp/.factory-reset.conf.part"
  [ "$status" -eq 1 ] && [ "$output" = "factory-reset: line 1: unknown key keep-apps" ]
  printf 'keep-\0network=yes\n' >"$tmp/.factory-reset.conf.part"
  run bash "$reset" check "$tmp/.factory-reset.conf.part"
  [ "$status" -eq 1 ] && [ "$output" = "factory-reset: the request holds a NUL byte" ]
  head -c 5000 /dev/zero | tr '\0' '#' >"$tmp/.factory-reset.conf.part"
  run bash "$reset" check "$tmp/.factory-reset.conf.part"
  [ "$status" -eq 1 ] && [ "$output" = "factory-reset: the request is larger than 4 KiB" ]
  run bash "$reset" check "$tmp/missing"
  [ "$status" -eq 1 ] && [ "$output" = "factory-reset: the request is not a file" ]
  run bash "$reset" check
  [ "$status" -eq 2 ]
  run bash "$reset" now
  [ "$status" -eq 2 ]
  [ "$(state)" = "$before" ]
}

@test "the record: result, image, version, slot, request, attempts and what was kept; nothing of the owner" {
  request 'keep-network=yes\n'
  boot
  [ "$status" -eq 0 ]
  [ "$(value result)" = done ]
  [[ "$(value time)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  [ "$(value image)" = ironflockos-amd64-efi-base ] && [ "$(value version)" = 0.15.0 ] && [ "$(value slot)" = A ]
  [[ "$(value request)" =~ ^[0-9]+-[0-9]+-2026111[01]T[0-9]{6}Z$ ]]
  [ "$(value other-slot)" = cleaned ]
  for owner in owner-device ironflockostest OwnerWiFi wifi-password proxy.owner.example proxy-password s3cret owner-app; do
    ! grep -q "$owner" "$esp/factory-reset.log" || { echo "the record names $owner"; return 1; }
  done
  ! grep -q -e owner-device -e ironflockostest -e OwnerWiFi <<<"$output"
}

@test "nothing outside the data partition and the paths of the reset changes; a new .flock and proxy.conf wait for the next boot; part files go" {
  before=$(outside)
  echo '{"secret": "half written"}' >"$esp/.factory-reset.flock.part"
  request 'keep-network=yes\n'
  boot
  [ "$status" -eq 0 ]
  [ "$(outside)" = "$before" ]
  [ "$(cat "$esp/new-device.flock")" = '{"name": "new-device", "secret": "new"}' ]
  grep -qx 'http_proxy=http://new-proxy:3128' "$esp/proxy.conf"
  [ ! -e "$esp/.factory-reset.flock.part" ]
}

@test "a Raspberry Pi on trial (tryboot) leaves the reset to its next normal boot; the attempt is not counted" {
  mkdir -p "$tmp/dt"
  printf '\0\0\0\1' >"$tmp/dt/tryboot"
  printf '[system]\nbootloader=custom\n' >"$tmp/system.conf"
  request ''
  before=$(state)
  boot
  [ "$status" -eq 0 ]
  [[ "$output" == *"tryboot"* ]]
  [ "$(state)" = "$before" ] && [ "$(hold_mode)" = wait ]
  printf '\0\0\0\0' >"$tmp/dt/tryboot"
  boot
  [ "$status" -eq 0 ]
  [ "$(value result)" = done ] && [ "$(value attempt)" = 1 ]
  grubenv | grep -qx A_TRY=1
}

# --- a power loss ------------------------------------------------------------

@test "a power loss at any step: the reset goes on at the next boot and ends as an uninterrupted one" {
  request 'keep-network=yes\n'
  boot
  [ "$status" -eq 0 ]
  want=$(state)
  steps=$(cat "$tmp/count")
  [ "$steps" -ge 20 ]
  for ((k = 1; k <= steps; k++)); do
    rm -rf "$tmp/disk" "$tmp/esp"
    device
    request 'keep-network=yes\n'
    rm -rf "$tmp/run" "$tmp/count" "$tmp/killed" "$tmp/calls" "$tmp/systemctl.log"
    FAKE_KILL_AT=$k run bash "$reset"
    [ "$status" -eq 137 ] || { echo "step $k: status $status: $output"; return 1; }
    boot
    [ "$status" -eq 0 ] || { echo "after a power loss at step $k: $output"; return 1; }
    [ "$(state)" = "$want" ] || {
      diff <(echo "$want") <(state)
      echo "after a power loss at step $k"
      return 1
    }
    # Done once: a next boot finds it done and changes nothing.
    boot
    [ "$status" -eq 0 ] && [ "$(state)" = "$want" ] && ! grep -q mkfs "$tmp/calls" 2>/dev/null
  done
}

@test "a power loss right before and right after factory-reset.keep takes its name" {
  request 'keep-network=yes\n'
  FAKE_KILL_ON=grub-editenv run bash "$reset"
  [ "$status" -eq 137 ]
  [ -e "$esp/.factory-reset.keep.part" ] && [ ! -e "$esp/factory-reset.keep" ] && [ -e "$data/owner-notes.txt" ]
  [ "$(state_value attempts)" = 1 ]
  boot
  [ "$status" -eq 0 ]
  [ "$(value result)" = done ] && [ "$(value attempt)" = 2 ] && [ -e "$data/ironflockos/proxy.conf" ]
}

@test "a completed reset is not done again: its request found at a later boot, in either slot, is removed and nothing else happens" {
  request 'keep-network=yes\n'
  boot
  [ "$status" -eq 0 ]
  want=$(state)
  # The request comes back unchanged (it could not be removed): the state of
  # the slot says done.
  request 'keep-network=yes\n'
  boot
  [ "$status" -eq 0 ]
  [[ "$output" == *"completed before; it is not done again"* ]]
  ! grep -q mkfs "$tmp/calls"
  [ ! -e "$tmp/systemctl.log" ] && [ ! -e "$esp/factory-reset.conf" ]
  [ "$(state)" = "$want" ]
  # The other slot boots, or the state is lost: the mark on /data says done.
  rm "$state_file"
  request 'keep-network=yes\n'
  boot
  [ "$status" -eq 0 ]
  ! grep -q mkfs "$tmp/calls"
  [ ! -e "$tmp/systemctl.log" ] && [ ! -e "$esp/factory-reset.conf" ]
  [ "$(state_value outcome)" = done ]
  # A power loss lost the record: it is written from the mark.
  rm "$esp/factory-reset.log" "$slot/var/lib/ironflockos/factory-reset.log"
  request 'keep-network=yes\n'
  boot
  [ "$(value result)" = done ] && [ "$(value kept)" = "rauc network/connections ironflockos/proxy.conf ironflockos/ptp.conf" ]
}

@test "a slot cleared halfway is finished the same at the next attempt" {
  request 'keep-network=yes\n'
  boot
  [ "$status" -eq 0 ]
  want=$(state)
  mkdir -p "$slot/apps/prod/app1"
  echo 'the app data of the owner' >"$slot/apps/prod/app1/data.txt"
  echo owner-device >"$slot/etc/hostname"
  echo 'ironflockostest:x:1000:1000::/home/ironflockostest:/bin/bash' >>"$slot/etc/passwd"
  : >"$slot/etc/passwd.ironflockos-new"
  rm "$state_file" "$data/ironflockos/factory-reset.done"
  echo 0123456789abcdef0123456789abcdef >"$slot/etc/machine-id"
  request 'keep-network=yes\n'
  boot
  [ "$status" -eq 0 ]
  [ "$(value result)" = done ]
  [ "$(state)" = "$want" ]
}

@test "factory-reset.keep alone goes on with a reset that has begun, whatever the request says now" {
  request 'keep-network=yes\n'
  FAKE_KILL_ON=mkfs.ext4 run bash "$reset"
  [ "$status" -eq 137 ]
  [ -e "$esp/factory-reset.keep" ]
  rm "$esp/factory-reset.conf"
  boot
  [ "$status" -eq 0 ]
  [[ "$output" == *"attempt 2 of 3, going on with the reset begun before (keep network: yes)"* ]]
  [ -e "$data/ironflockos/proxy.conf" ] && [ ! -e "$esp/factory-reset.keep" ]
  [ "$(value result)" = done ] && [ "$(value keep-network)" = yes ]
}

# --- failures: every boot goes on, three attempts, then it gives up ----------

@test "a failure before the reset begins: the boot goes on with the old /data, the old identity runs, three attempts, then it gives up" {
  before=$(outside)
  data_before=$(cd "$data" && find . | LC_ALL=C sort)
  on_disk vda4 sdb
  request 'keep-network=yes\n'
  for k in 1 2; do
    boot
    [ "$status" -eq 0 ]
    [[ "$output" == *"attempt $k of 3 failed (the data partition is not the partition named data on the disk of the root slot)"* ]]
    [ "$(value result)" = failed ] && [ "$(value attempt)" = "$k" ] && [ "$(value begun)" = no ] && [ "$(value data)" = old ]
    [ "$(hold_mode)" = wait ] && [ ! -e "$tmp/systemctl.log" ]
    [ -e "$esp/factory-reset.conf" ] && [ ! -e "$esp/factory-reset.keep" ]
    [ "$(cd "$data" && find . | LC_ALL=C sort)" = "$data_before" ]
    [ "$(outside | grep -v factory-reset)" = "$(printf '%s\n' "$before" | grep -v factory-reset)" ]
    grubenv | grep -qx A_TRY=1
  done
  boot
  [ "$status" -eq 0 ]
  [[ "$output" == *"GAVE UP after 3 attempts (the data partition is not the partition named data"* ]]
  [ "$(value result)" = gave-up ] && [ "$(value attempt)" = 3 ] && [ "$(value data)" = old ]
  [ "$(value left)" = "data booted-slot other-slot" ]
  [[ "$(value reason)" == "the data partition is not the partition named data on the disk of the root slot" ]]
  [ "$(state_value outcome)" = gave-up ]
  # The device stays the device it was: the request is retired, the .flock and
  # proxy.conf that came for after the reset are gone, nothing is held.
  [ ! -e "$esp/factory-reset.conf" ] && [ -e "$esp/factory-reset.conf.gave-up" ]
  [ ! -e "$esp/new-device.flock" ] && [ ! -e "$esp/proxy.conf" ] && [ "$(hold_mode)" = none ]
  grep -qx 'outcome=gave-up' "$data/ironflockos/factory-reset.done"
  [ "$(cd "$data" && find . | LC_ALL=C sort | grep -v factory-reset.done)" = "$data_before" ]
  # It is not tried again.
  on_disk vda4 vda
  boot
  [ "$status" -eq 0 ] && [ ! -e "$tmp/calls" ] && [ "$(state_value attempts)" = 3 ]
  # A new request (written again) has its own three attempts.
  request 'keep-network=yes\n' 202611120900
  boot
  [ "$(value result)" = done ] && [ "$(value attempt)" = 1 ]
}

@test "the other failures before the reset begins: no data partition, the wrong one, IRONFLOCKOS on another disk, no room, an unreadable grubenv" {
  data_before=$(cd "$data" && find . | LC_ALL=C sort)
  check_failed() {
    boot
    [ "$status" -eq 0 ] || return 1
    [ "$(value result)" = failed ] && [ "$(value begun)" = no ] && [ "$(hold_mode)" = wait ] || return 1
    [[ "$(value reason)" == $1 ]] || { echo "reason: $(value reason)"; return 1; }
    [ "$(cd "$data" && find . | LC_ALL=C sort)" = "$data_before" ] && grubenv | grep -qx A_TRY=1
    [ ! -f "$esp/.factory-reset.keep.part" ] && [ ! -e "$tmp/systemctl.log" ]
  }
  on_disk vda4 vda other
  request '' 202611110801
  check_failed "the data partition is not the partition named data on the disk of the root slot"
  on_disk vda4 vda data
  on_disk ironflockos sdb
  request '' 202611110802
  check_failed "the IRONFLOCKOS partition at * is not on the disk of the root slot"
  on_disk ironflockos vda
  rm "$tmp/dev/vda4"
  request '' 202611110803
  check_failed "the data partition (*) is missing"
  : >"$tmp/dev/vda4"
  mkdir "$esp/.factory-reset.keep.part"
  request '' 202611110804
  check_failed "cannot write factory-reset.keep to the IRONFLOCKOS partition"
  ! grep -q grub-editenv "$tmp/calls"
  rmdir "$esp/.factory-reset.keep.part"
  touch "$tmp/broken-grubenv"
  request '' 202611110805
  check_failed "cannot read or write *grubenv"
}

@test "a new filesystem that cannot be made: the boot goes on without /data, the waiting .flock is used and kept; the next attempt completes" {
  touch "$tmp/broken-mkfs"
  request 'keep-network=yes\n'
  boot
  [ "$status" -eq 0 ]
  [[ "$output" == *"attempt 1 of 3 failed (mkfs.ext4 failed on"* ]]
  [ "$(value result)" = failed ] && [ "$(value begun)" = yes ] && [ "$(value data)" = none ]
  [ "$(hold_mode)" = copy ] && [ ! -e "$tmp/systemctl.log" ]
  [ -e "$esp/factory-reset.conf" ] && [ -e "$esp/factory-reset.keep" ]
  # The root slots were cleared first: nothing of the old owner beside a new
  # identity; the running system keeps its machine-id.
  [ ! -e "$slot/apps" ] && [ "$(cat "$slot/etc/machine-id")" = 0123456789abcdef0123456789abcdef ]
  rm "$tmp/broken-mkfs"
  boot
  [ "$status" -eq 0 ]
  [ "$(value result)" = done ] && [ "$(value attempt)" = 2 ]
  [ -e "$data/network/connections/site-lan.nmconnection" ] && [ "$(hold_mode)" = none ]
}

@test "a reset cut short after the erase began: the next boot's attempt makes /data new again, never half-erased" {
  request 'keep-network=yes\n'
  FAKE_KILL_ON=mkfs.ext4 run bash "$reset"
  [ "$status" -eq 137 ]
  [ "$(state_value erase)" = started ]
  touch "$tmp/broken-mkfs"
  boot
  [ "$status" -eq 0 ]
  [ "$(value result)" = failed ] && [ "$(value attempt)" = 2 ] && [ "$(value data)" = none ]
  rm "$tmp/broken-mkfs"
  touch "$tmp/hang-factory-reset-attempt"
  boot
  [ "$status" -eq 0 ]
  # The third attempt did not end: the reset gives up and makes /data new,
  # with the kept files, rather than leave it half erased.
  [[ "$output" == *"GAVE UP after 3 attempts (the attempt did not end within"* ]]
  [ "$(value result)" = gave-up ] && [ "$(value data)" = new ] && [ -z "$(value left)" ]
  [ -e "$data/network/connections/site-lan.nmconnection" ] && [ ! -e "$data/owner-notes.txt" ]
  [ ! -e "$esp/factory-reset.keep" ] && [ "$(hold_mode)" = none ] && [ ! -e "$tmp/systemctl.log" ]
}

@test "a filesystem that hangs or cannot be mounted: three attempts, each boot goes on, then it gives up without /data and says so" {
  touch "$tmp/hang-mkfs.ext4"
  request ''
  for k in 1 2 3; do
    boot
    [ "$status" -eq 0 ] && [ ! -e "$tmp/systemctl.log" ]
    grep -qx 'timeout mkfs.ext4' "$tmp/calls"
  done
  [ "$(value result)" = gave-up ] && [ "$(value data)" = none ] && [ "$(value left)" = data ]
  [[ "$output" == *"THE DATA PARTITION HOLDS NO FILESYSTEM THAT MOUNTS"* ]]
  [ "$(copy_value result)" = gave-up ]

  [ ! -e "$esp/factory-reset.conf" ] && [ -e "$esp/factory-reset.conf.gave-up" ] && [ -e "$esp/new-device.flock" ]
  rm "$tmp/hang-mkfs.ext4"
  touch "$tmp/unmountable-vda4"
  request '' 202611110801
  boot
  [ "$status" -eq 0 ]
  [ "$(value result)" = failed ] && [ "$(value reason)" = "cannot mount the new filesystem" ] && [ "$(value data)" = none ]
}

@test "a data partition that cannot be mounted: two attempts wait for it, the last resets it all the same, keeping nothing of it" {
  touch "$tmp/broken-vda4"
  request 'keep-network=yes\n'
  for k in 1 2; do
    boot
    [ "$status" -eq 0 ]
    [ "$(value result)" = failed ] && [ "$(value reason)" = "the data partition could not be mounted to keep its files" ]
    [ "$(value begun)" = no ] && [ "$(value data)" = old ] && [ "$(hold_mode)" = wait ]
  done
  boot
  [ "$status" -eq 0 ]
  [ "$(value result)" = done ] && [ "$(value attempt)" = 3 ] && [ "$(value kept)" = "" ]
  [ "$(value note)" = "the data partition could not be mounted: nothing of it was kept" ]
}

@test "a clean-up step that fails after /data is new ends the reset as incomplete: the request goes, the device restarts" {
  not_root
  chmod 555 "$slot/etc"
  request 'keep-network=yes\n'
  boot
  [ "$status" -eq 0 ]
  [ "$(value result)" = incomplete ] && [ "$(value failed-steps)" = booted-slot ]
  [ ! -e "$esp/factory-reset.conf" ] && [ "$(cat "$tmp/systemctl.log")" = "--no-block reboot" ]
  [ ! -e "$slot/apps" ] && [ ! -e "$slot/var/lib/ironflockos/enrolled" ]
  [ "$(cat "$slot/etc/machine-id")" = uninitialized ]
}

@test "an attempt that cannot be counted is not made: the boot goes on as it is" {
  not_root
  mkdir -p "$slot/var/lib/ironflockos"
  chmod 555 "$slot/var/lib/ironflockos"
  request 'keep-network=yes\n'
  data_before=$(state | grep '^disk/vda4')
  for k in 1 2 3 4; do
    boot
    [ "$status" -eq 0 ]
    [[ "$output" == *"without a count there is no attempt at this boot"* ]]
    [ "$(value result)" = failed ] && [[ "$(value reason)" == "cannot count the attempt in "* ]]
    [ "$(state | grep '^disk/vda4')" = "$data_before" ] && [ "$(hold_mode)" = wait ]
  done
  # Nothing can be written at all, the IRONFLOCKOS partition neither: the same.
  chmod 555 "$esp"
  before=$(state)
  boot
  [ "$status" -eq 0 ] && [ "$(state)" = "$before" ] && [ "$(hold_mode)" = wait ]
}

@test "a read-only IRONFLOCKOS partition: each attempt fails before it begins, the boot goes on, the record is kept in the slot" {
  not_root
  request 'keep-network=yes\n'
  chmod 555 "$esp"
  for k in 1 2 3; do
    boot
    [ "$status" -eq 0 ]
  done
  [ "$(copy_value result)" = gave-up ] && [ "$(copy_value data)" = old ]
  [ "$(copy_value reason)" = "cannot write factory-reset.keep to the IRONFLOCKOS partition" ]
  [ "$(hold_mode)" = gave-up ] && [ -e "$data/owner-notes.txt" ]
}

@test "a request that gave up never fires again: in a fresh slot (an update), after a rollback, with IRONFLOCKOS read-only" {
  not_root
  request 'keep-network=yes\n'
  chmod 555 "$esp"
  for k in 1 2 3; do boot; done
  [ "$(copy_value result)" = gave-up ] && [ "$(hold_mode)" = gave-up ]
  [ -e "$esp/factory-reset.conf" ] && [ -e "$esp/new-device.flock" ]
  grep -qx 'outcome=gave-up' "$data/ironflockos/factory-reset.done"
  data_before=$(state | grep '^disk/vda4')
  # A slot without this state (a rollback, or an update without its carry):
  # the mark on /data says gave-up. Nothing is tried, nothing is counted.
  for k in 1 2 3 4; do
    rm -f "$state_file"
    boot
    [ "$status" -eq 0 ] && [[ "$output" == *"given up before"* ]]
    ! grep -qE 'mkfs|grub-editenv' "$tmp/calls"
    [ "$(hold_mode)" = gave-up ] && [ "$(state | grep '^disk/vda4')" = "$data_before" ]
  done
  # The state alone, without the mark on /data, does the same.
  rm "$data/ironflockos/factory-reset.done"
  boot
  [ "$status" -eq 0 ] && [[ "$output" == *"given up before"* ]] && ! grep -q mkfs "$tmp/calls"
  # IRONFLOCKOS writable again: the request is retired and the files go.
  chmod 755 "$esp"
  boot
  [ "$status" -eq 0 ]
  [ ! -e "$esp/factory-reset.conf" ] && [ -e "$esp/factory-reset.conf.gave-up" ]
  [ ! -e "$esp/new-device.flock" ] && [ ! -e "$esp/proxy.conf" ] && [ "$(hold_mode)" = none ]
  # An update carries the state into the new slot.
  grep -q 'reset_state=${IRONFLOCKOS_RESET_STATE:-/var/lib/ironflockos/factory-reset.state}' "$repo/overlay/usr/lib/ironflockos/rauc-post-install"
  grep -q 'cp -p "$reset_state" "$mnt$reset_state"' "$repo/overlay/usr/lib/ironflockos/rauc-post-install"
}

@test "after a give-up with the old data, a .flock put on IRONFLOCKOS later enrolls as on any device; while held, it waits" {
  lib=$repo/overlay/usr/lib/ironflockos
  mkdir -p "$tmp/agent" "$tmp/state" "$tmp/run"
  printf '#!/bin/bash\necho "$*" >>%s/init-calls\n' "$tmp" >"$tmp/ironflock-init"
  chmod +x "$tmp/ironflock-init"
  enroll_env=(IRONFLOCKOS_AGENT_DIR="$tmp/agent" IRONFLOCKOS_STATE="$tmp/state" IRONFLOCKOS_INIT="$tmp/ironflock-init"
    IRONFLOCKOS_ENROLL_CONF="$tmp/enroll.conf")
  echo gave-up >"$hold_file"
  : >"$tmp/state/enrolled"
  run env "${enroll_env[@]}" bash "$lib/enroll"
  [ "$status" -eq 0 ] && [ ! -e "$tmp/init-calls" ] && [ -e "$esp/new-device.flock" ]
  rm "$hold_file"
  run env "${enroll_env[@]}" bash "$lib/enroll"
  [ "$(cat "$tmp/init-calls")" = "enroll -c $esp/new-device.flock --shred-source --hostname-from-flock" ]
}

@test "started while /data is mounted (a unit that needs /data was started): nothing happens, nothing is counted" {
  request 'keep-network=yes\n'
  before=$(state)
  touch "$tmp/mounted-vda4"
  boot
  [ "$status" -eq 0 ]
  [[ "$output" == *"/data is mounted: the reset runs at the next boot"* ]]
  [ "$(state)" = "$before" ] && [ ! -e "$state_file" ] && [ ! -e "$esp/factory-reset.log" ]
}

# --- enroll and ironflockos-proxy, the units ----------------------------------------

@test "enroll and ironflockos-proxy: wait leaves the IRONFLOCKOS partition's .flock and proxy.conf, copy takes them and leaves them there" {
  lib=$repo/overlay/usr/lib/ironflockos
  mkdir -p "$tmp/agent" "$tmp/state" "$tmp/pdata" "$tmp/run"
  printf '#!/bin/bash\necho "$*" >>%s/init-calls\n' "$tmp" >"$tmp/ironflock-init"
  chmod +x "$tmp/ironflock-init"
  echo '{"appliance_domain": "old.example"}' >"$tmp/agent/device-config.flock"
  printf 'http_proxy=http://old:3128\n' >"$tmp/pdata/proxy.conf"
  echo '{"appliance_domain": "new.example"}' >"$esp/new-device.flock"
  echo '{"appliance_domain": "other.example"}' >"$esp/other.flock"
  touch -t 202001010000 "$esp/other.flock"
  enroll_env=(IRONFLOCKOS_AGENT_DIR="$tmp/agent" IRONFLOCKOS_STATE="$tmp/state" IRONFLOCKOS_INIT="$tmp/ironflock-init"
    IRONFLOCKOS_ENROLL_CONF="$tmp/enroll.conf")
  proxy_env=(IRONFLOCKOS_PROXY_CONF="$tmp/pdata/proxy.conf" IRONFLOCKOS_AGENT_FLOCK="$tmp/agent/device-config.flock")

  echo wait >"$hold_file"
  : >"$tmp/state/enrolled"
  run env "${enroll_env[@]}" bash "$lib/enroll"
  [ "$status" -eq 0 ] && [[ "$output" == *"no .flock is taken from the IRONFLOCKOS partition"* ]] && [ ! -e "$tmp/init-calls" ]
  rm "$tmp/state/enrolled"
  run env "${enroll_env[@]}" bash "$lib/enroll"
  [ "$(cat "$tmp/init-calls")" = "enroll -c $tmp/agent/device-config.flock --shred-source --hostname-from-flock" ]
  rm "$tmp/init-calls"
  run env "${proxy_env[@]}" bash "$lib/proxy"
  [ "$status" -eq 0 ] && [[ "$output" == *"proxy.conf waits"* ]]
  grep -qx 'http_proxy=http://old:3128' "$tmp/pdata/proxy.conf" && [ -e "$esp/proxy.conf" ]
  grep -qx 'NO_PROXY=localhost,127.0.0.1,::1,old.example,.old.example' "$tmp/run/proxy.env"

  # copy: the .flock is used and stays, for the reset still to come; so does
  # proxy.conf, and so do the other .flock files.
  echo copy >"$hold_file"
  run env "${enroll_env[@]}" bash "$lib/enroll"
  [ "$status" -eq 0 ]
  [ "$(cat "$tmp/init-calls")" = "enroll -c $esp/new-device.flock --hostname-from-flock" ]
  [ -e "$esp/new-device.flock" ] && [ -e "$esp/other.flock" ]
  rm "$tmp/init-calls"
  run env "${proxy_env[@]}" bash "$lib/proxy"
  [ "$status" -eq 0 ]
  grep -qx 'http_proxy=http://new-proxy:3128' "$tmp/pdata/proxy.conf" && [ -e "$esp/proxy.conf" ]
  grep -qx 'NO_PROXY=localhost,127.0.0.1,::1,new.example,.new.example' "$tmp/run/proxy.env"

  # Without /data (ironflockos-data-missing) both copy as well.
  rm "$hold_file"
  : >"$tmp/run/data-missing"
  run env "${enroll_env[@]}" bash "$lib/enroll"
  [ "$(cat "$tmp/init-calls")" = "enroll -c $esp/new-device.flock --hostname-from-flock" ]
  [ -e "$esp/new-device.flock" ]
  rm "$tmp/init-calls" "$tmp/run/data-missing"

  # none: as without a reset.
  run env "${enroll_env[@]}" bash "$lib/enroll"
  [ "$(cat "$tmp/init-calls")" = "enroll -c $esp/new-device.flock --shred-source --hostname-from-flock" ]
  [ ! -e "$esp/other.flock" ]
  run env "${proxy_env[@]}" bash "$lib/proxy"
  [ ! -e "$esp/proxy.conf" ]
}

@test "the units: the reset and the note of a missing /data are wanted by /data's mount; nothing of /data or IRONFLOCKOS can stop the boot" {
  u=$units/ironflockos-factory-reset.service
  grep -qx 'DefaultDependencies=no' "$u"
  grep -qx 'ConditionPathExists=|/boot/efi/factory-reset.conf' "$u"
  grep -qx 'ConditionPathExists=|/boot/efi/factory-reset.keep' "$u"
  grep -qx 'ConditionPathIsMountPoint=!/data' "$u"
  grep -qx 'ExecStart=/usr/lib/ironflockos/factory-reset' "$u"
  grep -qx 'Before=systemd-fsck@dev-disk-by\\x2dpartlabel-data.service data.mount local-fs.target' "$u"
  grep -qx 'Before=ironflockos-data-layout.service ironflockos-proxy.service ironflockos-ptp.service' "$u"
  grep -qE '^TimeoutStartSec=[0-9]+min$' "$u"
  ! grep -q '^\[Install\]' "$u"
  [ "$(readlink "$units/data.mount.wants/ironflockos-factory-reset.service")" = ../ironflockos-factory-reset.service ]
  [ "$(readlink "$units/data.mount.wants/ironflockos-data-missing.service")" = ../ironflockos-data-missing.service ]
  m=$units/ironflockos-data-missing.service
  grep -qx 'After=data.mount' "$m" && grep -qx 'ConditionPathIsMountPoint=!/data' "$m"
  grep -qx 'ExecStart=/usr/lib/ironflockos/data-missing' "$m"
  # /etc/fstab: no mount there can stop the boot; each stays before
  # local-fs.target. The reset is no requirement of /data's mount.
  fstab=$repo/overlay/etc/fstab
  ! grep -q 'x-systemd.requires=ironflockos-factory-reset' "$fstab"
  grep -v '^#' "$fstab" | grep -v '^$' | while read -r what where type opts rest; do
    [[ ",$opts," == *,nofail,* && ",$opts," == *,x-systemd.before=local-fs.target,* ]] || { echo "$where: $opts"; exit 1; }
  done
  grep -qE '^RequiresMountsFor=/opt/ironflock$' "$units/ironflockos-proxy.service"
  ! grep -q '^\[Install\]' "$m"
  ! grep -q '/data' "$repo/profiles/installer/overlay/etc/fstab"
  grep -q 'mask ironflockos-factory-reset.service ironflockos-data-missing.service$' "$repo/build/customize.sh"
  ! grep -q 'factory-reset' "$repo/profiles/installer/overlay/usr/lib/ironflockos/installer"
  [ "$(cat "$repo/overlay/etc/hostname")" = ironflockos ]
  grep -qx 'image_hostname=ironflockos' "$reset"
}

@test "data-missing says that /data is missing, on the console and in /run for enroll and ironflockos-proxy" {
  run env IRONFLOCKOS_RUN="$tmp/run" sh "$repo/overlay/usr/lib/ironflockos/data-missing"
  [ "$status" -eq 0 ]
  [[ "$output" == *"THE DATA PARTITION COULD NOT BE MOUNTED"* ]]
  grep -q 'root slot' "$tmp/run/data-missing"
}
