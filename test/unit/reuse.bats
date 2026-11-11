#!/usr/bin/env bats
# Reused images (ADR-0018, build/reuse.sh): the lists and the manifest of a
# build, the check of downloaded files, and the lookup and verification of a
# pull request's dry run against a stand-in gh, with every way it must refuse.

repo="$BATS_TEST_DIRNAME/../.."
reuse="$repo/build/reuse.sh"

REPO_NAME=IronFlock/ironflockos
H=1111111111111111111111111111111111111111 # the release commit on main
X=2222222222222222222222222222222222222222 # the pull request's head
M=3333333333333333333333333333333333333333 # the dry run's merge commit
T=4444444444444444444444444444444444444444 # their tree
SIGNER=https://github.com/IronFlock/workflows/.github/workflows/attest-provenance.yml@refs/tags/v1

setup() {
  tmp=$(mktemp -d)
  mkdir -p "$tmp/bin" "$tmp/api" "$tmp/out" "$tmp/lists"
  # shellcheck source=build/lib.sh
  . "$repo/build/lib.sh"
  load_conf "$repo/build/release.conf"
  # Every release image as built: a few small files each.
  for image in $RELEASE_IMAGES; do
    d=$tmp/out/ironflockos-$image
    mkdir -p "$d"
    printf 'image of %s' "$image" >"$d/ironflockos-$image-1.0.0.img.gz"
    printf 'osr %s' "$image" >"$d/ironflockos-$image-1.0.0.os-release"
    case "$image" in *-installer) ;; *) printf 'bundle of %s' "$image" >"$d/ironflockos-$image-1.0.0.raucb" ;; esac
    bash "$reuse" list "$d" >"$tmp/lists/ironflockos-$image.tsv"
  done
  bash "$reuse" manifest "$tmp/lists" >"$tmp/build.tsv"
  stand_in_gh
  world
}

teardown() { rm -rf "$tmp"; }

# key PATH: the stand-in's file of an API path.
key() { printf '%s' "$1" | tr '/?&=' '____'; }

# stand_in_gh: gh that logs its calls to $tmp/gh.log, answers `api PATH`
# from $tmp/api/<key PATH> (with --jq applied), and `attestation verify`
# with $tmp/attest.json, or fails when $tmp/attest.fail exists.
stand_in_gh() {
  cat >"$tmp/bin/gh" <<STANDIN
#!/bin/bash
echo "gh \$*" >>"$tmp/gh.log"
if [ "\$1" = attestation ]; then
  [ ! -e "$tmp/attest.fail" ] || exit 1
  cat "$tmp/attest.json"
  exit 0
fi
[ "\$1" = api ] || exit 2
shift
path="" expr=""
while [ \$# -gt 0 ]; do
  case "\$1" in --paginate) ;; --jq) expr=\$2; shift ;; -*) ;; *) path=\$1 ;; esac
  shift
done
f=$tmp/api/\$(printf '%s' "\$path" | tr '/?&=' '____')
[ -f "\$f" ] || { echo "HTTP 404: \$path" >&2; exit 1; }
if [ -n "\$expr" ]; then jq -r "\$expr" "\$f"; else cat "\$f"; fi
STANDIN
  chmod +x "$tmp/bin/gh"
}

# iso SECONDS: a time SECONDS from now.
iso() { jq -nr --argjson s "$1" 'now + $s | floor | todate'; }

# artifact NAME ID: an artifact of the run, made an hour ago, kept two days.
artifact() {
  jq -n --arg n "$1" --argjson id "$2" --arg c "$(iso -3600)" --arg e "$(iso 172800)" \
    '{id: $id, name: $n, expired: false, created_at: $c, expires_at: $e}'
}

