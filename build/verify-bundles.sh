#!/usr/bin/env bash
# The signed bundles against the keyring their images carry (ADR-0019,
# docs/signing.md).
#   verify-bundles.sh release|dry-run DIR
#
# Runs in the build container after build/sign-bundles.sh
# (build/sign-in-builder.sh). DIR holds one directory per image
# (out/<image-id>/). For each bundle, the keyring comes from the disk image
# next to it: /etc/rauc/keyring.pem in slot A (the partition rootfs-a of
# <name>.img.gz), the keyring a device installed from that image checks its
# updates with. The bundle is checked against it as the device checks it
# (code-signing purpose, the signing time). sign-bundles.sh checks against
# pki/ironflockos-root-ca.pem; this checks the image itself.
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
require rauc openssl sfdisk debugfs jq gzip dd

# The certificate the release signs with (build/sign-bundles.sh).
signer=$(printf '%s\n' "$src"/pki/ironflockos-bundle-signer-*.pem | sort -V | tail -n 1)
[ -f "$signer" ] || die "no bundle signer certificate in pki/"

work=$(mktemp -d "${IRONFLOCKOS_WORK:-${TMPDIR:-/tmp}}/verify-bundles.XXXXXX")
trap 'rm -rf "$work"' EXIT

# image_keyring IMG_GZ OUT: /etc/rauc/keyring.pem of slot A of the image.
image_keyring() {
  local img=$1 out=$2 disk=$work/disk.img slot=$work/slot.ext4 part start size unit
  rm -f "$disk" "$slot" "$out"
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
  debugfs -R "cat /etc/rauc/keyring.pem" "$slot" >"$out" 2>"$work/debugfs.log" || true
  rm -f "$slot"
  if ! grep -q -- '-----BEGIN CERTIFICATE-----' "$out" || ! openssl x509 -in "$out" -noout 2>/dev/null; then
    cat "$work/debugfs.log" >&2
    die "$(basename "$img") carries no RAUC keyring in slot A (/etc/rauc/keyring.pem)"
  fi
}

# check KEYRING COMPATIBLE BUNDLE: verify as the device does (its system.conf:
# the keyring, code-signing purpose, the signing time).
check() {
  printf '[system]\ncompatible=%s\nbootloader=noop\n\n[keyring]\npath=%s\nuse-bundle-signing-time=true\ncheck-purpose=codesign\n' \
    "$2" "$1" >"$work/image.conf"
  rauc --conf="$work/image.conf" info "$3" >"$work/image.info" 2>&1 &&
    grep -q "Compatible:.*'$2'" "$work/image.info"
}

n=0
for bundle in "$dir"/*/*.raucb; do
  [ -f "$bundle" ] || continue
  d=$(dirname "$bundle")
  id=$(basename "$d")
  name=$(basename "$bundle" .raucb)
  img=$d/$name.img.gz
  [ -f "$img" ] || die "$name.raucb has no disk image next to it ($name.img.gz)"
  keyring=$work/keyring.pem
  image_keyring "$img" "$keyring"
  ca=$(openssl x509 -in "$keyring" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')
  openssl verify -purpose any -CAfile "$keyring" "$signer" >/dev/null 2>&1 ||
    die "the keyring of $name.img.gz ($ca) does not accept the bundle signer $(basename "$signer")"
  # RAUC checks a bundle's payload only where nothing else can change the
  # file meanwhile: a copy of root's own, not the bind-mounted original.
  cp "$bundle" "$work/bundle.raucb"
  if [ "$mode" = release ]; then
    check "$keyring" "$id" "$work/bundle.raucb" || {
      cat "$work/image.info" >&2
      die "$name.raucb does not verify against the keyring of $name.img.gz ($ca)"
    }
    log "$name.raucb verifies against the keyring of $name.img.gz ($ca)"
  else
    if check "$keyring" "$id" "$work/bundle.raucb"; then
      die "$name.raucb, signed by the dry-run stand-in, verifies against the keyring of $name.img.gz ($ca)"
    fi
    log "$name.raucb (dry-run stand-in) is refused by the keyring of $name.img.gz ($ca), which accepts the bundle signer"
  fi
  rm -f "$work/bundle.raucb" "$keyring"
  n=$((n + 1))
done
[ "$n" -gt 0 ] || die "no bundles in $dir/*/"
log "$n bundles checked against the keyrings of their images ($mode)"
