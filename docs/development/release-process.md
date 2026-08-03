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
   gh release create vX.Y.Z --title "vX.Y.Z" --latest --notes-file notes.md
   ```

   See §Release notes for the body format.

## The direct-to-main exception

Feature and fix work goes through PRs; the release bump does **not**. The bump commit is pushed directly to `main` and then tagged. This keeps the tag pointing at a commit that exists on `main` with no merge-commit indirection.

This is the *only* sanctioned direct-to-main push. It is narrow by design: a two-line version bump with no logic. Anything bundled with substantive code would need a PR — so keep the bump commit pure. The standing rules still hold: never force-push `main`, and never bundle unrelated changes into the bump.

## Release notes

Notes open with a one-line statement of what the plugin is, then a `> [!NOTE]` callout for any visible behavior change. After that comes a menu of sections — **use only the ones this release can fill**, in this order. `v1.4.1` is the worked example; `gh release view v1.4.1` shows the shape.

| Section | Include when | Contents |
|---|---|---|
| **Highlights** | Any user-facing change | A bold linked lede per change, then the *mechanism* — which function was wrong and how — not just the symptom. Link the README pinned at the release tag (`blob/vX.Y.Z/README.md#anchor`), never `main`, so an operator on an older release reads that release's docs. |
| **Upgrading** | Always | Whether any step is required (usually none), the `claude plugin update` commands, and a **needs no action but will be visible** subsection for every default that changed. |
| **Everything since v<PREV>** | Always | A bullet per PR: `* <title> by @<author> in <PR-url>`. Say explicitly what the list omits — "all of them shipped below" when nothing is withheld, or "build and CI work is left out" when it is. Fold long lists into `<details>`. |
| **Decision surface** | The classifier, push policy, or `PROTECTED_BRANCH_RE` moved | A before/after table of the decisions that changed, plus the standing claim that nothing else moved ("one row added, nothing removed"). This is the section a reader checks to know whether their auto-approved commands still are. |
| **Validation** | Always | Spec count and platforms, **verified on the release commit itself** with a link to that run — not "CI is green". Close with what the suite does *not* assert. |
| **Security** | Always | No-advisory releases say so. Note that the hook is stdlib-only so there is nothing to bump, and keep the best-effort caveat: `bypassPermissions` ignores hook decisions, so hard guarantees need a git `pre-push` hook or server-side branch protection. |

Close with a **Full changelog:** line linking `https://github.com/karlkfi/claude-branch-guard/compare/v<PREV>...vX.Y.Z`.

To enumerate what shipped since the last tag:

```
git log --oneline v<PREV>..HEAD
```

`gh release create ... --generate-notes` produces the PR bullet list, which is the raw material for **Everything since v<PREV>** — the rest is written by hand. Publish with `--notes-file`; a body this size does not belong on a command line.

## The first release

There is no prior tag yet, so a couple of steps adapt:

- The `git log v<PREV>..HEAD` enumeration becomes `git log --oneline` over the whole history.
- The **Full changelog** line has no `v<PREV>` to compare against. Either drop it, or point it at the repo's first commit: `.../compare/<root-sha>...vX.Y.Z`. `gh release create ... --generate-notes` handles this automatically for the first release.
- The version is already `0.1.0` (pre-1.0). Decide deliberately whether the first release tags the current `0.1.0` as-is or bumps first; everything else in this checklist applies unchanged.

## Anti-patterns to watch for

- **Bumping only one of the two version files.** They must stay identical; a mismatch ships a marketplace listing that disagrees with the installed plugin.
- **Routing the bump through a PR.** The established flow is direct-to-main; a PR adds a merge commit the tag then has to point around.
- **Bundling code or docs into the bump commit.** That turns the sanctioned direct-to-main push into an unsanctioned one. Land everything else first, then bump.
- **Tagging before pushing the bump.** Push `main` first, then tag the commit that's now on `main`, so the tag is never orphaned on a branch.
- **Skipping the GitHub Release.** A tag without a Release breaks the "Full Changelog" chain and the Latest marker; every tag should have a matching Release.