# cert: the certificate claims of the harness's attestation in run 900 of
# ci.yml for pull request 216, at M.
cert() {
  jq -n --arg san "$SIGNER" --arg m "$M" '{
    subjectAlternativeName: $san,
    issuer: "https://token.actions.githubusercontent.com",
    buildTrigger: "pull_request",
    runnerEnvironment: "github-hosted",
    sourceRepositoryURI: "https://github.com/IronFlock/ironflockos",
    sourceRepositoryRef: "refs/pull/216/merge",
    sourceRepositoryDigest: $m,
    buildConfigURI: "https://github.com/IronFlock/ironflockos/.github/workflows/ci.yml@refs/pull/216/merge",
    runInvocationURI: "https://github.com/IronFlock/ironflockos/actions/runs/900/attempts/2"
  }'
}

# set_cert JQ: the attestation's claims, changed by a jq filter.
set_cert() {
  cert | jq "$1" | jq -s '[.[] | {verificationResult: {signature: {certificate: .}}}]' >"$tmp/attest.json"
}

# world: H is the squash merge of pull request 216 (head X), whose ci run 900
# succeeded, built M (tree T, as H's) and kept its artifacts.
world() {
  jq -n --arg h "$H" --arg x "$X" '[{number: 216, merged_at: "2026-11-11T12:00:00Z", merge_commit_sha: $h,
    base: {ref: "main"}, head: {sha: $x, repo: {full_name: "IronFlock/ironflockos"}}}]' \
    >"$tmp/api/$(key "repos/$REPO_NAME/commits/$H/pulls")"
  jq -n --arg x "$X" '{workflow_runs: [
    {id: 899, run_number: 40, event: "pull_request", path: ".github/workflows/ci.yml", head_sha: $x, head_repository: {full_name: "IronFlock/ironflockos"}, status: "completed", conclusion: "success"},
    {id: 900, run_number: 41, event: "pull_request", path: ".github/workflows/ci.yml", head_sha: $x, head_repository: {full_name: "IronFlock/ironflockos"}, status: "completed", conclusion: "success"}]}' \
    >"$tmp/api/$(key "repos/$REPO_NAME/actions/workflows/ci.yml/runs?event=pull_request&head_sha=$X&status=success&per_page=100")"
  {
    artifact release-build-manifest 7000
    i=7001
    for image in $RELEASE_IMAGES; do
      artifact "release-image-$image" "$i"
      i=$((i + 1))
    done
  } | jq -s '{artifacts: .}' >"$tmp/api/$(key "repos/$REPO_NAME/actions/runs/900/artifacts?per_page=100")"
  zip_manifest build.tsv
  for c in "$H" "$M"; do
    jq -n --arg t "$T" '{tree: {sha: $t}}' >"$tmp/api/$(key "repos/$REPO_NAME/git/commits/$c")"
  done
  set_cert .
}

# zip_manifest NAME...: the manifest artifact, holding build.tsv under these
# names.
zip_manifest() {
  python3 -I -c '
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    for name in sys.argv[3:]:
        z.write(sys.argv[2], name)
' "$tmp/api/$(key "repos/$REPO_NAME/actions/artifacts/7000/zip")" "$tmp/build.tsv" "$@"
}

# artifacts JQ: the run's artifacts, changed by a jq filter.
artifacts() {
  f=$tmp/api/$(key "repos/$REPO_NAME/actions/runs/900/artifacts?per_page=100")
  jq "$1" "$f" >"$f.new" && mv "$f.new" "$f"
}

find_() {
  run env PATH="$tmp/bin:$PATH" REPO="$REPO_NAME" GITHUB_OUTPUT="$tmp/output" REUSE_RETRY_SECONDS=0 bash "$reuse" find "$H" "$tmp/work"
}

# refused REASON: find failed, and said why.
refused() {
  [ "$status" -ne 0 ] || { echo "accepted"; return 1; }
  grep -q "^why=.*$1" "$tmp/output" || { cat "$tmp/output"; echo "$output"; return 1; }
  ! grep -q '^run-id=' "$tmp/output"
}

