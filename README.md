# branch-guard

**Branch-aware git permissions for Claude Code.**

[![release](https://img.shields.io/github/v/release/karlkfi/claude-branch-guard)](https://github.com/karlkfi/claude-branch-guard/releases) [![tests](https://img.shields.io/github/actions/workflow/status/karlkfi/claude-branch-guard/tests.yml?branch=main&label=tests)](https://github.com/karlkfi/claude-branch-guard/actions/workflows/tests.yml) [![License: MIT](https://img.shields.io/github/license/karlkfi/claude-branch-guard.svg)](LICENSE) [![Claude Code plugin](https://img.shields.io/badge/Claude_Code-plugin-7e57c2)](#install)

> Let Claude commit and push all day on feature branches. Pause it at `main`.

Claude finishes a task and runs `git add -A && git commit -m "fix" && git push` —
straight onto whatever branch is checked out. Most of the time that's a throwaway
`claude/*` branch and you want it to just happen. Once in a while it's `main`, or
it's `git reset --hard`, or `git push origin HEAD:main`. The default
`Bash(git commit:*)` permission rules can't tell these apart — they either trust
every git command or prompt on every one.

branch-guard is a `PreToolUse` hook that classifies each `git`/`gh` command,
**auto-approves the safe ones** (read-only, staging, branch/worktree creation,
commits and pushes on a feature branch), and **prompts** before anything that
touches a protected branch (`main`/`master`) or is destructive. Everything else
defers to your normal permission settings.

## Contents

- [What it does](#what-it-does)
- [Behavior](#behavior)
- [Push guard](#push-guard)
- [Install](#install)
- [Upgrade](#upgrade)
- [How it works](#how-it-works)
- [Agent guidance: avoiding prompts](#agent-guidance-avoiding-prompts)
- [Configuration](#configuration)
- [Limitations](#limitations)
- [Companion plugin](#companion-plugin)
- [Privacy](#privacy)
- [Contributing](#contributing)
- [License](#license)

## What it does

The hook produces one of three outcomes per command:

- **allow** — the command runs without a prompt.
- **ask** — Claude Code shows its standard permission prompt. You approve or
  reject. In a non-interactive mode this becomes **deny** (see
  [Configuration](#configuration)).
- **defer** — the hook stays silent; your normal permission settings apply.

It guards the `Bash` tool (for `git` and `gh` commands) and the `Edit`, `Write`,
`MultiEdit`, and `NotebookEdit` tools (for the branch a file's repository is on).

## Behavior

For a Bash command, every segment is classified and the command-level decision
is: **any segment needs `ask` → ask; else every segment is recognized-safe →
allow; else defer.** A segment counts as recognized-safe if it's a safe git/gh
invocation *or* a pure read-only filter (a pager like `head`/`tail`/`wc`) piped
after one — so `git log | head` auto-approves, but a non-git, non-filter command
can never ride along into an approval.

The table below assumes the worktree is on a feature branch (`claude/x`) under
the default `strict` [push policy](#push-guard).

| Command | Decision |
| --- | --- |
| `git status` / `git diff` / `git log` | allow |
| `git add -A` | allow |
| `git switch -c claude/y` / `git checkout -b claude/y` | allow |
| `git worktree add ../wt feature` | allow |
| `git commit -m "fix"` *(feature branch)* | allow |
| `git add -A && git commit -m x && git push` *(feature branch)* | allow |
| `git push` / `git push -u origin HEAD` *(worktree branch)* | allow |
| `git push --force` *(worktree branch)* | allow |
| `gh pr view 123` / `gh pr list` / `gh repo view` | allow |
| `git log \| head` / `gh pr checks 123 \| head -20` / `git diff --stat \| tail -n 5` *(piped to a read-only filter)* | allow |
| `git pull --ff-only` | allow |
| `git commit -m "fix"` *(on `main`)* | **ask** |
| editing a file whose repo is on `main` *(Edit/Write/MultiEdit/NotebookEdit)* | **ask** |
| `git push origin main` / `git push origin HEAD:main` | **ask** |
| `git push origin other-branch` *(strict policy)* | **ask** |
| `git reset --hard HEAD~1` | **ask** |
| `git clean -fd` | **ask** |
| `git branch -D old` | **ask** |
| `git restore file.txt` *(discards working changes)* | **ask** |
| `git config --global user.name x` | **ask** |
| `git pull` *(may merge or rebase)* | **ask** |
| `git rebase`/`git merge` *(onto `main`)* | **ask** |
| `git status && rm -rf foo` *(non-git segment)* | defer |
| `git log \| cat file.txt` *(filter reads a file)* / `git status \| tee out` *(filter writes)* | defer |
| `head -5` *(no git/gh segment)* | defer |
| `` git status `touch evil` `` / `git commit -m "$(touch evil)"` *(hidden command substitution)* | defer |
| `git status <(touch evil)` *(process substitution)* | defer |
| `git checkout file.txt` *(ambiguous: branch vs. file)* | defer |
| `git -c core.pager=cat log` *(inline-config escape hatch)* | defer |
| `gh pr create` *(gh mutation)* | defer |
| `ls -la` *(not a git/gh command)* | defer |

A few rows show the design's caution. `git status && rm -rf foo` **defers** rather
than allowing: auto-approval requires *every* segment to be a recognized-safe
git/gh invocation, so a trailing command can't ride along. The substitution rows
defer for the same reason a level down — `` `…` ``, `$(…)`, and `<(…)`/`>(…)` run
a command the classifier never sees (even inside a quoted argument or a redirect
target like `` git diff > `evil` ``), so a would-be `allow` is downgraded to defer.
`git checkout file.txt` **defers** because `checkout` is ambiguous — it could
switch branches or discard a file's changes — and the hook defers on ambiguity
rather than guess. Only the unambiguous branch-create form (`git checkout -b`)
auto-approves.

One narrow relaxation of the all-segments rule covers a constant AI-agent habit:
piping read-only git/gh output through a pager. A trailing segment also counts as
recognized-safe when it's a **pure read-only filter** — `head`, `tail`, `cat`,
`wc`, `nl`, `sort`, `uniq`, `cut`, `column`, `less`, `more` — so
`git log | head` and `gh pr checks 123 | head -20` auto-approve. A filter
qualifies only when *all* hold: (1) the program is in that allowlist; (2) it has
**no non-flag positional argument**, so it consumes stdin, not a file
(`git log | cat file.txt` defers — reading a file is workspace-guard's domain);
and (3) it carries no write option (`sort -o out` defers). The command must still
contain at least one git/gh segment, so `head -5` on its own keeps deferring, and
a protective `ask` (`git commit | head` on `main`) still wins. `sed` and `awk`
are deliberately excluded — both can write files (`sed -i`, `awk '… > f'`) or run
code.

The **ask** rows assume an interactive or `default`-mode session. In a
non-interactive mode (`auto`, `dontAsk`, `bypassPermissions`) the same commands
return **deny** — equally blocking, with recoverable feedback for the agent
instead of a prompt no one can answer. See [Configuration](#configuration).

The edit check resolves the branch of **the file's own repository**
(`git -C <dir-of-file>`), not the session's working directory — so it catches an
edit to a file checked out on `main` (e.g. a parent repo path) even while your
session's cwd is a feature-branch worktree.

## Push guard

`git push` is evaluated according to the `BRANCH_GUARD_PUSH_POLICY` environment
variable:

| Policy | Behavior |
| --- | --- |
| `strict` *(default)* | **allow** a push of the worktree's own current branch, including a force push of it. **ask** before any other push — a *different* branch (`git push origin other`), foreign refspecs (`git push origin HEAD:other`), wildcards, `--all`/`--mirror`, or a protected target. |
| `protected` | **ask** before a push whose target is `main`/`master` (including `git push origin main`, `HEAD:main`, deleting `main`, and `--all`/`--mirror`). Any other push defers. Never auto-approves. |
| `off` | Pushes are not guarded at all. |

A bare `git push` / `git push origin` pushes the current branch to its same-named
upstream: under `strict` it is auto-approved (it's the worktree branch); under
`protected` it defers.

The push guard is **best-effort**: it parses the Bash command Claude runs (so it
only governs Claude's `Bash` tool), and unusual refspecs may not be classified —
in which case it asks under `strict` / defers under `protected`, never silently
allowing. For a hard guarantee that no push reaches a protected branch —
regardless of how it's invoked or from which machine — pair it with a git
`pre-push` hook and/or server-side branch protection.

## Install

Install on any Claude Code surface that runs plugin `PreToolUse` hooks — the CLI,
the IDE extensions, or **Claude Code for Claude Desktop**.

**Claude Code (CLI or IDE extension)** — run the slash commands:

```
/plugin marketplace add karlkfi/claude-branch-guard
/plugin install branch-guard@claude-branch-guard
```

**Claude Code for Claude Desktop** — use the **Customize** tab:

1. Open the **Customize** tab and go to its plugins / marketplaces section.
2. Add `karlkfi/claude-branch-guard` as a marketplace (the repo at
   `https://github.com/karlkfi/claude-branch-guard.git`).
3. Find **branch-guard** in that marketplace, install it, and make sure it's
   enabled.

After installing with either method:

- Requires `python3` and `git` on your PATH.
- Restart Claude Code so the hook is registered.
- **Won't fire where plugin `PreToolUse` hooks don't run** (e.g. surfaces that
  don't yet run plugin hooks); there the guard never fires.

To verify, ask Claude to run `git commit -m test` on a checkout sitting on `main`
— you should see a permission prompt citing the protected branch. Then ask it to
commit on a `claude/*` or feature branch; it should run without prompting.

### Local install (development)

To run the plugin straight from a checkout instead of the GitHub marketplace,
add it as a `directory` marketplace in `~/.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "claude-branch-guard": {
      "source": { "source": "directory", "path": "~/workspace/claude-branch-guard" }
    }
  },
  "enabledPlugins": {
    "branch-guard@claude-branch-guard": true
  }
}
```

## Upgrade

branch-guard installs from a GitHub marketplace, which Claude Code tracks at the
repository's default branch (`main`). It does **not** auto-update by default, so a
newer release won't reach you until you refresh the marketplace and reinstall.

**Claude Code (CLI or IDE extension)** — run the slash commands:

```
/plugin marketplace update claude-branch-guard
/plugin uninstall branch-guard@claude-branch-guard
/plugin install branch-guard@claude-branch-guard
```

The first command re-fetches the marketplace manifest from the repo; the
reinstall picks up the new version. After upgrading, run `/reload-plugins` to
activate the updated hook without restarting, or restart Claude Code.

**Claude Code for Claude Desktop** — in the **Customize** tab's plugins /
marketplaces section, refresh the `claude-branch-guard` marketplace, then
reinstall **branch-guard** from it.

## How it works

1. **Tokenize** the command with Python's `shlex` (POSIX mode, punctuation
   grouping) so quotes are respected and shell operators (`|`, `&&`, `>`, `;`,
   newlines) become their own tokens.
2. **Split** into simple-command segments on those operators and drop redirect
   targets aside.
3. **Parse** each segment with `parse_invocation`: strip leading
   `NAME=VALUE` env prefixes (`GIT_AUTHOR_NAME=x git …`) and program global
   options (`git -C path`, `-c k=v`) to find the `git`/`gh` subcommand and its
   arguments. Combined short flags (`git clean -fd`) are decomposed.
4. **Classify** each segment as `allow` / `ask` / `defer` / non-git:
   read-only git and gh and harmless mutations (`add`, `restore --staged`,
   `switch -c`, `worktree add`, branch/tag create) allow on any branch;
   branch-sensitive mutations (`commit`, `merge`, `rebase`, `cherry-pick`,
   `stash`, `push`) allow on a feature branch and ask on a protected one;
   destructive commands (`reset --hard`, `clean -f`, `branch -D`, …) ask;
   unknown or ambiguous forms defer. The branch is resolved with
   `git symbolic-ref` (the session cwd for Bash, the file's own repo for edits).
5. **Combine** the segment verdicts: any `ask` → ask; else every segment must be
   recognized-safe → allow; else defer. A segment is recognized-safe when it's a
   git/gh `allow` or a **pure read-only filter** piped after one — `head`,
   `tail`, `cat`, `wc`, `nl`, `sort`, `uniq`, `cut`, `column`, `less`, `more`
   with no file positional and no write option (`git log | head -20`). At least
   one git/gh segment is still required (`head -5` alone defers). Two things
   downgrade a would-be `allow` to defer
   without ever weakening a protective `ask`: an inline-config escape hatch
   (`git -c core.pager='!sh …' log`), and a hidden command/process substitution
   in the raw token stream (`` `…` ``, `$(…)`, `<(…)`/`>(…)`, or an unrecognized
   operator run like `|&`) — checked over the raw tokens, before redirect targets
   are dropped, so `` git diff > `evil` `` is caught too.
6. **Fail safe** in non-interactive modes: a would-be `ask` is emitted as `deny`,
   since no human is present to answer the prompt.

## Agent guidance: avoiding prompts

Most branch-guard prompts are intentional — they fire when Claude touches a
protected branch or runs something destructive. But a few habits keep work
flowing. Paste the block below into your project's `CLAUDE.md` (or `AGENTS.md`):

```markdown
## Avoiding branch-guard permission prompts

This repo uses branch-guard, a hook that prompts before git/edit operations on a
protected branch (main/master) or destructive git commands. To keep work flowing:

- **Work on a feature branch, not main/master.** Commit, push, merge, and rebase
  all run without a prompt on a `claude/*` or feature branch; the same on
  main/master prompts. Use `git switch -c claude/<topic>` (or a worktree) before
  editing or committing.
- **Push the worktree's own branch.** `git push` / `git push -u origin HEAD`
  auto-approves; pushing a different branch or a refspec like `HEAD:main` prompts.
- **Prefer fast-forward pulls.** `git pull --ff-only` is auto-approved; a bare
  `git pull` (which may merge or rebase) prompts.
- **Run git commands on their own, not chained with non-git commands.**
  `git commit && <other>` won't auto-approve — the trailing command can't ride
  along. Run them as separate commands. (One exception: piping read-only output
  through a pager — `git log | head`, `gh pr checks 123 | head -20` — stays
  auto-approved.)
- **Expect a prompt for destructive commands** (`reset --hard`, `clean -f`,
  `branch -D`, `restore <path>`, `config --global`) — that's by design.
```

## Configuration

- **Push policy** — set `BRANCH_GUARD_PUSH_POLICY` to `strict` (default),
  `protected`, or `off` (see [Push guard](#push-guard)). Set it in
  `~/.claude/settings.json` (all projects) or a project's
  `.claude/settings.json`:

  ```json
  { "env": { "BRANCH_GUARD_PUSH_POLICY": "protected" } }
  ```

- **Protected branches** — the default set is `main` and `master`, defined by
  `PROTECTED_BRANCH_RE` at the top of `hooks/branch-guard.py`. Edit the regex to
  protect additional branches (e.g. `release/*`).

- **Non-interactive modes** — in `auto`, `dontAsk`, and `bypassPermissions` an
  `ask` is automatically emitted as `deny` so the guard fails safe when no human
  is present. (Claude Code ignores hook decisions entirely under
  `bypassPermissions`, so a hard guarantee there still needs a git `pre-push`
  hook or server-side branch protection.)

## Limitations

- The guard only governs Claude's `Bash`/`Edit`/`Write`/`MultiEdit`/`NotebookEdit`
  tools. It does **not** intercept file mutations done through other Bash
  commands — e.g. `sed -i`, `>` redirects, or `rm` — on a protected branch.
  [workspace-guard](#companion-plugin), a companion plugin, guards those Bash
  file commands on a path boundary.
- It auto-approves a *safe* set of `git`/`gh` subcommands and asks on a
  *destructive* set; anything outside both (an unknown subcommand, a `git config`
  form it can't classify, most `gh` mutations) **defers** to the normal
  permission flow rather than guessing.
- Auto-approval is only ever withheld, never granted, by the shell-construct
  check: a command carrying a command/process substitution (`` `…` ``, `$(…)`,
  `<(…)`/`>(…)`) or an unrecognized operator run **defers** instead of
  auto-approving, since those run code the classifier can't see. It is a
  best-effort lexical check, not a sandbox — the filesystem boundary is
  workspace-guard's job, and a hard guarantee belongs in a git `pre-push` hook
  or server-side branch protection.
- The push guard parses the command string, so unusual refspecs may not be
  classified (it asks/defers rather than allowing). Auto-approval is a
  convenience layer, not a security boundary — for hard guarantees use a git
  `pre-push` hook and/or server-side branch protection.

## Companion plugin

branch-guard reasons about **git/branch semantics** — which branch you're on and
whether a `git`/`gh` command is destructive. It deliberately leaves the
**filesystem boundary** to a sibling hook:
[**workspace-guard**](https://github.com/karlkfi/claude-workspace-guard),
path-aware bash permissions that prompt when a command reads or writes a file
outside your project root (`$CLAUDE_PROJECT_DIR`). The two are complementary and
don't overlap:

| Plugin | Guards | Boundary |
| --- | --- | --- |
| **branch-guard** | `git`/`gh` commands and `Edit`/`Write`/`MultiEdit`/`NotebookEdit` | the **branch** (`main`/`master` vs. a feature branch) |
| **workspace-guard** | file readers/writers like `grep`, `sed`, `cat`, `rm`, `cp`, `mv`, `tee`, `dd` | the **path** (inside vs. outside the project root) |

This closes part of branch-guard's first [limitation](#limitations): the raw
Bash file mutations branch-guard never sees (`sed -i`, `>` redirects, `rm`) are
exactly what workspace-guard catches — when they touch a path outside your
workspace. Run both for coverage across both dimensions. (Neither catches an
in-repo `sed -i` on a protected branch; for a hard guarantee there, use a git
`pre-commit`/`pre-push` hook or server-side branch protection.)

Install it the same way as branch-guard:

```
/plugin marketplace add karlkfi/claude-workspace-guard
/plugin install workspace-guard@workspace-guard
```

## Privacy

The hook runs entirely on your machine and has no network access, telemetry, or
analytics. It reads the pending Bash/edit command and resolves the current branch
with `git symbolic-ref`, decides in memory, and never opens file contents or writes
anything to disk.

## Contributing

Bugs, ideas, and questions go in
[GitHub Issues](https://github.com/karlkfi/claude-branch-guard/issues).

Run the test suite (spins up a throwaway git repo under `tmp/` and asserts the
decision for each command/branch combination):

```bash
./test/run.sh
```

It needs `python3` and `git`, plus `jq` to read the hook's JSON output.

## License

MIT — see [LICENSE](LICENSE).
