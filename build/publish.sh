#!/usr/bin/env bash
# Publishing an IronFlockOS release (docs/release.md; WP-2.6), from release.yml.
#   publish.sh sums    DIR           the release's SHA256SUMS, to stdout
#   publish.sh files   DIR           each published file's sha256, size and
#                                    name (tab-separated), to stdout: what
#                                    tools/catalog build -files reads
#   publish.sh meta    DIR META      what the later jobs need of DIR, into META:
#                                    SHA256SUMS, files.tsv (files, above), the
#                                    SBOMs, sources.tsv (every image's source
#                                    packages) and catalog/<image>/ (each
#                                    image's os-release, sizes and payloads):
#                                    no image or bundle
#   publish.sh stage   DIR VERSION   DIR's images, bundles, SBOMs, hardware
#                                    lists and checksums to the staging tree
#                                    STAGING/<version>/
#   publish.sh promote VERSION       the staged release to the live tree
#                                    LIVE/<version>/; a live file is never
#                                    replaced by different bytes
#   publish.sh sources PLAN VERSION  the release's source code (a plan of
#                                    build/sources.sh): the files the pool
#                                    LIVE/sources/ lacks to it, the index
#                                    SOURCES to STAGING/<version>/
#   publish.sh notes   DIR           the release notes DIR/<x.y.z>.md as
#                                    LIVE/release-notes.json ({version:
#                                    markdown}, {} without any), before the
#                                    catalog
#   publish.sh catalog FILE          the signed catalog to LIVE/manifest.json, last
#   publish.sh check   VERSION FILE  every file of the release and the catalog
#                                    answer through the download proxy
#
# DIR has one directory per image (out/ironflockos-<image>/). DRY_RUN=1 prints the
# storage calls and changes nothing. gcloud runs as the publisher identity.
# stage, promote and check work on PUBLISH_JOBS files at a time (default 8);
# every one of them must succeed.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=build/lib.sh
. "$here/lib.sh"
load_conf "$here/release.conf"
STAGING=$BUCKET/staging/ironflockos
LIVE=$BUCKET/ironflockos

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

# files DIR: the published files of a release, one per line: also each
# image's hardware list (.modules.alias.gz), which the catalog names.
files() {
  find "$1" -mindepth 2 -maxdepth 2 -type f \
    \( -name '*.img.gz' -o -name '*.raucb' -o -name '*.cdx.json' -o -name '*.os-release' -o -name '*.packages.tsv' \
    -o -name '*.modules.alias.gz' \) | sort
}

# sums DIR: the release's SHA256SUMS, by file name.
sums() {
  files "$1" | while read -r f; do
    (cd "$(dirname "$f")" && sha256sum -- "$(basename "$f")")
  done
}

# list_files DIR: each published file's sha256, size and name, tab-separated.
list_files() {
  files "$1" | while read -r f; do
    printf '%s\t%s\t%s\n' "$(sha256sum <"$f" | cut -d' ' -f1)" "$(wc -c <"$f" | tr -d ' ')" "$(basename "$f")"
  done
}

# each CMD...: CMD LINE for every line of stdin, PUBLISH_JOBS at a time.
# Waits for all of them; fails when any one failed (each exit code counts).
each() {
  local jobs=${PUBLISH_JOBS:-8} line rc=0 pids=()
  [[ "$jobs" =~ ^[1-9][0-9]*$ ]] || die "PUBLISH_JOBS must be a number: $jobs"
  while IFS= read -r line; do
    "$@" "$line" &
    pids+=("$!")
    if [ "${#pids[@]}" -ge "$jobs" ]; then
      wait "${pids[0]}" || rc=1
      pids=("${pids[@]:1}")
    fi
  done
  for p in ${pids[@]+"${pids[@]}"}; do
    wait "$p" || rc=1
  done
  return "$rc"
}

# stage_one VERSION FILE: one file to the staging tree.
stage_one() { put "$2" "$STAGING/$1/$(basename "$2")"; }