@test "list: every file's sha256, size and name, sorted" {
  run bash "$reuse" list "$tmp/out/ironflockos-amd64-efi-base"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" = 3 ]
  [ "$(echo "$output" | head -n 1 | cut -f 2-)" = "$(printf '23\tironflockos-amd64-efi-base-1.0.0.img.gz')" ]
  [ "$(echo "$output" | head -n 1 | cut -f 1)" = "$(printf 'image of amd64-efi-base' | sha256sum | cut -d' ' -f1)" ]
}

@test "list: refuses a directory or a link among the files" {
  mkdir "$tmp/out/ironflockos-amd64-efi-base/sub"
  run bash "$reuse" list "$tmp/out/ironflockos-amd64-efi-base"
  [ "$status" -ne 0 ]
  rmdir "$tmp/out/ironflockos-amd64-efi-base/sub"
  ln -s /etc/hostname "$tmp/out/ironflockos-amd64-efi-base/link"
  run bash "$reuse" list "$tmp/out/ironflockos-amd64-efi-base"
  [ "$status" -ne 0 ]
}

@test "manifest: every file of every image as <image>/<name>, sorted" {
  [ "$(wc -l <"$tmp/build.tsv" | tr -d ' ')" = 22 ]
  grep -q "	ironflockos-amd64-efi-installer/ironflockos-amd64-efi-installer-1.0.0.img.gz$" "$tmp/build.tsv"
  [ "$(cut -f 3 "$tmp/build.tsv")" = "$(cut -f 3 "$tmp/build.tsv" | LC_ALL=C sort)" ]
  printf 'not a list\n' >"$tmp/lists/ironflockos-x.tsv"
  run bash "$reuse" manifest "$tmp/lists"
  [ "$status" -ne 0 ]
}

@test "files: the images as the manifest lists them" {
  run bash "$reuse" files "$tmp/build.tsv" "$tmp/out"
  [ "$status" -eq 0 ]
  run bash "$reuse" files "$tmp/build.tsv" "$tmp/out" amd64-efi-nvidia
  [ "$status" -eq 0 ]
}

@test "files: refuses a changed byte, a file more or less, an image more or less" {
  d=$tmp/out/ironflockos-amd64-efi-base
  printf 'Image of amd64-efi-base' >"$d/ironflockos-amd64-efi-base-1.0.0.img.gz"
  run bash "$reuse" files "$tmp/build.tsv" "$tmp/out"
  [ "$status" -ne 0 ]
  run bash "$reuse" files "$tmp/build.tsv" "$tmp/out" amd64-efi-base
  [ "$status" -ne 0 ]
  printf 'image of amd64-efi-base' >"$d/ironflockos-amd64-efi-base-1.0.0.img.gz"
  touch "$d/extra"
  run bash "$reuse" files "$tmp/build.tsv" "$tmp/out" amd64-efi-base
  [ "$status" -ne 0 ]
  rm "$d/extra" "$d/ironflockos-amd64-efi-base-1.0.0.os-release"
  run bash "$reuse" files "$tmp/build.tsv" "$tmp/out" amd64-efi-base
  [ "$status" -ne 0 ]
  printf 'osr amd64-efi-base' >"$d/ironflockos-amd64-efi-base-1.0.0.os-release"
  mkdir "$tmp/out/ironflockos-amd64-efi-other"
  run bash "$reuse" files "$tmp/build.tsv" "$tmp/out"
  [ "$status" -ne 0 ]
  rmdir "$tmp/out/ironflockos-amd64-efi-other"
  rm -r "$tmp/out/ironflockos-rpi-arm64-base"
  run bash "$reuse" files "$tmp/build.tsv" "$tmp/out"
  [ "$status" -ne 0 ]
}

@test "files: refuses a manifest without every release image" {
  grep -v 'ironflockos-rpi-arm64-base/' "$tmp/build.tsv" >"$tmp/short.tsv"
  run bash "$reuse" files "$tmp/short.tsv" "$tmp/out" amd64-efi-base
  [ "$status" -ne 0 ]
}

