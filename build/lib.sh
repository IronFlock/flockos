# shellcheck shell=bash
# Shared helpers of the FlockOS build scripts. Sourced, never executed.
#
# Conventions: every script runs with `set -euo pipefail`, logs with `log`,
# fails with `die`, and reads its configuration from plain KEY=value files
# (target.conf, profile versions) through `load_conf`, which accepts nothing
# but assignments, so a configuration file can never run code.

log() { printf '==> %s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# require CMD...: fail early with the missing tool's name.
require() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required but not installed"
  done
}

# load_conf FILE: export the KEY=value lines of FILE. Blank lines and
# comments are skipped; values may be quoted with "" or ''; anything else is
# an error, so the file stays data.
load_conf() {
  local file=$1 line key value n=0
  [ -f "$file" ] || die "configuration $file not found"
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in '' | '#'*) continue ;; esac
    if [[ ! "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
      die "$file:$n: not a KEY=value line: $line"
    fi
    key=${BASH_REMATCH[1]}
    value=${BASH_REMATCH[2]}
    if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
      value=${BASH_REMATCH[1]}
    fi
    export "$key=$value"
  done <"$file"
}

# slot_fill EXT4_IMAGE: how full a root slot's filesystem is, as
# "<used percent> <used bytes> <size bytes>" from its superblock (ext4's own
# overhead included).
slot_fill() {
  local info blocks free bsize used
  info=$(dumpe2fs -h "$1" 2>/dev/null) || die "cannot read the superblock of $1"
  blocks=$(awk -F: '/^Block count:/ { gsub(/ /, "", $2); print $2 }' <<<"$info")
  free=$(awk -F: '/^Free blocks:/ { gsub(/ /, "", $2); print $2 }' <<<"$info")
  bsize=$(awk -F: '/^Block size:/ { gsub(/ /, "", $2); print $2 }' <<<"$info")
  [ -n "$blocks" ] && [ -n "$free" ] && [ -n "$bsize" ] && [ "$blocks" -gt 0 ] || die "no block counts in the superblock of $1"
  used=$((blocks - free))
  printf '%s %s %s\n' $((used * 100 / blocks)) $((used * bsize)) $((blocks * bsize))
}

# check_slot_fill EXT4_IMAGE NAME: a root slot's size is fixed for a
# device's lifetime (rootfs-b and /data are made once, on the first boot), so
# every later release has to fit the slots of the oldest device in the field.
# This warns (and annotates the CI run) from FLOCKOS_SLOT_FILL_WARN percent
# and fails the build from FLOCKOS_SLOT_FILL_MAX, releases before a tree
# outgrows its slot.
check_slot_fill() {
  local warn_at=${FLOCKOS_SLOT_FILL_WARN:-75} max=${FLOCKOS_SLOT_FILL_MAX:-90} pct used size msg
  read -r pct used size <<<"$(slot_fill "$1")"
  msg="$2: the root slot is ${pct}% full ($((used >> 20)) MiB of $((size >> 20)) MiB)"
  if [ "$pct" -ge "$max" ]; then
    printf '::error title=root slot nearly full::%s; the limit is %s%%\n' "$msg" "$max"
    die "$msg; the limit is ${max}%: shrink the image or plan a larger slot (a new image id, as devices cannot grow theirs)"
  elif [ "$pct" -ge "$warn_at" ]; then
    printf '::warning title=root slot filling up::%s (warning from %s%%, the build fails from %s%%)\n' "$msg" "$warn_at" "$max"
    warn "$msg (warning from ${warn_at}%, the build fails from ${max}%)"
  else
    log "$msg"
  fi
}

# read_list FILE...: print the entries of package-style lists, one per line,
# without comments and blank lines. Missing files are skipped, so optional
# per-architecture lists need no special case.
read_list() {
  local file
  for file in "$@"; do
    [ -f "$file" ] || continue
    sed -e 's/#.*//' -e 's/[[:space:]]\+$//' -e '/^[[:space:]]*$/d' "$file"
  done
}

# join_by SEP WORD...: WORD1SEPWORD2...
join_by() {
  local sep=$1 first=1 out="" word
  shift
  for word in "$@"; do
    if [ "$first" = 1 ]; then out=$word first=0; else out="$out$sep$word"; fi
  done
  printf '%s' "$out"
}

# render TEMPLATE: substitute @VAR@ placeholders with the environment's VAR.
# A placeholder whose variable is unset is an error, so a template never
# ships with a hole.
render() {
  local template=$1 out var
  out=$(<"$template")
  while [[ "$out" =~ @([A-Z][A-Z0-9_]*)@ ]]; do
    var=${BASH_REMATCH[1]}
    [ -n "${!var+set}" ] || die "$template: @$var@ has no value"
    out=${out//@$var@/${!var}}
  done
  printf '%s\n' "$out"
}

# size_bytes SIZE: 256M, 4G, 512K or a plain byte count, as bytes.
size_bytes() {
  local s=$1
  case "$s" in
    *[!0-9KMG]* | '' | [KMG]*) die "not a size: $s" ;;
    *K) echo $((${s%K} * 1024)) ;;
    *M) echo $((${s%M} * 1024 * 1024)) ;;
    *G) echo $((${s%G} * 1024 * 1024 * 1024)) ;;
    *) echo "$s" ;;
  esac
}

