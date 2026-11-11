#!/usr/bin/env bash
# The signed bundles against the keyring their images carry (ADR-0019,
# docs/signing.md).
#   verify-bundles.sh release|dry-run DIR
#
# Runs in a build container of its own after build/sign-bundles.sh
# (build/sign-in-builder.sh), without the release identity: of the
# repository it gets and reads only this script, build/lib.sh and pki/, and
# it only reads DIR. DIR holds one directory per image (out/<image-id>/).
# For each bundle, the keyring and the RAUC settings come from the disk image
# next to it: /etc/rauc/keyring.pem and /etc/rauc/system.conf in slot A (the
# partition rootfs-a of <name>.img.gz), which a device installed from that
# image checks its updates with. sign-bundles.sh checks against
# pki/ironflockos-root-ca.pem; this checks the image itself.
#
# rauc info gets the image's own settings for the check (rauc_conf): from
# [system] compatible and bundle-formats, and the whole [keyring] section,
# its path= naming the keyring read from the image. It does not get the
# image's slots, bootloader, handlers and data directory, which a signature
# check does not read; bootloader is noop. The bundle's compatible must be
# the image's, as an install requires.
#
# release  every bundle must verify against its image's keyring.
# dry-run  the stand-in's bundles must not: a release image refuses them.
#
# In both modes the newest bundle signer certificate of pki/ must chain to the
# image's keyring, so a dry run shows that the release signer's bundles will
# fit its images.
#
# IRONFLOCKOS_WORK is the scratch space (default: TMPDIR): each image is
# unpacked there, sparse.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/.." && pwd)
# shellcheck source=build/lib.sh
. "$here/lib.sh"

mode=${1:-}
dir=${2:-}
case "$mode" in
  release | dry-run) ;;
  *) die "usage: verify-bundles.sh release|dry-run DIR" ;;
esac
[ -d "$dir" ] || die "usage: verify-bundles.sh release|dry-run DIR ($dir is no directory)"
require rauc openssl sfdisk debugfs jq gzip dd awk

# The certificate the release signs with (build/sign-bundles.sh).
signer=$(printf '%s\n' "$src"/pki/ironflockos-bundle-signer-*.pem | sort -V | tail -n 1)
[ -f "$signer" ] || die "no bundle signer certificate in pki/"

work=$(mktemp -d "${IRONFLOCKOS_WORK:-${TMPDIR:-/tmp}}/verify-bundles.XXXXXX")
trap 'rm -rf "$work"' EXIT