@test "find: the pull request merged as the commit, its newest successful run, verified" {
  find_
  [ "$status" -eq 0 ]
  grep -qx 'run-id=900' "$tmp/output"
  grep -qx 'pr=216' "$tmp/output"
  grep -qx "commit=$M" "$tmp/output"
  grep -qx "tree=$T" "$tmp/output"
  ! grep -q '^why=' "$tmp/output"
  cmp "$tmp/work/build.tsv" "$tmp/build.tsv"
  # gh checks the signer exactly, the issuer, the ref and the runner
  verify=$(grep '^gh attestation verify' "$tmp/gh.log")
  [[ "$verify" == *"--repo IronFlock/ironflockos"* ]]
  [[ "$verify" == *"--cert-identity $SIGNER "* ]]
  [[ "$verify" == *"--cert-oidc-issuer https://token.actions.githubusercontent.com"* ]]
  [[ "$verify" == *"--source-ref refs/pull/216/merge"* ]]
  [[ "$verify" == *"--deny-self-hosted-runners"* ]]
}

@test "check: a dry run's own run, as the release run checks it" {
  run env PATH="$tmp/bin:$PATH" REPO="$REPO_NAME" GITHUB_OUTPUT="$tmp/output" bash "$reuse" check 900 216 "$M" "$tmp/work"
  [ "$status" -eq 0 ]
  grep -qx "commit=$M" "$tmp/output"
}

@test "find: refuses a commit that is no pull request's merge into main from this repository" {
  f=$tmp/api/$(key "repos/$REPO_NAME/commits/$H/pulls")
  cp "$f" "$tmp/pulls"
  for change in '.[0].head.repo.full_name = "someone/ironflockos"' '.[0].base.ref = "other"' \
    '.[0].merge_commit_sha = "5555555555555555555555555555555555555555"' '.[0].merged_at = null' '[]' '. + .'; do
    jq "$change" "$tmp/pulls" >"$f"
    rm -f "$tmp/output"
    find_
    refused "is not the merge of exactly one pull request" || { echo "$change"; return 1; }
  done
}

@test "find: refuses when the API does not answer" {
  rm "$tmp/api/$(key "repos/$REPO_NAME/commits/$H/pulls")"
  find_
  refused "the GitHub API did not answer"
}

@test "find: refuses without a successful run of ci.yml on the pull request from this repository" {
  f=$tmp/api/$(key "repos/$REPO_NAME/actions/workflows/ci.yml/runs?event=pull_request&head_sha=$X&status=success&per_page=100")
  cp "$f" "$tmp/runs"
  for change in '.workflow_runs[].event = "push"' '.workflow_runs[].path = ".github/workflows/other.yml"' \
    '.workflow_runs[].conclusion = "failure"' '.workflow_runs[].head_repository.full_name = "someone/ironflockos"' \
    '.workflow_runs[].head_sha = "5555555555555555555555555555555555555555"' '.workflow_runs = []'; do
    jq "$change" "$tmp/runs" >"$f"
    rm -f "$tmp/output"
    find_
    refused "has no successful ci run" || { echo "$change"; return 1; }
  done
}

@test "find: refuses missing, doubled, expired, expiring and old artifacts" {
  f=$tmp/api/$(key "repos/$REPO_NAME/actions/runs/900/artifacts?per_page=100")
  cp "$f" "$tmp/arts"
  for change in 'del(.artifacts[] | select(.name == "release-image-rpi-arm64-base"))' \
    'del(.artifacts[] | select(.name == "release-build-manifest"))' \
    '.artifacts += [.artifacts[] | select(.name == "release-image-amd64-efi-base")]'; do
    jq "$change" "$tmp/arts" >"$f"
    rm -f "$tmp/output"
    find_
    refused "does not have exactly one artifact" || { echo "$change"; return 1; }
  done
  jq '(.artifacts[] | select(.name == "release-image-amd64-efi-nvidia") | .expired) = true' "$tmp/arts" >"$f"
  rm -f "$tmp/output"
  find_
  refused "has expired"
  jq --arg e "$(iso 3600)" '(.artifacts[] | select(.name == "release-image-arm64-efi-base") | .expires_at) = $e' "$tmp/arts" >"$f"
  rm -f "$tmp/output"
  find_
  refused "expires within 6 hours"
  jq --arg c "$(iso -100000)" '(.artifacts[] | select(.name == "release-build-manifest") | .created_at) = $c' "$tmp/arts" >"$f"
  rm -f "$tmp/output"
  find_
  refused "is older than 24 hours"
}

