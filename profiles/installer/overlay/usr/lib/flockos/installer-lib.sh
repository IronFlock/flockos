# shellcheck shell=bash
# shellcheck disable=SC2034 # the CONF_* variables are installer_conf's output
# Functions of flockos-installer (master plan, section 3.6; WP-3.1). Sourced
# by /usr/lib/flockos/installer and by the unit tests; does nothing by itself.
#
# installer.conf on the installer's FLOCKOS partition (KEY=value, all
# optional):
#   disk=largest | /dev/<name> | by-id:<id>   target disk (default largest)
#   confirm=yes | no        ask on the console before writing (default yes)
#   payload=<variant>       which embedded image when there are several (base, nvidia)
#   after=poweroff | reboot what to do when done (default poweroff)
#   allow-usb=no | yes      also offer USB disks as targets (default no)

INSTALLER_CONF_KEYS="disk confirm payload after allow-usb"

# installer_conf FILE: set CONF_DISK, CONF_CONFIRM, CONF_PAYLOAD, CONF_AFTER,
# CONF_ALLOW_USB from FILE (missing file: defaults). Values are validated;
# the file is data, never sourced.
installer_conf() {
  local file=$1 line key value n=0
  CONF_DISK=largest CONF_CONFIRM=yes CONF_PAYLOAD="" CONF_AFTER=poweroff CONF_ALLOW_USB=no
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%$'\r'}
    case "$line" in '' | '#'*) continue ;; esac
    if [[ ! "$line" =~ ^[[:space:]]*([a-z-]+)[[:space:]]*=[[:space:]]*([^[:space:]]*)[[:space:]]*$ ]]; then
      echo "installer.conf:$n: not a key=value line: $line" >&2
      return 1
    fi
    key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
    case "$key" in
      disk)
        [[ "$value" =~ ^(largest|/dev/[a-zA-Z0-9]+|by-id:[A-Za-z0-9_.:-]+)$ ]] || {
          echo "installer.conf:$n: disk must be largest, /dev/<name> or by-id:<id>" >&2
          return 1
        }
        CONF_DISK=$value
        ;;
      confirm | allow-usb)
        [[ "$value" =~ ^(yes|no)$ ]] || {
          echo "installer.conf:$n: $key must be yes or no" >&2
          return 1
        }
        if [ "$key" = confirm ]; then CONF_CONFIRM=$value; else CONF_ALLOW_USB=$value; fi
        ;;
      payload)
        [[ "$value" =~ ^[a-z0-9-]+$ ]] || {
          echo "installer.conf:$n: payload must be a variant name" >&2
          return 1
        }
        CONF_PAYLOAD=$value
        ;;
      after)
        [[ "$value" =~ ^(poweroff|reboot)$ ]] || {
          echo "installer.conf:$n: after must be poweroff or reboot" >&2
          return 1
        }
        CONF_AFTER=$value
        ;;
      *)
        echo "installer.conf:$n: unknown key $key (known: $INSTALLER_CONF_KEYS)" >&2
        return 1
        ;;
    esac
  done <"$file"
}

# installer_candidates JSON BOOT_DISK ALLOW_USB MIN_BYTES: the disks a
# payload may go to, one "name size transport model" line each, from
# `lsblk --json --bytes -d -o NAME,SIZE,TYPE,TRAN,RM,RO,MODEL`. Never the
# disk the installer runs from, never read-only, loop, zram or optical,
# never smaller than the payload, USB only when allowed.
installer_candidates() {
  local json=$1 boot=$2 allow_usb=$3 min=$4
  jq -r --arg boot "$boot" --arg usb "$allow_usb" --argjson min "$min" '
    .blockdevices[]
    | select(.type == "disk")
    | select(.name != $boot)
    | select((.ro | tostring) == "false" or (.ro | tostring) == "0")
    | select(.name | test("^(loop|zram|sr|ram|fd)") | not)
    | select((.size | tonumber) >= $min)
    | select($usb == "yes" or (.tran // "") != "usb")
    | "\(.name) \(.size) \(.tran // "-") \((.model // "-") | gsub(" "; "_"))"
  ' <<<"$json"
}

# installer_select RULE CANDIDATES [BYID_DIR]: the target device (/dev/...)
# for RULE among CANDIDATES (lines of installer_candidates).
installer_select() {
  local rule=$1 candidates=$2 byid=${3:-/dev/disk/by-id} name target
  [ -n "$candidates" ] || {
    echo "no disk to install to (the installer's own disk, USB disks and disks smaller than the image are left out)" >&2
    return 1
  }
  case "$rule" in
    largest)
      name=$(sort -k2,2nr <<<"$candidates" | head -n 1 | cut -d' ' -f1)
      ;;
    /dev/*)
      name=${rule#/dev/}
      ;;
    by-id:*)
      target=$(readlink -f "$byid/${rule#by-id:}" 2>/dev/null) || target=""
      [ -n "$target" ] && [ -e "$target" ] || {
        echo "no disk $byid/${rule#by-id:}" >&2
        return 1
      }
      name=${target##*/}
      ;;
    *)
      echo "unknown disk rule $rule" >&2
      return 1
      ;;
  esac
  if ! cut -d' ' -f1 <<<"$candidates" | grep -qx -- "$name"; then
    echo "/dev/$name is not a disk the installer may write (see the list of disks above)" >&2
    return 1
  fi
  printf '/dev/%s\n' "$name"
}

# installer_payload DIR VARIANT: the embedded image to install: the one for
# VARIANT, or the only one when VARIANT is empty.
installer_payload() {
  local dir=$1 variant=$2 found=()
  shopt -s nullglob
  if [ -n "$variant" ]; then
    found=("$dir"/flockos-*-"$variant"-*.img.zst)
  else
    found=("$dir"/flockos-*.img.zst)
  fi
  shopt -u nullglob
  case "${#found[@]}" in
    1) printf '%s\n' "${found[0]}" ;;
    0)
      echo "no payload${variant:+ for $variant} in $dir" >&2
      return 1
      ;;
    *)
      echo "several payloads in $dir; set payload= in installer.conf: $(basename -a "${found[@]}" | tr '\n' ' ')" >&2
      return 1
      ;;
  esac
}

# installer_partition DEVICE N: the device of partition N (sda1, nvme0n1p1).
installer_partition() {
  case "$1" in
    *[0-9]) printf '%sp%s\n' "$1" "$2" ;;
    *) printf '%s%s\n' "$1" "$2" ;;
  esac
}

# installer_loader [MACHINE]: the UEFI removable-media loader the written
# image boots from on this machine (uname -m), as EFI_LOADER in the targets.
installer_loader() {
  case "${1:-$(uname -m)}" in
    x86_64) echo '\EFI\BOOT\BOOTX64.EFI' ;;
    aarch64) echo '\EFI\BOOT\BOOTAA64.EFI' ;;
    *) return 1 ;;
  esac
}

# installer_human BYTES: a size for people.
installer_human() {
  awk -v b="$1" 'BEGIN { split("B KB MB GB TB", u); i = 1; while (b >= 1000 && i < 5) { b /= 1000; i++ } printf "%.1f %s\n", b, u[i] }'
}
