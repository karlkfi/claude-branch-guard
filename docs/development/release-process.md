# Agent reference: Cutting a release

A release is three artifacts that must agree: the **version string** (in two files), an **annotated git tag**, and a **GitHub Release**. This doc is the checklist for producing all three consistently. Releases are the one place where a commit lands on `main` without a PR — that exception is deliberate and scoped to the version bump only (see §The direct-to-main exception).

## The version string lives in exactly two files

Both must be bumped together and kept identical:

- `.claude-plugin/plugin.json` → `"version"`
- `.claude-plugin/marketplace.json` → `plugins[0].version`

Nothing else in the repo encodes the version (no README badge, no `__version__`). If you add a third location, add it here too. To confirm before bumping:

```
grep -rn '"version"' .claude-plugin/
```

## Steps

1. **Start from a fresh `main`.** Releases must include everything merged. Rebase the worktree:

   ```
   git fetch origin main && git rebase origin/main
   ```

2. **Run the full test suite — it must be green.**

   ```
   ./test/run.sh
   ```

3. **Bump both version files** to the new `X.Y.Z`. Patch (`Z`) for fixes, docs, and packaging; minor (`Y`) for new guarded commands or hook surface; major (`X`) for a default-behavior change. Most releases are patch.

4. **Commit the bump alone** — no other changes in this commit:

   ```
   git commit -am "chore(release): bump version to X.Y.Z"
   ```

5. **Push the bump straight to `main`** (see §The direct-to-main exception):

   ```
   git push origin HEAD:main
   ```

6. **Tag the bump commit** with an annotated tag whose message is just the version:

   ```
   git tag -a vX.Y.Z -m "vX.Y.Z" <bump-commit-sha>
   git push origin vX.Y.Z
   ```

7. **Create the GitHub Release** on that tag, marked latest:

   ```
   gh release create vX.Y.Z --title "vX.Y.Z" --latest --notes "..."
   ```

   See §Release notes for the body format.

## The direct-to-main exception

Feature and fix work goes through PRs; the release bump does **not**. The bump commit is pushed directly to `main` and then tagged. This keeps the tag pointing at a commit that exists on `main` with no merge-commit indirection.

This is the *only* sanctioned direct-to-main push. It is narrow by design: a two-line version bump with no logic. Anything bundled with substantive code would need a PR — so keep the bump commit pure. The standing rules still hold: never force-push `main`, and never bundle unrelated changes into the bump.

## Release notes

- A one-line intro summarizing the release theme (e.g. "Patch release: a parsing hardening fix and docs improvements.").
- A bullet per notable PR: `* <title> by @<author> in <PR-url>`. Curate — highlight user-facing changes; routine chores can be folded into the changelog link.
- A trailing `**Full Changelog**: https://github.com/karlkfi/claude-branch-guard/compare/v<PREV>...vX.Y.Z` line.

To enumerate what shipped since the last tag:

```
git log --oneline v<PREV>..HEAD
```

`gh release create ... --generate-notes` produces a usable first draft in this shape; edit the intro line and prune the bullets before publishing. Once a release exists, `gh release view v<PREV>` is a good reference for the established format.

## The first release

There is no prior tag yet, so a couple of steps adapt:

- The `git log v<PREV>..HEAD` enumeration becomes `git log --oneline` over the whole history.
- The **Full Changelog** line has no `v<PREV>` to compare against. Either drop it, or point it at the repo's first commit: `.../compare/<root-sha>...vX.Y.Z`. `gh release create ... --generate-notes` handles this automatically for the first release.
- The version is already `0.1.0` (pre-1.0). Decide deliberately whether the first release tags the current `0.1.0` as-is or bumps first; everything else in this checklist applies unchanged.

## Anti-patterns to watch for

- **Bumping only one of the two version files.** They must stay identical; a mismatch ships a marketplace listing that disagrees with the installed plugin.
- **Routing the bump through a PR.** The established flow is direct-to-main; a PR adds a merge commit the tag then has to point around.
- **Bundling code or docs into the bump commit.** That turns the sanctioned direct-to-main push into an unsanctioned one. Land everything else first, then bump.
- **Tagging before pushing the bump.** Push `main` first, then tag the commit that's now on `main`, so the tag is never orphaned on a branch.
- **Skipping the GitHub Release.** A tag without a Release breaks the "Full Changelog" chain and the Latest marker; every tag should have a matching Release.
