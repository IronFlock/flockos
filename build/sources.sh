#!/usr/bin/env bash
# The source code of a FlockOS release (docs/release.md, "Source code").
#   sources.sh image               the source packages of an image, from the
#                                  dpkg-query lines "<source:Package> TAB
#                                  <source:Version> TAB <Built-Using>" on
#                                  stdin: "<source> TAB <version>", sorted
#   sources.sh plan LIST           where every file of every source package
#                                  in LIST comes from, to stdout: the build
#                                  container's apt for Debian and the
#                                  Raspberry Pi archive, snapshot.debian.org
#                                  for a version the archive no longer has,
#                                  release/sources for everything else
#   sources.sh index PLAN VERSION  the release's SOURCES, to stdout
#   sources.sh resolve             in the build container, for plan
#
# build/publish.sh sources uploads a plan's files and its SOURCES.
#
# A plan line is "<source> <version> <pool path> <URL> <hash> <note>", tab
# separated. The pool path is <archive>/<source>/<file> below
# DL_BASE/flockos/sources/ (archive: debian, raspberrypi or upstream), the
# hash "SHA256:<hex>", "SHA1:<hex>" or "-" (an upstream tarball). A source
# package whose source is not published has "-" for pool path, URL and hash
# and its reason as the note.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
# shellcheck source=build/lib.sh
. "$here/lib.sh"

SNAPSHOT=https://snapshot.debian.org
RULES=$repo/release/sources

# image: stdin's dpkg-query lines as source packages: each package's own,
# and those its Built-Using names, Debian's field for licence compliance (the
# source of a signed kernel or boot loader is the unsigned one's). A long
# Built-Using continues on lines that start with a space.
image() {
  awk '
    function emit(   n, i, e, p) {
      if (src == "") return
      print src "\t" ver
      n = split(used, e, ",")
      for (i = 1; i <= n; i++) {
        gsub(/^[ \t]+|[ \t]+$/, "", e[i])
        if (e[i] == "") continue
        if (e[i] !~ /^[a-z0-9][a-z0-9+.-]* \(= [^ ()]+\)$/) {
          print "error: not a Built-Using entry of " src ": " e[i] > "/dev/stderr"
          bad = 1
          continue
        }
        split(e[i], p, / \(= /)
        sub(/\)$/, "", p[2])
        print p[1] "\t" p[2]
      }
    }
    /^[ \t]/ {
      if (src == "") { print "error: a continuation line without a package: " $0 > "/dev/stderr"; bad = 1 }
      else used = used "," $0
      next
    }
    {
      emit()
      src = ""
      n = split($0, f, "\t")
      if (n < 2 || f[1] == "" || f[2] == "") { print "error: not a source line: " $0 > "/dev/stderr"; bad = 1; next }
      src = f[1]; ver = f[2]; used = f[3]
    }
    END { emit(); exit bad }' | LC_ALL=C sort -u
}

