# Release notes

One file per stable tag, `vX.Y.Z.md`, holding the body of that GitHub Release verbatim. Notes are
authored here and published from here, so the body that ships is reviewable in a diff and
reproducible from a commit.

## The invariant is "matches the published body", not "frozen at the tag"

A file here tracks what the Release **currently says**, not what it said the day it was tagged. So
a correction to an already-published body — a broken link, a wrong spec count, a clarification
someone asked for — is expected to change the file too, in the same change that changes the
Release. The two are one artifact stored twice.

That makes the browser's "Edit release" box the thing to avoid: it changes one copy and leaves no
diff. Re-publish from the file instead:

```bash
gh release edit vX.Y.Z --notes-file docs/releases/vX.Y.Z.md
```

## Format

No front matter and no `# vX.Y.Z` title heading — the Releases page renders the tag as the page
h1, so a title in the body duplicates it. The file starts with the first line of the body.

See the [release runbook](../development/release-process.md) for which sections a body carries and
when each one applies.

## Verifying

Every file, or just the tags named as arguments:

```bash
./scripts/verify-release-notes.sh
```

It compares against `--template '{{.body}}'`, which emits the stored body byte-for-byte. `--jq .body`
appends a newline and would report a difference on every release that already has one.

Because the comparison is byte-exact, it also catches a trailing newline
appearing or disappearing — `v1.1.0`, `v1.2.0`, `v1.3.0`, and `v1.3.1` were published without a
final newline and are stored that way, so an editor that adds one on save will show up here. That
is the check working: the file no longer matches what is published, and the fix is to re-publish it.