# image_rauc IMG_GZ: /etc/rauc/keyring.pem and /etc/rauc/system.conf of
# slot A of the image, as $work/keyring.pem and $work/system.conf.
image_rauc() {
  local img=$1 disk=$work/disk.img slot=$work/slot.ext4 part start size unit f
  rm -f "$disk" "$slot" "$work/keyring.pem" "$work/system.conf"
  gzip -dc "$img" | dd of="$disk" bs=1M iflag=fullblock conv=sparse status=none ||
    die "$(basename "$img") does not unpack"
  part=$(sfdisk --json "$disk" | jq -r '.partitiontable | (.sectorsize // 512) as $unit
      | [.partitions[] | select(.name == "rootfs-a")]
      | if length == 1 then "\(.[0].start) \(.[0].size) \($unit)" else empty end') ||
    die "$(basename "$img") has no partition table sfdisk reads"
  read -r start size unit <<<"$part" || true
  [[ "${start:-}" =~ ^[0-9]+$ && "${size:-}" =~ ^[1-9][0-9]*$ && "${unit:-}" =~ ^[1-9][0-9]*$ ]] ||
    die "$(basename "$img") has no single partition rootfs-a"
  dd if="$disk" of="$slot" bs=1M iflag=skip_bytes,count_bytes skip=$((start * unit)) count=$((size * unit)) \
    conv=sparse status=none
  rm -f "$disk"
  # debugfs reports a missing file on stderr, not in its exit status.
  for f in keyring.pem system.conf; do
    debugfs -R "cat /etc/rauc/$f" "$slot" >"$work/$f" 2>>"$work/debugfs.log" || true
  done
  rm -f "$slot"
  if ! grep -q -- '-----BEGIN CERTIFICATE-----' "$work/keyring.pem" || ! openssl x509 -in "$work/keyring.pem" -noout 2>/dev/null; then
    cat "$work/debugfs.log" >&2
    die "$(basename "$img") carries no RAUC keyring in slot A (/etc/rauc/keyring.pem)"
  fi
  grep -q '^\[keyring\]' "$work/system.conf" || {
    cat "$work/debugfs.log" >&2
    die "$(basename "$img") carries no RAUC system.conf with a keyring in slot A (/etc/rauc/system.conf)"
  }
}

# rauc_conf SYSTEM_CONF KEYRING: the image's settings for rauc info (see the
# top), the keyring KEYRING. Fails on a [keyring] section without exactly one
# path=, with a directory=, or a [system] section without compatible=.
rauc_conf() {
  awk -v keyring="$2" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    /^[ \t]*\[/ { sec = trim($0); next }
    /^[ \t]*(#|;|$)/ || index($0, "=") == 0 { next }
    {
      key = trim(substr($0, 1, index($0, "=") - 1)); value = trim(substr($0, index($0, "=") + 1))
      if (sec == "[system]" && (key == "compatible" || key == "bundle-formats")) sys[key] = value
      if (sec == "[keyring]") {
        if (key == "directory") bad = 1
        if (key == "path") { paths++; value = keyring }
        settings = settings key "=" value "\n"
      }
    }
    END {
      if (bad || paths != 1 || sys["compatible"] == "") exit 1
      print "[system]"
      print "compatible=" sys["compatible"]
      print "bootloader=noop"
      if ("bundle-formats" in sys) print "bundle-formats=" sys["bundle-formats"]
      print ""
      print "[keyring]"
      printf "%s", settings
    }' "$1"
}

# check CONF BUNDLE: rauc info of BUNDLE with CONF; its output in $work/info.
check() {
  rauc --conf="$1" info "$2" >"$work/info" 2>&1
}

n=0
for bundle in "$dir"/*/*.raucb; do
  [ -f "$bundle" ] || continue
  d=$(dirname "$bundle")
  id=$(basename "$d")
  name=$(basename "$bundle" .raucb)
  img=$d/$name.img.gz
  [ -f "$img" ] || die "$name.raucb has no disk image next to it ($name.img.gz)"
  image_rauc "$img"
  keyring=$work/keyring.pem
  rauc_conf "$work/system.conf" "$keyring" >"$work/image.conf" ||
    die "$name.img.gz: its /etc/rauc/system.conf has no compatible, or no single keyring path, or a keyring directory"
  compatible=$(sed -n 's/^compatible=//p' "$work/image.conf")
  [ "$compatible" = "$id" ] || die "$name.img.gz is compatible $compatible, not $id"
  ca=$(openssl x509 -in "$keyring" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')
  openssl verify -purpose any -CAfile "$keyring" "$signer" >/dev/null 2>&1 ||
    die "the keyring of $name.img.gz ($ca) does not accept the bundle signer $(basename "$signer")"
  # RAUC checks a bundle's payload only where nothing else can change the
  # file meanwhile: a copy of root's own, not the bind-mounted original.
  cp "$bundle" "$work/bundle.raucb"
  if [ "$mode" = release ]; then
    check "$work/image.conf" "$work/bundle.raucb" || {
      cat "$work/info" >&2
      die "$name.raucb does not verify against the keyring of $name.img.gz ($ca)"
    }
    grep -q "Compatible:.*'$compatible'" "$work/info" || {
      cat "$work/info" >&2
      die "$name.raucb is not compatible $compatible, as its image is"
    }
    log "$name.raucb verifies against the keyring of $name.img.gz ($ca)"
  else
    if check "$work/image.conf" "$work/bundle.raucb"; then
      die "$name.raucb, signed by the dry-run stand-in, verifies against the keyring of $name.img.gz ($ca)"
    fi
    log "$name.raucb (dry-run stand-in) is refused by the keyring of $name.img.gz ($ca), which accepts the bundle signer"
  fi
  rm -f "$work/bundle.raucb" "$keyring" "$work/system.conf" "$work/image.conf"
  n=$((n + 1))
done
[ "$n" -gt 0 ] || die "no bundles in $dir/*/"
log "$n bundles checked against the keyrings of their images ($mode)"
