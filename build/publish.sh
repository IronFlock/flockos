#!/usr/bin/env bash
# Publishing a FlockOS release (docs/release.md; WP-2.6), from release.yml.
#   publish.sh sums    DIR           the release's SHA256SUMS, to stdout
#   publish.sh stage   DIR VERSION   DIR's images, bundles, SBOMs and checksums
#                                    to the staging tree STAGING/<version>/
#   publish.sh promote VERSION       the staged release to the live tree
#                                    LIVE/<version>/; a live file is never
#                                    replaced by different bytes
#   publish.sh catalog FILE          the signed catalog to LIVE/manifest.json, last
#   publish.sh check   VERSION FILE  every file of the release and the catalog
#                                    answer through the download proxy
#
# DIR has one directory per image (out/flockos-<image>/). DRY_RUN=1 prints the
# storage calls and changes nothing. gcloud runs as the publisher identity.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=build/lib.sh
. "$here/lib.sh"
load_conf "$here/release.conf"
STAGING=$BUCKET/staging/flockos
LIVE=$BUCKET/flockos

# done_ MESSAGE: what a step did, or would have done in a dry run.
done_() {
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "dry run, nothing changed: would have $*"
  else
    log "$*"
  fi
}

storage() {
  if [ "${DRY_RUN:-0}" = 1 ]; then
    printf '+ gcloud storage %s\n' "$*"
    return 0
  fi
  gcloud storage "$@"
}
# put LOCAL REMOTE: no caching anywhere, as devices must see a change at once.
put() { storage cp --quiet --cache-control="public, max-age=0" "$1" "$2"; }

# files DIR: the published files of a release, one per line.
files() {
  find "$1" -mindepth 2 -maxdepth 2 -type f \
    \( -name '*.img.gz' -o -name '*.raucb' -o -name '*.cdx.json' -o -name '*.os-release' -o -name '*.packages.tsv' \) | sort
}

# sums DIR: the release's SHA256SUMS, by file name.
sums() {
  files "$1" | while read -r f; do
    (cd "$(dirname "$f")" && sha256sum -- "$(basename "$f")")
  done
}

cmd=${1:-}
case "$cmd" in
  sums)
    sums "${2:?usage: publish.sh sums DIR}"
    ;;
  stage)
    dir=${2:?usage: publish.sh stage DIR VERSION} version=${3:?usage: publish.sh stage DIR VERSION}
    [ -n "$(files "$dir")" ] || die "no release files in $dir"
    # One SHA256SUMS for the release, by file name.
    sums=$(mktemp)
    trap 'rm -f "$sums"' EXIT
    sums "$dir" >"$sums"
    files "$dir" | while read -r f; do put "$f" "$STAGING/$version/$(basename "$f")"; done
    put "$sums" "$STAGING/$version/SHA256SUMS"
    done_ "staged $(wc -l <"$sums" | tr -d ' ') files to $STAGING/$version/"
    ;;
  promote)
    version=${2:?usage: publish.sh promote VERSION}
    if [ "${DRY_RUN:-0}" = 1 ]; then
      storage cp "$STAGING/$version/*" "$LIVE/$version/"
      done_ "promoted $STAGING/$version/ to $LIVE/$version/"
      exit 0
    fi
    storage ls "$STAGING/$version/" | while read -r src; do
      name=${src##*/}
      dest=$LIVE/$version/$name
      if storage objects describe "$dest" --format='value(name)' >/dev/null 2>&1; then
        [ "$(storage objects describe "$src" --format='value(md5_hash)')" = "$(storage objects describe "$dest" --format='value(md5_hash)')" ] ||
          die "$dest is live with different bytes"
      else
        storage cp --quiet --cache-control="public, max-age=0" "$src" "$dest"
      fi
    done
    done_ "promoted $STAGING/$version/ to $LIVE/$version/"
    ;;
  catalog)
    file=${2:?usage: publish.sh catalog FILE}
    put "$file" "$LIVE/manifest.json"
    done_ "published the catalog $LIVE/manifest.json"
    ;;
  check)
    version=${2:?usage: publish.sh check VERSION FILE} file=${3:?usage: publish.sh check VERSION FILE}
    require curl
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    # The small files byte for byte; every other file answers with the size
    # of its object in the bucket (the proxy serves the bucket's bytes).
    curl -fsS --proto '=https' --retry 5 -o "$tmp/SHA256SUMS" "$DL_BASE/flockos/$version/SHA256SUMS" ||
      die "$DL_BASE/flockos/$version/SHA256SUMS does not answer: does the download proxy serve /dl/flockos/?"
    storage cat "$LIVE/$version/SHA256SUMS" | cmp -s - "$tmp/SHA256SUMS" || die "the proxy's SHA256SUMS is not the live one"
    while read -r _ name; do
      want=$(storage objects describe "$LIVE/$version/$name" --format='value(size)')
      got=$(curl -fsSI --proto '=https' --retry 5 "$DL_BASE/flockos/$version/$name" | tr -d '\r' |
        awk 'tolower($1) == "content-length:" { print $2 }' | tail -n 1)
      [ -n "$got" ] && [ "$got" = "$want" ] || die "$name answers with ${got:-no} bytes, the bucket holds $want"
    done <"$tmp/SHA256SUMS"
    curl -fsS --proto '=https' --retry 5 -o "$tmp/manifest.json" "$DL_BASE/flockos/manifest.json" || die "the catalog does not answer"
    cmp -s "$tmp/manifest.json" "$file" || die "the catalog the proxy serves is not the one published"
    log "every file of $version and the catalog answer through $DL_BASE/flockos/"
    ;;
  *) die "usage: publish.sh stage|promote|catalog|check ..." ;;
esac