# valid_target / valid_variant / valid_kernel NAME: the build matrix axes
# (master plan, section 3.1).
valid_target() { case "$1" in amd64-efi | arm64-efi | rpi-arm64 | jetson-orin) return 0 ;; *) return 1 ;; esac }
valid_variant() { case "$1" in base | nvidia | installer) return 0 ;; *) return 1 ;; esac }
valid_kernel() { case "$1" in std | rt) return 0 ;; *) return 1 ;; esac }

# image_id TARGET VARIANT KERNEL: flockos-<target>-<variant>[-rt], the RAUC
# compatible and IMAGE_ID of the image.
image_id() {
  local id="flockos-$1-$2"
  [ "$3" = rt ] && id="$id-rt"
  printf '%s' "$id"
}

# uuid_for NAME: a UUID derived from $IMAGE_ID and NAME, so every build of a
# target has the same partition and filesystem ids.
uuid_for() {
  local h
  h=$(printf 'flockos:%s:%s' "${IMAGE_ID:?}" "$1" | sha256sum | cut -c1-32)
  printf '%s-%s-4%s-8%s-%s' "${h:0:8}" "${h:8:4}" "${h:13:3}" "${h:17:3}" "${h:20:12}"
}

# throwaway_signer DIR CN: a CA of its own (DIR/keyring.pem) and a code-signing
# certificate it issued (DIR/signer.pem, key DIR/signer.key), RSA 3072, valid
# 30 days. The CA's key is gone when this returns, so nothing else is ever
# signed under that CA.
throwaway_signer() {
  local d=$1 cn=$2 days=30
  require openssl
  mkdir -p "$d"
  chmod 0700 "$d"
  openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days "$days" \
    -keyout "$d/ca.key" -out "$d/keyring.pem" \
    -subj "/O=IronFlock/CN=$cn CA (throwaway)" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash" 2>/dev/null
  openssl req -newkey rsa:3072 -nodes -sha256 \
    -keyout "$d/signer.key" -out "$d/signer.csr" \
    -subj "/O=IronFlock/CN=$cn signer (throwaway)" 2>/dev/null
  printf '%s\n' \
    "basicConstraints=critical,CA:FALSE" \
    "keyUsage=critical,digitalSignature" \
    "extendedKeyUsage=critical,codeSigning" \
    "subjectKeyIdentifier=hash" \
    "authorityKeyIdentifier=keyid" >"$d/signer.ext"
  openssl x509 -req -sha256 -days "$days" -in "$d/signer.csr" \
    -CA "$d/keyring.pem" -CAkey "$d/ca.key" -CAcreateserial \
    -extfile "$d/signer.ext" -out "$d/signer.pem" 2>/dev/null
  rm -f "$d/ca.key" "$d/signer.csr" "$d/signer.ext" "$d/keyring.srl"
  openssl verify -purpose any -CAfile "$d/keyring.pem" "$d/signer.pem" >/dev/null
}
