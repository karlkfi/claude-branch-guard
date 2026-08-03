#!/usr/bin/env bash
#
# Diffs every docs/releases/vX.Y.Z.md against the body GitHub currently serves
# for that tag. The files are what the runbook publishes from, so the copy that
# can drift is the published one: an edit made in the browser changes it and
# leaves no diff anywhere. Requires gh on PATH and authenticated, so this is
# not part of test/run.sh, which is hermetic and offline.
#
# Usage: scripts/verify-release-notes.sh [vX.Y.Z ...]   (default: every file)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NOTES_DIR="$REPO_ROOT/docs/releases"

WORK="$REPO_ROOT/tmp/verify-release-notes.$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

if ! command -v gh >/dev/null 2>&1; then
  printf 'gh is not on PATH; cannot read the published bodies\n' >&2
  exit 1
fi

tags=()
if [[ $# -gt 0 ]]; then
  tags=("$@")
else
  for f in "$NOTES_DIR"/v*.md; do
    [[ -e "$f" ]] || continue
    tags+=("$(basename "$f" .md)")
  done
fi

# An empty list would otherwise report "0 failed" and exit 0, which reads as
# a clean check rather than a check that never ran.
if [[ ${#tags[@]} -eq 0 ]]; then
  printf 'no release notes found under docs/releases\n' >&2
  exit 1
fi

pass=0
fail=0
for tag in "${tags[@]}"; do
  notes="$NOTES_DIR/$tag.md"
  if [[ ! -f "$notes" ]]; then
    printf 'FAIL - %s: docs/releases/%s.md does not exist\n' "$tag" "$tag"
    fail=$((fail + 1))
    continue
  fi
  # --template, not --jq: `--jq .body` appends a newline unconditionally, so it
  # reports a difference on every release whose body already ends with one.
  # Redirect straight to a file — routing the body through a shell variable
  # would strip its trailing newlines and defeat the byte-exact comparison.
  if ! gh release view "$tag" --json body --template '{{.body}}' \
      > "$WORK/$tag.published" 2>"$WORK/$tag.err"; then
    printf 'FAIL - %s: could not read the published release\n' "$tag"
    sed 's/^/         /' "$WORK/$tag.err" >&2
    fail=$((fail + 1))
    continue
  fi
  if diff -q "$WORK/$tag.published" "$notes" >/dev/null; then
    printf 'ok   - %s\n' "$tag"
    pass=$((pass + 1))
  else
    printf 'FAIL - %s: published body differs from docs/releases/%s.md\n' \
      "$tag" "$tag"
    diff "$WORK/$tag.published" "$notes" | sed 's/^/         /' || true
    fail=$((fail + 1))
  fi
done

printf '\n%d match, %d differ\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