@test "find: refuses a manifest artifact that is not one build.tsv of the release's images" {
  zip_manifest build.tsv other
  find_
  refused "is not one build.tsv"
  zip_manifest ../build.tsv
  rm -f "$tmp/output"
  find_
  refused "is not one build.tsv"
  grep -v 'ironflockos-rpi-arm64-base/' "$tmp/build.tsv" >"$tmp/short.tsv"
  cp "$tmp/short.tsv" "$tmp/build.tsv"
  zip_manifest build.tsv
  rm -f "$tmp/output"
  find_
  refused "is not a manifest of the images"
}

@test "find: refuses a manifest without the harness's attestation, after three tries" {
  touch "$tmp/attest.fail"
  find_
  refused "has no attestation of the harness"
  [ "$(grep -c '^gh attestation verify' "$tmp/gh.log")" = 3 ]
}

@test "find: refuses an attestation of another run, workflow, event, pull request, signer or runner" {
  for change in '.buildTrigger = "push"' '.buildTrigger = "pull_request_target"' \
    '.buildConfigURI = "https://github.com/IronFlock/ironflockos/.github/workflows/release.yml@refs/pull/216/merge"' \
    '.buildConfigURI = "https://github.com/IronFlock/ironflockos/.github/workflows/ci.yml@refs/pull/217/merge"' \
    '.runInvocationURI = "https://github.com/IronFlock/ironflockos/actions/runs/901/attempts/1"' \
    '.runInvocationURI = "https://github.com/IronFlock/ironflockos/actions/runs/9001/attempts/1"' \
    '.runInvocationURI = "https://github.com/IronFlock/ironflockos/actions/runs/900/attempts/1x"' \
    '.sourceRepositoryRef = "refs/pull/217/merge"' '.sourceRepositoryRef = "refs/heads/main"' \
    '.sourceRepositoryURI = "https://github.com/someone/ironflockos"' \
    '.subjectAlternativeName = "https://github.com/IronFlock/workflows/.github/workflows/attest-provenance.yml@refs/heads/main"' \
    '.subjectAlternativeName = "https://github.com/IronFlock/ironflockos/.github/workflows/release.yml@refs/pull/216/merge"' \
    '.issuer = "https://example.org"' '.runnerEnvironment = "self-hosted"' '.sourceRepositoryDigest = "abc"'; do
    set_cert "$change"
    rm -f "$tmp/output"
    find_
    refused "has no attestation of run 900" || { echo "$change"; return 1; }
  done
}

@test "find: refuses attestations of two commits" {
  { cert; cert | jq '.sourceRepositoryDigest = "5555555555555555555555555555555555555555"'; } |
    jq -s '[.[] | {verificationResult: {signature: {certificate: .}}}]' >"$tmp/attest.json"
  find_
  refused "or several commits"
}

@test "find: refuses a run that built another tree, or a tree it cannot look up" {
  jq -n '{tree: {sha: "5555555555555555555555555555555555555555"}}' >"$tmp/api/$(key "repos/$REPO_NAME/git/commits/$M")"
  find_
  refused "whose tree is not the tree of $H"
  rm "$tmp/api/$(key "repos/$REPO_NAME/git/commits/$M")"
  rm -f "$tmp/output"
  find_
  [ "$status" -ne 0 ]
  ! grep -q '^run-id=' "$tmp/output"
  rm -f "$tmp/output"
  jq -n '{tree: {sha: "nope"}}' >"$tmp/api/$(key "repos/$REPO_NAME/git/commits/$M")"
  find_
  refused "no tree for commit $M"
}