# promote_one VERSION SRC: one staged object to the live tree, unless it is
# live already, which must then hold the same bytes.
promote_one() {
  local src=$2 dest
  dest=$LIVE/$1/${src##*/}
  if storage objects describe "$dest" --format='value(name)' >/dev/null 2>&1; then
    [ "$(storage objects describe "$src" --format='value(md5_hash)')" = "$(storage objects describe "$dest" --format='value(md5_hash)')" ] ||
      die "$dest is live with different bytes"
  else
    storage cp --quiet --cache-control="public, max-age=0" "$src" "$dest"
  fi
}

# check_one VERSION LINE: a line of SHA256SUMS answers through the download
# proxy with the size of its object in the bucket.
check_one() {
  local name want got
  name=${2#*  }
  want=$(storage objects describe "$LIVE/$1/$name" --format='value(size)')
  got=$(curl -fsSI --proto '=https' --retry 5 "$DL_BASE/ironflockos/$1/$name" | tr -d '\r' |
    awk 'tolower($1) == "content-length:" { print $2 }' | tail -n 1)
  [ -n "$got" ] && [ "$got" = "$want" ] || die "$name answers with ${got:-no} bytes, the bucket holds $want"
}

# hash_ok FILE HASH: FILE has the hash a plan names ("-": none to check).
hash_ok() {
  local got
  case "$2" in
    -) return 0 ;;
    SHA256:*) got=$(sha256sum <"$1") ;;
    SHA1:*) got=$(sha1sum <"$1") ;;
    *) die "$1: unknown hash $2" ;;
  esac
  [ "${got%% *}" = "${2#*:}" ]
}

