#!/usr/bin/env bash
# Print /usr/lib/os-release of a FlockOS image (master plan, section 3.1).
#   osrelease.sh VERSION TARGET VARIANT KERNEL COMMIT EPOCH
# COMMIT is the git commit the image is built from, EPOCH its time
# (SOURCE_DATE_EPOCH). VERSION keeps the legacy v<ver>-g<sha>-<buildtime>
# shape the device-agent parses until it reads IMAGE_ID/IMAGE_VERSION/BUILD_ID.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=build/lib.sh
. "$here/lib.sh"

[ "$#" -eq 6 ] || die "usage: osrelease.sh VERSION TARGET VARIANT KERNEL COMMIT EPOCH"
version=$1 target=$2 variant=$3 kernel=$4 commit=$5 epoch=$6
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$ ]] || die "not a version: $version"
valid_target "$target" || die "unknown target $target"
valid_variant "$variant" || die "unknown variant $variant"
valid_kernel "$kernel" || die "unknown kernel $kernel"
[[ "$commit" =~ ^[0-9a-f]{7,40}$ ]] || die "not a commit: $commit"
[[ "$epoch" =~ ^[0-9]+$ ]] || die "not an epoch: $epoch"

short=${commit:0:7}
stamp=$(date -u -d "@$epoch" +%Y%m%dT%H%M%S 2>/dev/null || date -u -r "$epoch" +%Y%m%dT%H%M%S)
id=$(image_id "$target" "$variant" "$kernel")
detail="$target, $variant"
[ "$kernel" = rt ] && detail="$detail, rt"

cat <<OSR
NAME="FlockOS"
ID=flockos
ID_LIKE=debian
PRETTY_NAME="FlockOS $version ($detail)"
VERSION_ID="$version"
VERSION="v$version-g$short-$stamp"
IMAGE_ID=$id
IMAGE_VERSION=$version
VARIANT="$variant"
VARIANT_ID=$variant
BUILD_ID=${stamp}Z-g$short
HOME_URL="https://www.ironflock.com"
SUPPORT_URL="https://github.com/IronFlock/flockos"
BUG_REPORT_URL="https://github.com/IronFlock/flockos/issues"
OSR