# snapshot SOURCE VERSION: the plan lines of a Debian source package from
# snapshot.debian.org, which keeps every version the archive ever had; fails
# when it does not know the version.
snapshot() {
  local src=$1 ver=$2 json lines
  json=$(curl -fsS --proto '=https' --retry 5 \
    "$SNAPSHOT/mr/package/$(jq -rn --arg s "$src" '$s | @uri')/$(jq -rn --arg v "$ver" '$v | @uri')/srcfiles?fileinfo=1" 2>/dev/null) ||
    return 1
  lines=$(jq -r --arg src "$src" --arg ver "$ver" --arg file "$SNAPSHOT/file/" '
    .fileinfo // {} | to_entries[] | .key as $hash
    | (.value | map(select(.archive_name == "debian" or .archive_name == "debian-security")) | first) as $f
    | select($f != null)
    | [$src, $ver, "debian/\($src)/\($f.name)", $file + $hash, "SHA1:" + $hash, "-"] | @tsv' <<<"$json") || return 1
  awk -F'\t' '$3 ~ /\.dsc$/ { found = 1 } END { exit !found }' <<<"$lines" || return 1
  printf '%s\n' "$lines"
}

plan() {
  local list=$1 src ver missing=()
  [ -s "$list" ] || die "$list lists no source packages"
  [ -f "$RULES" ] || die "$RULES is missing"
  require awk
  load_conf "$repo/distros/debian-trixie/versions"
  RPI_MIRROR=$(sed -n 's/^RPI_MIRROR=//p' "$repo/targets/rpi-arm64/target.conf")
  [ -n "$RPI_MIRROR" ] || die "targets/rpi-arm64/target.conf names no RPI_MIRROR"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT

  # release/sources first: "none" and "upstream" lines go to the plan as
  # they are, every other source package to the archives.
  awk -v archive="$tmp/archive.tsv" '
    FNR == NR {
      if ($0 ~ /^[ \t]*(#|$)/) next
      n = split($0, w, /[ \t]+/)
      if (n < 3 || (w[2] != "none" && w[2] != "upstream")) { print "error: release/sources:" FNR ": not \"<source> none|upstream ...\"" > "/dev/stderr"; bad = 1; next }
      arg = $0
      sub(/^[^ \t]+[ \t]+[^ \t]+[ \t]+/, "", arg)
      kind[w[1]] = w[2]; val[w[1]] = arg
      next
    }
    {
      split($0, f, "\t"); src = f[1]; ver = f[2]
      if (src !~ /^[a-z0-9][a-z0-9+.-]*$/ || ver !~ /^[0-9A-Za-z.+~:-]+$/) { print "error: not a source package: " $0 > "/dev/stderr"; bad = 1; next }
      if (!(src in kind)) { print src "\t" ver > archive; next }
      if (kind[src] == "none") { print src "\t" ver "\t-\t-\t-\t" val[src]; next }
      up = ver; sub(/^[0-9]+:/, "", up); sub(/-[^-]*$/, "", up)
      url = val[src]; gsub(/\{upstream\}/, up, url)
      print src "\t" ver "\tupstream/" src "/" src "_" up ".tar.gz\t" url "\t-\t-"
    }
    END { exit bad }' "$RULES" "$list"

  [ -s "$tmp/archive.tsv" ] || return 0
  require docker curl jq
  load_conf "$here/builder.conf"
  log "resolving $(wc -l <"$tmp/archive.tsv" | tr -d ' ') source packages with apt in $BUILDER_IMAGE"
  docker run --rm -i \
    -v "$repo:/src:ro" \
    -e DEBIAN_FRONTEND=noninteractive \
    "$BUILDER_IMAGE" \
    bash /src/build/sources.sh resolve <"$tmp/archive.tsv" >"$tmp/resolved.tsv"
  awk -v debian="$DISTRO_MIRROR/" -v security="$DISTRO_SECURITY_MIRROR/" -v rpi="$RPI_MIRROR/" -v missing="$tmp/missing.tsv" '
    BEGIN { FS = OFS = "\t"; printf "" > missing }
    $3 == "-" { print $1, $2 > missing; next }
    {
      if (index($3, debian) == 1 || index($3, security) == 1) a = "debian"
      else if (index($3, rpi) == 1) a = "raspberrypi"
      else { print "error: " $1 " " $2 ": a file from an unknown archive: " $3 > "/dev/stderr"; bad = 1; next }
      print $1, $2, a "/" $1 "/" $4, $3, $6, "-"
    }
    END { exit bad }' "$tmp/resolved.tsv"
  while IFS=$'\t' read -r src ver; do
    if ! snapshot "$src" "$ver"; then
      missing+=("$src $ver")
    fi
  done <"$tmp/missing.tsv"
  [ "${#missing[@]}" -eq 0 ] ||
    die "no source for: $(join_by ', ' "${missing[@]}"). A source package outside Debian and the Raspberry Pi archive needs a line in release/sources."
}

# resolve: in the build container, the files of each source package of
# stdin's list as apt finds them ("<source> <version> <URL> <file> <size>
# <hash>"), or "<source> <version> -" when apt does not know it.
resolve() {
  if [ ! -f /etc/debian_version ] || ! command -v apt-get >/dev/null; then
    die "resolve runs in the build container (sources.sh plan)"
  fi
  load_conf "$repo/distros/debian-trixie/versions"
  local rpi src ver out
  rpi=$(sed -n 's/^RPI_MIRROR=//p' "$repo/targets/rpi-arm64/target.conf")
  # The Raspberry Pi archive is https: the certificates first, from the
  # image's own sources.
  apt-get -qq -o Acquire::Retries=5 update >&2
  apt-get -qq -y -o Acquire::Retries=5 install --no-install-recommends ca-certificates >/dev/null
  # Then only the source indexes (the image's own entries name the keyring
  # by another path, which apt refuses for the same archive).
  rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*
  {
    printf 'Types: deb-src\nURIs: %s\nSuites: %s %s-updates\nComponents: %s\nSigned-By: %s\n\n' \
      "$DISTRO_MIRROR" "$DISTRO_SUITE" "$DISTRO_SUITE" "$DISTRO_COMPONENTS" "$DISTRO_KEYRING"
    printf 'Types: deb-src\nURIs: %s\nSuites: %s-security\nComponents: %s\nSigned-By: %s\n\n' \
      "$DISTRO_SECURITY_MIRROR" "$DISTRO_SUITE" "$DISTRO_COMPONENTS" "$DISTRO_KEYRING"
    printf 'Types: deb-src\nURIs: %s\nSuites: %s\nComponents: main\nSigned-By:\n' "$rpi" "$DISTRO_SUITE"
    sed -e 's/^$/./' -e 's/^/ /' "$repo/targets/rpi-arm64/apt/raspberrypi.asc"
  } >/etc/apt/sources.list.d/flockos-sources.sources
  apt-get -qq -o Acquire::Retries=5 update >&2
  # apt leaves out a file it finds in the current directory.
  cd "$(mktemp -d)"
  while IFS=$'\t' read -r src ver; do
    if out=$(apt-get source --print-uris --only-source "$src=$ver" 2>/dev/null); then
      # 'URL' file size hash
      while read -r url file size hash; do
        case "$url" in
          \'*\') printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$src" "$ver" "${url:1:${#url}-2}" "$file" "$size" "$hash" ;;
        esac
      done <<<"$out"
    else
      printf '%s\t%s\t-\n' "$src" "$ver"
    fi
  done
}

index() {
  local plan=$1 version=$2
  [ -s "$plan" ] || die "$plan is an empty plan"
  load_conf "$here/release.conf"
  cat <<HEADER
# FlockOS $version: the source code of the software in its images.
#
# An image is a collection of separate programs, each under its own licence,
# which /usr/share/doc/<package>/copyright in the image names; the
# <image>.packages.tsv next to this file lists the packages of an image.
# Below is every file of every source package the images were built from,
# on this server; "dget <URL of a .dsc>" fetches a Debian source package
# with all its files. A source package with "-" as its URL has no source
# here, for the reason after it: none of them is under a copyleft licence.
#
# FlockOS's own files are https://github.com/IronFlock/flockos at the tag
# v$version, under the Apache License 2.0.
#
# source	version	URL or -	reason
HEADER
  awk -F'\t' -v base="$DL_BASE/flockos/sources/" '
    $3 == "-" { print $1 "\t" $2 "\t-\t" $6; next }
    { print $1 "\t" $2 "\t" base $3 }' "$plan" | LC_ALL=C sort -u
}

cmd=${1:-}
case "$cmd" in
  image) image ;;
  plan) plan "${2:?usage: sources.sh plan LIST}" ;;
  index) index "${2:?usage: sources.sh index PLAN VERSION}" "${3:?usage: sources.sh index PLAN VERSION}" ;;
  resolve) resolve ;;
  *) die "usage: sources.sh image|plan|index|resolve ..." ;;
esac