cmd=${1:-}
case "$cmd" in
  sums)
    sums "${2:?usage: publish.sh sums DIR}"
    ;;
  files)
    list_files "${2:?usage: publish.sh files DIR}"
    ;;
  meta)
    dir=${2:?usage: publish.sh meta DIR META} meta=${3:?usage: publish.sh meta DIR META}
    [ -n "$(files "$dir")" ] || die "no release files in $dir"
    mkdir -p "$meta/catalog"
    list_files "$dir" >"$meta/files.tsv"
    awk -F'\t' '{ print $1 "  " $3 }' "$meta/files.tsv" >"$meta/SHA256SUMS"
    cp "$dir"/*/*.cdx.json "$meta/"
    cat "$dir"/*/*.sources.tsv | LC_ALL=C sort -u >"$meta/sources.tsv"
    for d in "$dir"/ironflockos-*/; do
      id=$(basename "$d")
      mkdir "$meta/catalog/$id"
      cp "$d"*.os-release "$d"*.sizes "$meta/catalog/$id/"
      if compgen -G "$d*.payloads" >/dev/null; then cp "$d"*.payloads "$meta/catalog/$id/"; fi
    done
    log "$(wc -l <"$meta/files.tsv" | tr -d ' ') files of $(find "$meta/catalog" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ') images listed in $meta"
    ;;
  stage)
    dir=${2:?usage: publish.sh stage DIR VERSION} version=${3:?usage: publish.sh stage DIR VERSION}
    [ -n "$(files "$dir")" ] || die "no release files in $dir"
    # One SHA256SUMS for the release, by file name.
    sums=$(mktemp)
    trap 'rm -f "$sums"' EXIT
    sums "$dir" >"$sums"
    # The files side by side, SHA256SUMS once every one of them is there.
    files "$dir" | each stage_one "$version"
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
    storage ls "$STAGING/$version/" | each promote_one "$version"
    done_ "promoted $STAGING/$version/ to $LIVE/$version/"
    ;;
  sources)
    # Every release names its source files in SOURCES, so a file in the pool
    # is never replaced (no-clobber); one that is there is not downloaded
    # again. A downloaded file must have the plan's hash, which apt took
    # from the archive's signed index. SOURCES goes to the staging tree, and
    # promote publishes it with the release. A dry run downloads nothing.
    plan=${2:?usage: publish.sh sources PLAN VERSION} version=${3:?usage: publish.sh sources PLAN VERSION}
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    bash "$here/sources.sh" index "$plan" "$version" >"$tmp/SOURCES"
    # pool path, URL, hash; one line per path (two versions of a source
    # package share their orig tarball, maybe one from the archive and one
    # from snapshot.debian.org)
    awk -F'\t' '$3 != "-" { print $3 "\t" $4 "\t" $5 }' "$plan" | LC_ALL=C sort -t "$(printf '\t')" -k 1,1 -u >"$tmp/files"
    bad=$(cut -f 1 "$tmp/files" | grep -vE '^(debian|raspberrypi|upstream)/[a-z0-9][a-z0-9+.-]*/[A-Za-z0-9][A-Za-z0-9+._~-]*$' || true)
    [ -z "$bad" ] || die "not a path in the pool: $(echo "$bad" | tr '\n' ' ')"
    if [ "${DRY_RUN:-0}" = 1 ]; then
      cp "$tmp/files" "$tmp/new"
      storage cp --recursive --no-clobber --quiet --cache-control="public, max-age=0" "<the new files>/*" "$LIVE/sources/"
    else
      require curl
      # No pool yet (or no listing): every file is downloaded, and
      # no-clobber still keeps what is there.
      { storage ls "$LIVE/sources/**" 2>/dev/null || true; } | sed -n "s|^$LIVE/sources/||p" >"$tmp/pool"
      awk -F'\t' -v pool="$tmp/pool" 'BEGIN { while ((getline p <pool) > 0) have[p] = 1 } !($1 in have)' "$tmp/files" >"$tmp/new"
      while IFS=$'\t' read -r path url hash; do
        mkdir -p "$tmp/up/${path%/*}"
        curl -fsSL --proto '=http,https' --retry 5 -o "$tmp/up/$path" "$url" || die "cannot download $url"
        hash_ok "$tmp/up/$path" "$hash" || die "$url is not the file the plan names ($hash)"
      done <"$tmp/new"
      if [ -s "$tmp/new" ]; then
        storage cp --recursive --no-clobber --quiet --cache-control="public, max-age=0" "$tmp/up"/* "$LIVE/sources/"
      fi
    fi
    put "$tmp/SOURCES" "$STAGING/$version/SOURCES"
    done_ "uploaded $(wc -l <"$tmp/new" | tr -d ' ') of the release's $(wc -l <"$tmp/files" | tr -d ' ') source files to $LIVE/sources/, staged $STAGING/$version/SOURCES"
    ;;
  notes)
    # The cloud emails a new production release with its notes (the System
    # emails of the profile), and only a release that has notes. Published
    # with every release, {} included, before the catalog names the release.
    dir=${2:?usage: publish.sh notes DIR}
    require jq
    json=$(mktemp)
    trap 'rm -f "$json"' EXIT
    shopt -s nullglob
    for f in "$dir"/*.md; do
      [[ "$(basename "$f")" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.md$ ]] || die "$f: the name must be <x.y.z>.md"
    done
    for f in "$dir"/*.md; do
      jq -n --arg v "$(basename "$f" .md)" --rawfile n "$f" '{($v): $n}'
    done | jq -s 'add // {}' >"$json"
    put "$json" "$LIVE/release-notes.json"
    done_ "published the release notes of $(jq length "$json") version(s) as $LIVE/release-notes.json"
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
    curl -fsS --proto '=https' --retry 5 -o "$tmp/SHA256SUMS" "$DL_BASE/ironflockos/$version/SHA256SUMS" ||
      die "$DL_BASE/ironflockos/$version/SHA256SUMS does not answer: does the download proxy serve /dl/ironflockos/?"
    storage cat "$LIVE/$version/SHA256SUMS" | cmp -s - "$tmp/SHA256SUMS" || die "the proxy's SHA256SUMS is not the live one"
    each check_one "$version" <"$tmp/SHA256SUMS"
    # The source code: SOURCES byte for byte, and its first file in the pool.
    curl -fsS --proto '=https' --retry 5 -o "$tmp/SOURCES" "$DL_BASE/ironflockos/$version/SOURCES" ||
      die "$DL_BASE/ironflockos/$version/SOURCES does not answer"
    storage cat "$LIVE/$version/SOURCES" | cmp -s - "$tmp/SOURCES" || die "the proxy's SOURCES is not the live one"
    url=$(awk -F'\t' '!/^#/ && $3 != "-" { print $3; exit }' "$tmp/SOURCES")
    [ -n "$url" ] || die "SOURCES lists no source file"
    curl -fsSI --proto '=https' --retry 5 "$url" >/dev/null ||
      die "$url does not answer: does the download proxy serve /dl/ironflockos/sources/?"
    curl -fsS --proto '=https' --retry 5 -o "$tmp/manifest.json" "$DL_BASE/ironflockos/manifest.json" || die "the catalog does not answer"
    cmp -s "$tmp/manifest.json" "$file" || die "the catalog the proxy serves is not the one published"
    log "every file of $version, its SOURCES and the catalog answer through $DL_BASE/ironflockos/"
    ;;
  *) die "usage: publish.sh sums|files|meta|stage|promote|sources|notes|catalog|check ..." ;;
esac
