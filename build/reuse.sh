#!/usr/bin/env bash
# Reused images (ADR-0018, docs/release.md "Reused images"): the release run
# takes the images that its pull request's dry run built, when it can prove
# they are the build of the release commit's tree; otherwise it builds them.
#
#   reuse.sh list DIR                 every file of DIR (one image as built):
#                                     sha256, size and name, tab-separated
#   reuse.sh manifest DIR             the build manifest of a run: DIR holds
#                                     <image-id>.tsv (list) per image; prints
#                                     sha256, size and <image-id>/<name>
#   reuse.sh find COMMIT WORK         the dry run that built COMMIT's tree:
#                                     the pull request merged as COMMIT, its
#                                     newest successful ci run, then check
#   reuse.sh check RUN PR COMMIT WORK run RUN of ci.yml, for pull request PR,
#                                     built the images of COMMIT's tree, and
#                                     its artifacts are there; WORK/build.tsv
#                                     is then its verified manifest
#   reuse.sh files MANIFEST DIR [IMAGE]
#                                     DIR/ironflockos-<image>/ holds exactly the
#                                     files MANIFEST lists for each image (or
#                                     for IMAGE), byte for byte
#
# find and check write what they found to GITHUB_OUTPUT (when it is set):
# run-id, pr, commit (the merge commit the run built), tree; and why=, the
# reason, when they fail. They fail on anything they cannot prove; the
# caller then builds. They read the GitHub API with gh as GH_TOKEN, for the
# repository REPO (owner/name). Nothing an artifact says about itself counts:
# the run's commit comes from the Sigstore certificate of the attestation the
# harness made of the manifest in that run (GitHub's OIDC claims), the trees
# from the API.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=build/lib.sh
. "$here/lib.sh"
load_conf "$here/release.conf"

# The signer of the manifest's attestation: the harness's attest-provenance
# workflow at the tag release.yml calls.
SIGNER=https://github.com/IronFlock/workflows/.github/workflows/attest-provenance.yml@refs/tags/v1
ISSUER=https://token.actions.githubusercontent.com
# The images are reused only while their artifacts have this long to live
# (retention 3 days), and only when they are this young: a younger build has
# the newer packages.
REUSE_MIN_LEFT_HOURS=${REUSE_MIN_LEFT_HOURS:-6}
REUSE_MAX_AGE_HOURS=${REUSE_MAX_AGE_HOURS:-24}
REUSE_RETRY_SECONDS=${REUSE_RETRY_SECONDS:-20}
tab=$'\t'
REPO=${REPO:-}

# output KEY VALUE: a step output, when there is a step.
output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"; fi
}

# fail REASON: no reuse, and why.
fail() {
  output why "$*"
  die "$*"
}

# list DIR: sha256, size and name of every file of DIR; nothing but files.
list() {
  local dir=$1 f
  [ -d "$dir" ] || die "$dir is no directory"
  # A directory is the only way to a file deeper down.
  if [ -n "$(find "$dir" -mindepth 1 ! -type f -print -quit)" ]; then
    die "$dir holds something other than files"
  fi
  find "$dir" -mindepth 1 -maxdepth 1 -type f -print | LC_ALL=C sort | while read -r f; do
    printf '%s\t%s\t%s\n' "$(sha256sum <"$f" | cut -d' ' -f1)" "$(wc -c <"$f" | tr -d ' ')" "$(basename "$f")"
  done
}

# valid_manifest FILE: every line sha256, size, ironflockos-<image>/<name>, each
# path once, and the images are RELEASE_IMAGES.
valid_manifest() {
  local file=$1 want got
  [ -s "$file" ] || return 1
  awk -F'\t' '
    NF != 3 || $1 !~ /^[0-9a-f]{64}$/ || $2 !~ /^[0-9]+$/ || $3 !~ /^ironflockos-[a-z0-9-]+\/[A-Za-z0-9][A-Za-z0-9._+-]*$/ { exit 1 }
    seen[$3]++ { exit 1 }
  ' "$file" || return 1
  # shellcheck disable=SC2086 # a space-separated list of image names
  want=$(printf 'ironflockos-%s\n' $RELEASE_IMAGES | LC_ALL=C sort)
  got=$(cut -f 3 "$file" | cut -d/ -f1 | LC_ALL=C sort -u)
  [ "$want" = "$got" ]
}

# api PATH...: gh api, or no reuse.
api() {
  gh api "$@" || fail "the GitHub API did not answer: gh api $*"
}

# tree COMMIT: the tree of a commit of the repository, from the API.
tree() {
  local t
  t=$(api "repos/$REPO/git/commits/$1" --jq .tree.sha)
  [[ "$t" =~ ^[0-9a-f]{40}$ ]] || fail "no tree for commit $1"
  printf '%s\n' "$t"
}

