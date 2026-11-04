# FlockOS: the IronFlock device OS, built as disk images and RAUC bundles in
# CI (docs/master-plan.md, docs/build.md). The build runs in a Debian 13
# container (build/builder.conf), so a local build with Docker produces the
# same image as CI; CI stays the build of record.

VERSION := `cat VERSION | tr -d '[:space:]'`
RELEASE_NAME := "flockos"
VERSION_FILE := "VERSION"

# Every file _write-version changes; the release commit holds exactly these.

VERSION_FILES := "VERSION"

# Show available commands
default:
    @just --list

# Static checks as CI runs them: Justfile format, shellcheck, workflow YAML
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "==> just --fmt --check"
    just --fmt --check --unstable
    # Shell scripts: a sh or bash shebang on the first line (a shebang in a
    # test's heredoc does not count).
    scripts=$(git ls-files | while read -r f; do [ -f "$f" ] && head -n 1 "$f" | grep -qE '^#!/(usr/)?bin/(env )?(ba)?sh$' && echo "$f"; done || true)
    if [ -n "$scripts" ]; then
        if command -v shellcheck >/dev/null; then
            echo "==> shellcheck"
            echo "$scripts" | xargs shellcheck -x
        else
            echo "==> shellcheck not installed, skipped"
        fi
    fi
    if [ -n "$scripts" ]; then
        if command -v shfmt >/dev/null; then
            echo "==> shfmt"
            echo "$scripts" | xargs shfmt -d -i 2 -ci
        else
            echo "==> shfmt not installed, skipped"
        fi
    fi
    if command -v go >/dev/null; then
        echo "==> gofmt, go vet (tools/rauc-pki)"
        unformatted=$(gofmt -l tools/rauc-pki)
        [ -z "$unformatted" ] || { echo "gofmt: $unformatted"; exit 1; }
        go -C tools/rauc-pki vet ./...
    else
        echo "==> go not installed, tools/rauc-pki skipped"
    fi
    echo "==> python syntax"
    git ls-files '*.py' | xargs -r python3 -I -c 'import ast, sys; [ast.parse(open(f).read(), f) for f in sys.argv[1:]]'
    if command -v yamllint >/dev/null; then
        echo "==> yamllint"
        yamllint -d '{extends: default, rules: {line-length: disable, document-start: disable, truthy: disable}}' .github/workflows
    fi
    echo "==> lint OK"

# Unit tests: bats for the build and image scripts, go test for tools/rauc-pki
test:
    #!/usr/bin/env bash
    set -euo pipefail
    bats test/unit
    if command -v go >/dev/null; then
        go -C tools/rauc-pki test -count=1 ./...
    else
        echo "go not installed: tools/rauc-pki tests skipped"
    fi

# Build one image into out/<image-id>/: just build TARGET VARIANT [KERNEL]
build TARGET="amd64-efi" VARIANT="base" KERNEL="std":
    build/run-in-builder.sh {{ TARGET }} {{ VARIANT }} {{ KERNEL }}

# Boot a built image in QEMU and run the image tests (KVM where available)
qemu-test TARGET="amd64-efi" VARIANT="base" *ARGS:
    python3 -I test/qemu/run.py --target {{ TARGET }} --variant {{ VARIANT }} {{ ARGS }}

# ------------------------------------------------------------------ release --
# Pull requests into main, from IronFlock/workflows (scripts/pr.sh at v1):
#   just merge [TITLE]      a no-release pull request from this feature branch
#   just release-patch      a release pull request (-minor, -major): the bump
#                           from main's version on top of this branch (or on a
#                           new branch release/v<x> from an up-to-date main)
# Both merge automatically once ci and security are green. The merge of a
# release pull request runs .github/workflows/release.yml.

# Write the version file(s); called by pr.sh with the next version
_write-version NEW:
    #!/usr/bin/env bash
    set -euo pipefail
    printf '%s\n' "{{ NEW }}" > VERSION
    echo "version {{ VERSION }} -> {{ NEW }}"

[positional-arguments]
_pr *args:
    #!/usr/bin/env bash
    set -euo pipefail
    script=$(mktemp)
    trap 'rm -f "$script"' EXIT
    if ! gh api -H 'Accept: application/vnd.github.raw' \
        'repos/IronFlock/workflows/contents/scripts/pr.sh?ref=v1' > "$script"; then
        echo "could not fetch pr.sh with gh (see above). An exported GH_TOKEN or GITHUB_TOKEN overrides gh's own login: unset it, check gh auth status, then run this again." >&2
        exit 1
    fi
    bash "$script" "$@"

# Open a no-release pull request from this branch
[positional-arguments]
merge TITLE="":
    just _pr merge {{ VERSION_FILE }} "$1"

# Open a release pull request with the patch version bumped
release-patch:
    just _pr release patch {{ RELEASE_NAME }} {{ VERSION_FILE }} release.yml {{ VERSION_FILES }}

# Open a release pull request with the minor version bumped
release-minor:
    just _pr release minor {{ RELEASE_NAME }} {{ VERSION_FILE }} release.yml {{ VERSION_FILES }}

# Open a release pull request with the major version bumped
release-major:
    just _pr release major {{ RELEASE_NAME }} {{ VERSION_FILE }} release.yml {{ VERSION_FILES }}
