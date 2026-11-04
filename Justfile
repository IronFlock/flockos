# FlockOS: the IronFlock device OS, built as disk images and RAUC bundles in
# CI only (docs/master-plan.md). Phase 0 skeleton: the recipes the harness
# gates on exist and pass; the image build arrives with Phase 1.

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
    scripts=$(git ls-files | xargs -r grep -lE '^#!/(usr/)?bin/(env )?(ba)?sh' 2>/dev/null || true)
    if [ -n "$scripts" ]; then
        if command -v shellcheck >/dev/null; then
            echo "==> shellcheck"
            echo "$scripts" | xargs shellcheck -x
        else
            echo "==> shellcheck not installed, skipped"
        fi
    fi
    if command -v yamllint >/dev/null; then
        echo "==> yamllint"
        yamllint -d '{extends: default, rules: {line-length: disable, document-start: disable, truthy: disable}}' .github/workflows
    fi
    echo "==> lint OK"

# Unit tests (bats) of the build and RAUC backend scripts; none yet
test:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -d test/unit ]; then
        bats test/unit
    else
        echo "no unit tests yet (Phase 1 adds test/unit)"
    fi

# Build one image: just build TARGET VARIANT (placeholder until Phase 1)
build TARGET="amd64-efi" VARIANT="base":
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{ TARGET }}" in
        amd64-efi | arm64-efi | rpi-arm64 | jetson-orin) ;;
        *) echo "unknown target {{ TARGET }}" >&2; exit 2 ;;
    esac
    case "{{ VARIANT }}" in
        base | nvidia | installer) ;;
        *) echo "unknown variant {{ VARIANT }}" >&2; exit 2 ;;
    esac
    echo "flockos {{ VERSION }}: build {{ TARGET }}/{{ VARIANT }} is not implemented yet (Phase 1)"

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