@test "find and check: usage errors" {
  run env PATH="$tmp/bin:$PATH" REPO="$REPO_NAME" bash "$reuse" find not-a-commit "$tmp/work"
  [ "$status" -ne 0 ]
  run env PATH="$tmp/bin:$PATH" REPO="$REPO_NAME" bash "$reuse" check 900 216 "$M"
  [ "$status" -ne 0 ]
  run env PATH="$tmp/bin:$PATH" bash "$reuse" find "$H" "$tmp/work"
  [ "$status" -ne 0 ]
}

@test "build_commit: the pull request's head when it has HEAD's tree, else HEAD" {
  g=$tmp/git
  git init -q -b main "$g"
  git -C "$g" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
  git -C "$g" checkout -q -b topic
  echo a >"$g/a"
  git -C "$g" add a
  GIT_COMMITTER_DATE=@1700000000 git -C "$g" -c user.name=t -c user.email=t@t commit -q -m head
  head=$(git -C "$g" rev-parse HEAD)
  git -C "$g" checkout -q main
  # GitHub's test merge: base and head, the head's tree
  GIT_COMMITTER_DATE=@1800000000 git -C "$g" -c user.name=t -c user.email=t@t merge -q --no-ff -m merge topic
  merge=$(git -C "$g" rev-parse HEAD)
  [ "$(build_commit "$g" "$head")" = "$head 1700000000" ]
  [ "$(build_commit "$g")" = "$merge 1800000000" ]
  [ "$(build_commit "$g" "")" = "$merge 1800000000" ]
  # a head with another tree (not up to date), or none here: HEAD
  base=$(git -C "$g" rev-parse HEAD~1)
  [ "$(build_commit "$g" "$base" 2>/dev/null)" = "$merge 1800000000" ]
  [ "$(build_commit "$g" 5555555555555555555555555555555555555555 2>/dev/null)" = "$merge 1800000000" ]
  [ "$(build_commit "$g" "not a commit" 2>/dev/null)" = "$merge 1800000000" ]
}

@test "release.yml: a release reuses only what source verified, and builds otherwise" {
  wf=$repo/.github/workflows/release.yml
  job() { awk -v job="  $1:" '$0 == job { f = 1; print; next } f && /^  [a-z][a-z-]*:$/ { exit } f' "$wf"; }
  # source: every step of the lookup may fail; the decision step always runs
  [ "$(job source | grep -c 'continue-on-error: true')" = 3 ]
  [[ "$(job source)" == *'build/reuse.sh find "$COMMIT"'* ]]
  [[ "$(job source)" == *'if: always()'* ]]
  [[ "$(job source)" == *'**Images: built** in this run'* ]]
  # build only without reuse; sign checks every file against the manifest
  [[ "$(job build)" == *"needs.source.outputs.reuse != 'true'"* ]]
  [[ "$(job sign)" == *'build/reuse.sh files manifest/build.tsv out "$IMAGE"'* ]]
  [[ "$(job sign)" == *'run-id: ${{ needs.source.outputs.run-id }}'* ]]
  # the dry run attests its manifest and checks its own run, on pull requests
  [[ "$(job attest-build)" == *"github.event_name == 'pull_request'"* ]]
  [[ "$(job attest-build)" == *'dry-run: false'* ]]
  [[ "$(job would-reuse)" == *'build/reuse.sh check "$RUN" "$PR" "$COMMIT"'* ]]
  # nothing of the release run reads a pull request's event
  ! job source | grep -q 'github.event.pull_request'
  ! job sign | grep -q 'github.event.pull_request'
}
