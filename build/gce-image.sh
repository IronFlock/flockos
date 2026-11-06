#!/usr/bin/env bash
# The Compute Engine image of one FlockOS image of a release (ADR-0010,
# docs/release.md), from release.yml: a boot image of the
# virtual-device-manager's FlockOS VMs.
#
#   gce-image.sh DIR VERSION [SUMS]
#
# DIR is the image's directory as the build left it (out/flockos-<image>/,
# <image> one of GCE_IMAGES in build/release.conf); SUMS is the release's
# SHA256SUMS, which the image must match, so the VM image is made from the
# published file. It writes the image as the disk.raw of a Compute Engine
# tarball, sparse and grown to the smallest disk the FlockOS layout fits,
# puts the tarball into the staging tree (STAGING/<version>/gce/), makes the
# image flockos-<image>-v<version> in the family flockos-<image> from it, and
# removes the tarball. An image of that name that exists already is kept when
# it was made from the same file (a re-run of the release); made from another
# file, it is an error.
#
# DRY_RUN=1 makes the tarball and prints the cloud calls. FLOCKOS_WORK is the
# scratch space (default: TMPDIR). gcloud runs as the publisher identity.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
# shellcheck source=build/lib.sh
. "$here/lib.sh"
load_conf "$here/release.conf"

usage="usage: gce-image.sh DIR VERSION [SUMS]"
dir=${1:?$usage} version=${2:?$usage} sums=${3:-}
dir=${dir%/}
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "not a release version: $version"
id=$(basename "$dir")
image=${id#flockos-}
case " $GCE_IMAGES " in
  *" $image "*) ;;
  *) die "$id has no Compute Engine image (GCE_IMAGES in build/release.conf: $GCE_IMAGES)" ;;
esac
target=${image%-*} variant=${image##*-}
file=$id-$version.img.gz
[ -f "$dir/$file" ] || die "no $dir/$file"
require gzip tar dd truncate sha256sum

# The machine. Both targets boot UEFI and drive gVNIC (C4A has no other NIC);
# amd64 VMs also take a multi-queue virtio-scsi disk.
load_conf "$repo/targets/$target/target.conf"
case "$ARCH" in
  amd64) gce_arch=X86_64 features=UEFI_COMPATIBLE,GVNIC,VIRTIO_SCSI_MULTIQUEUE ;;
  arm64) gce_arch=ARM64 features=UEFI_COMPATIBLE,GVNIC ;;
  *) die "$target: no Compute Engine architecture for $ARCH" ;;
esac
# The smallest disk, in whole GiB (Compute Engine takes nothing else): the
# GPT and its 1 MiB in front of the first partition and at the end, both
# slots, the FLOCKOS partition and the least /data.
slot_var=SLOT_SIZE_${variant^^}
[ -n "${!slot_var:-}" ] || die "$target has no $slot_var"
mib=$((1024 * 1024))
gib=$((1024 * mib))
min=$((2 * mib + 2 * $(size_bytes "${!slot_var}") + $(size_bytes "$ESP_SIZE") + $(size_bytes "$GCE_DATA_MIN")))
min_gib=$(((min + gib - 1) / gib))

sha=$(sha256sum "$dir/$file" | cut -d' ' -f1)
if [ -n "$sums" ]; then
  want=$(awk -v f="$file" '$2 == f { print $1 }' "$sums")
  [ -n "$want" ] || die "$file is not in $sums"
  [ "$want" = "$sha" ] || die "$file is not the published file: its sha256 is $sha, $sums names $want"
fi

tag=${version//./-}
name=flockos-$image-v$tag
family=flockos-$image
gcs=$BUCKET/staging/flockos/$version/gce/$name.tar.gz
description="FlockOS $version $target $variant for virtual devices: $DL_BASE/flockos/$version/$file sha256 $sha"
labels=flockos-version=$tag,flockos-target=$target,flockos-variant=$variant

cloud() {
  if [ "${DRY_RUN:-0}" = 1 ]; then
    printf '+ gcloud %s\n' "$*"
    return 0
  fi
  gcloud "$@"
}

# A re-run of the release: the image is there, made from this file.
if [ "${DRY_RUN:-0}" != 1 ] &&
  existing=$(gcloud compute images describe "$name" --project "$GCE_PROJECT" --format='value(description)' 2>/dev/null); then
  [[ "$existing" == *"sha256 $sha"* ]] || die "the image $name exists, made from another file: $existing"
  log "the image $name exists, made from $file: kept"
  exit 0
fi

work=$(mktemp -d "${FLOCKOS_WORK:-${TMPDIR:-/tmp}}/gce-image.XXXXXX")
trap 'rm -rf "$work"' EXIT
# Sparse all the way: dd skips the blocks of zeros, tar -S stores only data.
gzip -dc "$dir/$file" | dd of="$work/disk.raw" bs=1M iflag=fullblock conv=sparse status=none
raw=$(stat -c %s "$work/disk.raw")
size_gib=$(((raw + gib - 1) / gib))
[ "$size_gib" -ge "$min_gib" ] || size_gib=$min_gib
truncate -s $((size_gib * gib)) "$work/disk.raw"
tar --format=oldgnu -Sczf "$work/$name.tar.gz" -C "$work" disk.raw
rm -f "$work/disk.raw"
log "$name.tar.gz: a disk of $size_gib GiB from $file, $(du -h "$work/$name.tar.gz" | cut -f1) compressed"

cloud storage cp --quiet "$work/$name.tar.gz" "$gcs"
if ! cloud compute images create "$name" --project "$GCE_PROJECT" --source-uri "$gcs" \
  --family "$family" --architecture "$gce_arch" --guest-os-features "$features" \
  --storage-location "$GCE_STORAGE_LOCATION" --description "$description" --labels "$labels"; then
  cloud storage rm --quiet "$gcs" || true
  die "Compute Engine did not make the image $name"
fi
cloud storage rm --quiet "$gcs"
if [ "${DRY_RUN:-0}" = 1 ]; then
  log "dry run, nothing changed: would have made the image $name (family $family, $size_gib GiB) from $file"
else
  log "made the image $name (family $family, $size_gib GiB) from $file"
fi
