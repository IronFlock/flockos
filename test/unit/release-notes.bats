#!/usr/bin/env bats
# The release notes' format (`just check-release-notes`, part of `just lint`):
# release-notes/<x.y.z>.md with the sections Security, New, Fixed and Changed,
# in that order, the empty ones left out, no level-1 heading.

repo="$BATS_TEST_DIRNAME/../.."

setup() { tmp=$(mktemp -d); }
teardown() { rm -rf "$tmp"; }

# check NAME CONTENT: the check's verdict on one file, ok or its first message.
check() {
  printf '%b' "$2" >"$tmp/$1"
  if out=$(just -f "$repo/Justfile" -d "$repo" check-release-notes "$tmp/$1" 2>&1); then
    echo ok
  else
    printf '%s\n' "$out" | head -n 1 | sed "s|$tmp/||"
  fi
}

@test "all four sections, in order" {
  [ "$(check 0.11.0.md '## Security\n\n- A fix.\n\n## New\n\n- A.\n\n## Fixed\n\n- B.\n\n## Changed\n\n- C.\n')" = ok ]
}

@test "deeper headings are content" {
  [ "$(check 0.11.1.md '## Fixed\n\n- A bug.\n\n### Details\n\nMore.\n')" = ok ]
}

@test "out of order or twice" {
  [ "$(check 0.12.0.md '## New\n\n- A.\n\n## Security\n\n- B.\n')" = '0.12.0.md:5: "Security" twice or out of order (Security, New, Fixed, Changed)' ]
  [ "$(check 0.12.1.md '## Fixed\n\n- A.\n\n## Fixed\n\n- B.\n')" = '0.12.1.md:5: "Fixed" twice or out of order (Security, New, Fixed, Changed)' ]
}

@test "an unknown or empty section" {
  [ "$(check 0.13.0.md '## Improvements\n\n- A.\n')" = '0.13.0.md:1: unknown section "Improvements" (Security, New, Fixed, Changed)' ]
  [ "$(check 0.13.1.md '## Security\n\n## Fixed\n\n- A.\n')" = '0.13.1.md: section "Security" is empty: leave it out' ]
}

@test "a level-1 heading, text before the first section, no section" {
  [ "$(check 0.14.0.md '# FlockOS 0.14.0\n\n## New\n\n- A.\n')" = '0.14.0.md:1: no level-1 heading (the emails name the version)' ]
  [ "$(check 0.14.1.md 'Intro.\n\n## New\n\n- A.\n')" = '0.14.1.md:1: text before the first section' ]
  [ "$(check 0.14.2.md '\n')" = '0.14.2.md: no section (Security, New, Fixed, Changed)' ]
}

@test "the name must be <x.y.z>.md" {
  [ "$(check next.md '## New\n\n- A.\n')" = 'next.md: the name must be <x.y.z>.md' ]
}

@test "no release notes yet: nothing to check" {
  run just -f "$repo/Justfile" -d "$repo" check-release-notes
  [ "$status" -eq 0 ]
}
