#!/usr/bin/env bash
# Build one image in the build container (build/builder.conf).
#   run-in-builder.sh TARGET VARIANT [KERNEL]
#
# Runs on the host (a GitHub runner, or a developer machine with Docker for
# debugging; CI is the build of record). Takes version, commit and time from
# git, runs build/in-builder.sh in a privileged container (mmdebstrap needs
# mounts), and leaves the artefacts in out/<image-id>/.
#
# Env:
#   FLOCKOS_WORK  scratch for the rootfs and images: a host directory on a
#                 native Linux filesystem (CI: /mnt/flockos-work), or the
#                 name of a Docker volume (default: flockos-work), which is
#                 what macOS needs (its bind mounts cannot hold a rootfs)
#   FLOCKOS_OUT   artefact directory (default: out)
#   FLOCKOS_SIGNING  dev (default: throwaway keys) or release (WP-1.6)
#   FLOCKOS_STAGES   all (default) or rootfs: stop after the customisation
#                    and leave the root tree in FLOCKOS_WORK/<image-id>/rootfs
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
# shellcheck source=build/lib.sh
. "$here/lib.sh"

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || die "usage: run-in-builder.sh TARGET VARIANT [KERNEL]"
target=$1 variant=$2 kernel=${3:-std}
valid_target "$target" || die "unknown target $target"
valid_variant "$variant" || die "unknown variant $variant"
valid_kernel "$kernel" || die "unknown kernel $kernel"
[ -f "$repo/targets/$target/target.conf" ] || die "target $target is not implemented yet (see docs/implementation-plan.md)"
require docker git

load_conf "$here/builder.conf"
load_conf "$repo/targets/$target/target.conf"

version=$(tr -d '[:space:]' <"$repo/VERSION")
commit=$(git -C "$repo" rev-parse HEAD)
epoch=$(git -C "$repo" log -1 --format=%ct)
dirty=""
if [ -n "$(git -C "$repo" status --porcelain --untracked-files=no)" ]; then
  dirty="-dirty"
  warn "the working tree has uncommitted changes: BUILD_ID ends in -dirty"
fi

work=${FLOCKOS_WORK:-flockos-work}
case "$work" in
  /*) mkdir -p "$work" && work_mount="$work:/work" ;;
  *) work_mount="$work:/work" ;;
esac
out=${FLOCKOS_OUT:-$repo/out}
mkdir -p "$out"
out=$(cd "$out" && pwd)

log "building $(image_id "$target" "$variant" "$kernel") $version ($commit$dirty) in $BUILDER_IMAGE"
docker run --rm --privileged \
  --platform "linux/$ARCH" \
  -v "$repo:/src:ro" \
  -v "$work_mount" \
  -v "$out:/out" \
  -e FLOCKOS_VERSION="$version" \
  -e FLOCKOS_COMMIT="$commit" \
  -e FLOCKOS_DIRTY="$dirty" \
  -e SOURCE_DATE_EPOCH="$epoch" \
  -e FLOCKOS_SIGNING="${FLOCKOS_SIGNING:-dev}" \
  -e FLOCKOS_STAGES="${FLOCKOS_STAGES:-all}" \
  -e FLOCKOS_HOST_UID="$(id -u)" \
  -e FLOCKOS_HOST_GID="$(id -g)" \
  "$BUILDER_IMAGE" \
  bash /src/build/in-builder.sh "$target" "$variant" "$kernel"