check() {
  local run=$1 pr=$2 commit=$3 work=$4 now arts a id verified="" certs merge left age built want try
  [[ "$run" =~ ^[0-9]+$ ]] || fail "not a run id: $run"
  [[ "$pr" =~ ^[0-9]+$ ]] || fail "not a pull request number: $pr"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || fail "not a commit: $commit"
  mkdir -p "$work"
  now=$(date -u +%s)

  # The artifacts: the manifest and every image, each once, none expired,
  # none about to expire, none too old.
  arts=$(api --paginate "repos/$REPO/actions/runs/$run/artifacts?per_page=100" --jq '.artifacts[]' | jq -s .) ||
    fail "cannot list the artifacts of run $run"
  # shellcheck disable=SC2086 # a space-separated list of image names
  for a in release-build-manifest $(printf 'release-image-%s ' $RELEASE_IMAGES); do
    [ "$(jq --arg n "$a" '[.[] | select(.name == $n)] | length' <<<"$arts")" = 1 ] ||
      fail "run $run does not have exactly one artifact $a"
    jq -e --arg n "$a" '.[] | select(.name == $n) | .expired == false' <<<"$arts" >/dev/null ||
      fail "the artifact $a of run $run has expired"
    left=$(jq -r --arg n "$a" '.[] | select(.name == $n) | .expires_at | fromdateiso8601' <<<"$arts") ||
      fail "the artifact $a of run $run has no expiry date"
    [ $((left - now)) -ge $((REUSE_MIN_LEFT_HOURS * 3600)) ] ||
      fail "the artifact $a of run $run expires within $REUSE_MIN_LEFT_HOURS hours"
    age=$(jq -r --arg n "$a" '.[] | select(.name == $n) | .created_at | fromdateiso8601' <<<"$arts") ||
      fail "the artifact $a of run $run has no creation date"
    [ $((now - age)) -le $((REUSE_MAX_AGE_HOURS * 3600)) ] ||
      fail "the artifact $a of run $run is older than $REUSE_MAX_AGE_HOURS hours"
  done

  # The manifest: one file, build.tsv, well-formed, naming exactly the
  # release's images.
  id=$(jq -r '.[] | select(.name == "release-build-manifest") | .id' <<<"$arts")
  api "repos/$REPO/actions/artifacts/$id/zip" >"$work/manifest.zip"
  [ "$(unzip -Z1 "$work/manifest.zip" 2>/dev/null)" = build.tsv ] || fail "the manifest artifact of run $run is not one build.tsv"
  unzip -p "$work/manifest.zip" build.tsv >"$work/build.tsv"
  valid_manifest "$work/build.tsv" || fail "the manifest of run $run is not a manifest of the images $RELEASE_IMAGES"

  # Its attestation: made by the harness, in run RUN of ci.yml for pull
  # request PR, on a GitHub-hosted runner, at the pull request's merge
  # commit. gh checks the signature, the transparency log, the signer and
  # the ref; the rest is pinned here, in the certificate's claims.
  # Three tries: a dry run checks an attestation made a minute before.
  for try in 1 2 3; do
    if verified=$(gh attestation verify "$work/build.tsv" --repo "$REPO" \
      --cert-identity "$SIGNER" --cert-oidc-issuer "$ISSUER" \
      --source-ref "refs/pull/$pr/merge" --deny-self-hosted-runners --format json); then
      break
    fi
    [ "$try" -lt 3 ] || fail "the manifest of run $run has no attestation of the harness for pull request #$pr"
    sleep "$REUSE_RETRY_SECONDS"
  done
  certs=$(jq -c --arg signer "$SIGNER" --arg issuer "$ISSUER" --arg repo "https://github.com/$REPO" --arg run "$run" --arg pr "$pr" '
    ($repo + "/actions/runs/" + $run + "/attempts/") as $attempts
    | [.[].verificationResult.signature.certificate
      | select(.subjectAlternativeName == $signer
        and .issuer == $issuer
        and .buildTrigger == "pull_request"
        and .runnerEnvironment == "github-hosted"
        and .sourceRepositoryURI == $repo
        and .sourceRepositoryRef == ("refs/pull/" + $pr + "/merge")
        and .buildConfigURI == ($repo + "/.github/workflows/ci.yml@refs/pull/" + $pr + "/merge")
        and (.runInvocationURI | startswith($attempts) and (ltrimstr($attempts) | test("^[0-9]+$")))
        and (.sourceRepositoryDigest | test("^[0-9a-f]{40}$")))
      | .sourceRepositoryDigest] | unique' <<<"$verified") ||
    fail "cannot read the attestation of the manifest of run $run"
  [ "$(jq length <<<"$certs")" = 1 ] ||
    fail "the manifest of run $run has no attestation of run $run of ci.yml for pull request #$pr (or several commits)"
  merge=$(jq -r '.[0]' <<<"$certs")

  # The run built the release commit's tree (each lookup fails on its own).
  built=$(tree "$merge")
  want=$(tree "$commit")
  [ "$built" = "$want" ] || fail "run $run built $merge, whose tree is not the tree of $commit"

  output run-id "$run"
  output pr "$pr"
  output commit "$merge"
  output tree "$want"
  log "run $run of ci.yml (pull request #$pr) built $merge, the tree of $commit: its images can be reused"
}

find_run() {
  local commit=$1 work=$2 prs pr head runs run
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || fail "not a commit: $commit"
  # The pull request merged as COMMIT, into main, from this repository.
  prs=$(api "repos/$REPO/commits/$commit/pulls")
  pr=$(jq -r --arg c "$commit" --arg repo "$REPO" '[.[] | select(.merged_at != null and .merge_commit_sha == $c
      and .base.ref == "main" and .head.repo.full_name == $repo)] | if length == 1 then .[0].number else empty end' <<<"$prs") ||
    fail "cannot read the pull requests of $commit"
  [ -n "$pr" ] || fail "$commit is not the merge of exactly one pull request into main from $REPO"
  head=$(jq -r --argjson n "$pr" '.[] | select(.number == $n) | .head.sha' <<<"$prs")
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || fail "pull request #$pr has no head commit"
  # Its newest successful run of ci.yml.
  runs=$(api "repos/$REPO/actions/workflows/ci.yml/runs?event=pull_request&head_sha=$head&status=success&per_page=100")
  run=$(jq -r --arg h "$head" --arg repo "$REPO" '[.workflow_runs[] | select(.event == "pull_request"
      and .path == ".github/workflows/ci.yml" and .head_sha == $h and .head_repository.full_name == $repo
      and .status == "completed" and .conclusion == "success")] | max_by(.run_number) | .id // empty' <<<"$runs") ||
    fail "cannot read the ci runs of $head"
  [ -n "$run" ] || fail "pull request #$pr has no successful ci run of its head $head"
  check "$run" "$pr" "$commit" "$work"
}

