# branch-guard

A Claude Code plugin that adds a `PreToolUse` hook for `Bash`, `Edit`, `Write`, `MultiEdit`, and `NotebookEdit`. Its job is to **minimize routine git/branch approval prompts** (especially in `acceptEdits` and non-interactive modes) while keeping a human in the loop for protected-branch and destructive operations. For Bash it classifies each `git`/`gh` command and auto-approves the safe ones (read-only git/gh, staging, branch creation, fetch, a commit/push of a feature/worktree branch), asks before protected-branch or destructive ones (`reset --hard`, `clean -f`, `branch -D`, …), and defers on anything it can't classify. For edits it asks when the file's repo is on a protected branch. See `README.md` for the user-facing overview and the decision tables.

The load-bearing piece is `hooks/branch-guard.py` — a stdlib-only Python hook that reads the `PreToolUse` JSON from stdin and emits a decision against `PROTECTED_BRANCH_RE`. For Bash it lexes the command with `shlex` (matching workspace-guard's parsing model) via `tokenize` into a flat raw token list, splits that into simple-command segments with `command_segments`, and parses each with `parse_invocation` (handles `git` *and* `gh`, env prefixes, global flags, combined short flags) rather than substring matching. `classify_segment` returns `('allow'|'ask'|'defer'|'nongit', reason)` per segment via `classify_git`/`classify_gh`; `main()` combines them — **any `ask` wins; else every segment must be `allow`; else defer**. `has_shell_substitution` runs over the *raw* token list (before redirect targets are stripped) and downgrades a would-be `allow` to defer when a token hides command/process substitution (`` `…` ``, `$(…)`, `<(…)`/`>(…)`) or an unrecognized operator run (`|&`) — the same downgrade-only discipline as `GIT_ESCAPE_HATCHES`, never weakening an `ask`. For edits it resolves the branch of **the file's own repository** (`git -C <dir-of-file>`), not the session cwd — reading the path from `notebook_path` for `NotebookEdit` and `file_path` for the others, and deferring if neither is present.

The git/gh classifier is the contract: `READONLY_GIT` (allow on any branch), `READONLY_GH` (allow), per-subcommand rules in `classify_git` (safe mutations like `add`/`switch -c`/`worktree add`; `_feature()` for branch-sensitive mutations — allow on non-protected, ask on protected; destructive → ask; unknown → defer). `GIT_ESCAPE_HATCHES` (`-c`/`--config-env`) downgrade a would-be `allow` to defer (but never weaken an `ask`). `short_flag_letters` decomposes bundled flags (`-fd`).

The push guard (`push_decision`/`push_policy`) is driven by the `BRANCH_GUARD_PUSH_POLICY` env var: `strict` (default — **allow** a push of the worktree's own branch including force pushes, **ask** for anything else), `protected` (ask only when a push targets `main`/`master`, never auto-approve), or `off`. A command is auto-approved only when *every* segment is a recognized-safe git/gh invocation, so a non-git command (`git push && rm …`) can never ride along into an allow.

`confirm()` converts a would-be `ask` into a `deny` when `permission_mode` is one of `NON_INTERACTIVE_MODES` (`auto`/`dontAsk`/`bypassPermissions`) — no human is present to answer, so the guard fails safe. Every `ask` (the single Bash combine-site and the edit path) goes through `confirm()`; `allow` and defer are never downgraded. Classifier verdicts carry only the `ask` *reason*; `main()` is the one place that emits.

## Model selection

Use the `model-advisor` skill to assess the right model and thinking level at session start and whenever the task type shifts significantly (e.g. moving from a one-line regex tweak to reworking how the hook tokenizes commands or resolves branches).

## Development philosophy

Build the right thing AND build it well. Before writing any code, state the goal in one sentence and the approach in two or three. If the goal is unclear, ask one focused question rather than guessing.

Make the smallest change that achieves the goal. If you notice problems outside the current task's scope, flag them rather than fixing them — mention them at the end of the turn or open a separate PR.

Before introducing a new pattern or abstraction, check whether the existing tool dispatch in `main()` and `PROTECTED_BRANCH_RE` already solve the problem with a small edit. The lexing/parsing pipeline (`tokenize` → `command_segments` → `parse_invocation`) is deliberately shared in spirit with workspace-guard — reuse that model rather than inventing a parallel one.

## Workflow

1. **At session start, check whether the worktree is stale.** New worktrees are branched from `main` at creation time, but `main` may have advanced since then — particularly if a previous session merged a PR. Run `git fetch origin main` and compare with `git log --oneline HEAD..origin/main`; if `origin/main` has new commits, rebase with `git rebase origin/main` before doing any other work.
2. **Before making changes** — read `README.md` and the whole of `hooks/branch-guard.py` so the proposed change matches the existing dispatch and tokenization model. If picking the next task, run `gh pr list` first and skip anything already covered by an open PR.
   - **Verify behavioral claims end-to-end, not just by source-reading.** Shell tokenization is full of surprises that only show up when you exec the thing. If a change depends on "command X parses as a git commit" or "this branch resolves to Y," actually run `./test/run.sh` (or a targeted reproduction) and confirm.
3. **After making changes** — review the diff and update docs proactively:
   - **Changed the decision logic, the git-commit detection, or `PROTECTED_BRANCH_RE`** → update the behavior table and "Known limitation" section in `README.md`.
   - **New configuration or hook surface** → `README.md`, `hooks/hooks.json`, and `.claude-plugin/plugin.json` keywords/description.
4. **Commit when done** — small, focused, Conventional Commits.

## Code standards

### Python (`hooks/branch-guard.py`)

- Stdlib only — no third-party deps. The hook runs on whatever `python3` the user has on their PATH (`hooks/hooks.json` invokes `python3 …`). `git` must be on PATH; the hook no longer shells out to `jq`.
- The contract is explicit data + dispatch: the tool dispatch in `main()`, `PROTECTED_BRANCH_RE`, `PUSH_POLICIES`, the classifier sets (`READONLY_GIT`, `READONLY_GH`, `GIT_ESCAPE_HATCHES`), and the per-subcommand rules in `classify_git`. Adding/guarding a subcommand, protected branch, or push policy means an explicit edit there — don't infer behavior at runtime.
- When classifying a subcommand, decide its tier deliberately: read-only → `allow` any branch; staging/branch-create → `allow` any branch; branch-sensitive mutation → `_feature()` (allow non-protected, ask protected); destructive → `ask`; **unknown or ambiguous → `defer`, never `allow`**. A subcommand that's read-only by default but mutating with a flag (`branch`, `tag`, `config`, `restore`, `clean`, `reflog`, `remote`, `worktree`, `stash`) needs its flags checked — use `short_flag_letters` for bundled short flags (`-fd`). When unsure whether a form is safe, defer.
- Tokenize Bash commands with `shlex` via `tokenize` → `command_segments` → `parse_invocation`; never go back to substring/regex matching on the raw command — that's the exact gap the python port closed. `GIT_VALUE_OPTS`/`GH_VALUE_OPTS`/`PUSH_VALUE_OPTS` list the options that consume a following value token, and `PUSH_MANY_FLAGS` the ones that push more than one branch; extend these explicitly rather than guessing at parse time. `shlex` doesn't model every construct that runs a command (command/process substitution, `|&`), so `has_shell_substitution` over the raw `tokenize` output downgrades a would-be `allow` to defer — run that check on the raw tokens (pre-redirect-stripping), and only to weaken an `allow`, never an `ask`.
- The push guard leans toward asking (`strict`) / deferring (`protected`) on refspec forms it can't classify — never toward silently allowing. Hard guarantees belong in a git `pre-push` hook or server-side branch protection; keep `README.md`'s "best-effort" framing honest.
- On any uncertainty — not a git repo, detached HEAD, empty/missing input, unbalanced quotes (`shlex` raises `ValueError`), unresolvable branch — the hook **defers silently** (returns, emits nothing) so normal permissions apply. Never fail closed without an explicit reason.
- The interactive decision for a protected branch is `ask`, not `deny`. The one exception is non-interactive permission modes, where `confirm()` deliberately upgrades `ask` → `deny` because no human can answer — that's failing *safe*, not hard-blocking by default. Don't add a blanket `deny` for interactive modes without sign-off.
- Emit decisions through `emit()` (`json.dumps`), and route every `ask` through `confirm()` so the non-interactive fail-safe applies uniformly — don't hand-build decision JSON or call `emit('ask', …)` directly.

## Security principles

**Secure by default, not opt-in.** This plugin exists to add a guardrail; its defaults must never trade away a security property for convenience. If a proposed change weakens any property — even partially, even with mitigations — the more secure behavior stays the default. The looser behavior may be offered as an explicit opt-in (env var, config, local edit) but must be documented as a trade-off.

Examples of regressions that must not silently become defaults:
- Flipping the protected-branch decision from `ask` to `allow`.
- Removing `main` or `master` from `PROTECTED_BRANCH_RE` because it was "noisy".
- Treating an unresolvable branch or unparseable input as `allow` rather than deferring.
- Auto-approving a command that contains any non-git/gh segment (e.g. `git status && rm -rf foo`). Allow fires only when *every* segment is recognized-safe; widening this lets a trailing command ride along into a silent approval — the exact gap the Python port closed.
- Moving a subcommand into the `allow` tiers (`READONLY_GIT`, the safe-mutation cases) without checking its mutating flags — e.g. allowing `git restore` (discards the worktree) or `git checkout <name>` (ambiguous branch-vs-file discard). Default ambiguous/unknown forms to `defer`.
- Letting a `git -c …`/`--config-env` escape hatch reach an `allow` (it must downgrade to defer), or weakening the push-policy default — `strict` must stay the default; `protected`/`off` are looser and opt-in only.
- Downgrading the non-interactive fail-safe: in `auto`/`dontAsk`/`bypassPermissions` an `ask` must stay a `deny`. Letting it fall back to `ask` (or `allow`) means an unattended session runs a destructive command or pushes/commits to `main` with nobody to stop it.
- Resolving the edit branch from the session cwd instead of the file's own repo (`git -C <dir-of-file>`), so edits through a checkout sitting on `main` are no longer caught.

When in doubt, ask before shipping. The hook's job is to add friction at the protected-branch boundary; removing friction is the change that needs sign-off, not adding it.

## Testing

Tests live in `test/run.sh`. Run with:

```bash
./test/run.sh
```

It spins up a throwaway git repo under `tmp/` and asserts the emitted `permissionDecision` across the matrix: commits and all-git/mixed chains, env-prefixed/global-flag commits, the read-only git allowlist, safe mutations (`add`/`switch -c`/`worktree add`/`restore --staged`), destructive commands (`reset --hard`/`clean -fd`/`branch -D`/`config --global`/…), branch-sensitive mutations on feature vs protected (`rebase`/`merge`/`pull`), the inline-config escape hatch, read-only vs mutating `gh`, edits, all three push policies, and the non-interactive-mode `ask`→`deny` conversion. The harness sets `BRANCH_GUARD_PUSH_POLICY`/`permission_mode` per case (and `unset`s the policy up top for hermeticity), and parses the hook's JSON with `jq`, so `jq` is a test-only dependency.

When changing the classifier (`classify_git`/`classify_gh`, the allowlist sets), the push logic, or `PROTECTED_BRANCH_RE`, add the case that motivated the change as a fixture, and hand-exercise the behavior table in `README.md` against the change before committing. New SPEC-style rules are easy to get subtly wrong — actually run `./test/run.sh`.

## Commits

- Commit after each task is complete and validated.
- Use small, focused commits following the Conventional Commits standard.
- Amending an unpushed commit is fine — fix up the message or staged changes before pushing without asking. Once a commit is pushed, prefer a follow-up commit; only amend + force-push (always `--force-with-lease`, never on `main`/`master`) when the user asks for it.
- After pushing, check whether a PR exists (`gh pr view`). If one does, update its description with `gh pr edit` to reflect any new commits.
- If a change doesn't belong in the current PR, open a separate PR for it. Working multiple PRs in parallel is fine and preferable to bundling unrelated concerns.

## Documentation conventions

Human-facing docs (`README.md` and anything user-facing) must never link to `CLAUDE.md` or `AGENTS.md`. This file is the entrypoint for Claude/agents only; humans start at `README.md`. The dependency direction is one-way: `CLAUDE.md` may link out to `README.md` and other docs, but nothing user-facing may link back to it.

## Agent reference docs

| Task | Reference |
|---|---|
| Changing which git/gh commands auto-allow vs ask (the classifier) | `hooks/branch-guard.py` (`classify_git`/`classify_gh`, `READONLY_GIT`/`READONLY_GH`) + `README.md` behavior table |
| Changing the decision logic, git/push detection, or protected-branch set | `hooks/branch-guard.py` + `README.md` behavior & push-guard tables |
| Changing push-guard policies or the `BRANCH_GUARD_PUSH_POLICY` config | `hooks/branch-guard.py` (`push_decision`/`push_policy`/`PUSH_POLICIES`) + `README.md` "Push guard" section |
| Hook registration / matcher | `hooks/hooks.json` |
| Plugin packaging / marketplace listing | `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` |
| Testing the decision matrix | `test/run.sh` |
| Rendering or regenerating brand images (social preview, favicon) | `docs/development/rendering-images.md` |
| Cutting a release (version bump, tag, GitHub Release) | `docs/development/release-process.md` |