# files MANIFEST DIR [IMAGE]: DIR's image directories are the manifest's.
files() {
  local manifest=$1 dir=$2 image=${3:-} want got d id
  valid_manifest "$manifest" || die "$manifest is not a manifest of the images $RELEASE_IMAGES"
  if [ -n "$image" ]; then
    grep -q "$tab""ironflockos-$image/" "$manifest" || die "the manifest has no image $image"
    want="ironflockos-$image"
  else
    want=$(cut -f 3 "$manifest" | cut -d/ -f1 | LC_ALL=C sort -u)
    got=$(find "$dir" -mindepth 1 -maxdepth 1 -print | sed 's|.*/||' | LC_ALL=C sort)
    [ "$want" = "$got" ] || die "$dir does not hold exactly the images of the manifest"
  fi
  for id in $want; do
    d=$dir/$id
    got=$(list "$d" | awk -F'\t' -v id="$id" '{ print $1 "\t" $2 "\t" id "/" $3 }')
    [ "$got" = "$(grep "$tab$id/" "$manifest" | LC_ALL=C sort -t "$tab" -k 3,3)" ] ||
      die "$id is not the build the manifest lists"
  done
  log "every file of $(echo "$want" | wc -w | tr -d ' ') image(s) is the one the manifest lists"
}

cmd=${1:-}
case "$cmd" in
  list)
    list "${2:?usage: reuse.sh list DIR}"
    ;;
  manifest)
    dir=${2:?usage: reuse.sh manifest DIR}
    shopt -s nullglob
    lists=("$dir"/ironflockos-*.tsv)
    [ "${#lists[@]}" -gt 0 ] || die "no lists in $dir"
    for l in "${lists[@]}"; do
      id=$(basename "$l" .tsv)
      awk -F'\t' -v id="$id" 'NF == 3 { print $1 "\t" $2 "\t" id "/" $3; next } { exit 1 }' "$l" ||
        die "$l is not a list"
    done | LC_ALL=C sort -t "$tab" -k 3,3
    ;;
  find)
    [ -n "$REPO" ] || die "REPO is the repository, owner/name"
    require gh jq unzip
    find_run "${2:?usage: reuse.sh find COMMIT WORK}" "${3:?usage: reuse.sh find COMMIT WORK}"
    ;;
  check)
    [ -n "$REPO" ] || die "REPO is the repository, owner/name"
    require gh jq unzip
    [ "$#" -eq 5 ] || die "usage: reuse.sh check RUN PR COMMIT WORK"
    check "$2" "$3" "$4" "$5"
    ;;
  files)
    files "${2:?usage: reuse.sh files MANIFEST DIR [IMAGE]}" "${3:?usage: reuse.sh files MANIFEST DIR [IMAGE]}" "${4:-}"
    ;;
  *) die "usage: reuse.sh list|manifest|find|check|files ..." ;;
esac
