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
touches a protected branch (`main`/`master`, plus any you add) or is destructive.
Everything else defers to your normal permission settings.

## Contents

- [What it does](#what-it-does)
- [Behavior](#behavior)
- [Break-glass: `BRANCH_GUARD_OVERRIDE`](#break-glass-branch_guard_override)
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
  reject. In a mode with no prompt to show, this becomes **deny** (see
  [Configuration](#configuration)).
- **defer** — the hook stays silent; your normal permission settings apply.

It guards the `Bash` tool (for `git` and `gh` commands) and the `Edit`, `Write`,
`MultiEdit`, and `NotebookEdit` tools (for the branch a file's repository is on).

## Behavior

For a Bash command, every segment is classified and the command-level decision
is: **any segment needs `ask` → ask; else every segment is recognized-safe →
allow; else defer.** A segment counts as recognized-safe if it's a safe git/gh
invocation, a pure read-only filter (a pager like `head`/`tail`/`wc`) piped after
one, *or* a side-effect-free label/no-op (`echo`/`printf`/`true`) — so
`git log | head` and `git log … ; echo "---" ; git log …` auto-approve, but a
non-git, non-filter, non-benign command can never ride along into an approval. A
segment that writes a file via an output redirect (`git log > f`, `echo x > f`;
`/dev/null` and the standard streams don't count) is downgraded out of `allow`.

The table below assumes the worktree is on a feature branch (`claude/x`) under
the default `strict` [push policy](#push-guard).

| Command | Decision |
| --- | --- |
| `git status` / `git diff` / `git log` | allow |
| `git add -A` | allow |
| `git switch -c claude/y` / `git checkout -b claude/y` | allow |
| `git worktree add ../wt feature` | allow |
| `git worktree remove ../wt` *(git refuses one holding modified or untracked files)* | allow |
| `git commit -m "fix"` *(feature branch)* | allow |
| `git add -A && git commit -m x && git push` *(feature branch)* | allow |
| `git push` / `git push -u origin HEAD` *(worktree branch)* | allow |
| `git push --force` *(worktree branch)* | allow |
| `git push --force-with-lease=other origin HEAD:other` *(rewrites an unprotected branch, lease names the destination)* | allow |
| `git push` *(worktree branch; the base moved, but not into the lines this branch edits)* | allow |
| `git push --dry-run` / `git push --delete origin claude/x` *(nothing lands on the base, so no overlap to have)* | allow |
| `git push` *(on `release/1.2` — a release branch is diverged from the base on purpose)* | allow |
| `gh pr view 123` / `gh pr list` / `gh repo view` / `gh run watch` / `gh search prs` | allow |
| `gh api repos/o/r` / `gh api -X GET …` *(a read — default or explicit GET)* | allow |
| `git log \| head` / `gh pr checks 123 \| head -20` / `git diff --stat \| tail -n 5` *(piped to a read-only filter)* | allow |
| `git log --oneline ; echo "---" ; git status` *(label/no-op between git reads)* | allow |
| `gh pr view "$(git branch --show-current)"` / `git -C "$(git rev-parse --show-toplevel)" status` / `git log "$(pwd)"` *(pure read-only substitution)* | allow |
| `git commit -F- <<'EOF' … EOF` *(feature branch; heredoc body is opaque data)* | allow |
| `git fetch 2>/dev/null` / `git log >/dev/null 2>&1` *(discard redirect / fd-dup)* | allow |
| `git pull --ff-only` | allow |
| `git pull` / `git pull --rebase` *(feature branch — as `fetch`, `merge`, and `rebase` already are)* | allow |
| `git branch -d old` / `git branch -m old new` / `git branch -c old copy` *(unprotected target; git refuses the unsafe cases itself)* | allow |
| `git branch -D old` *(tip survives on a remote-tracking branch or `main`)* | allow |
| `git branch -D tmp-basecheck` *(scratch ref whose only unshared commit is a merge git reproduces)* | allow |
| `git branch -f backup claude/x` *(the ref doesn't exist yet — a create)* | allow |
| `git reset --hard origin/main` *(clean worktree, feature branch whose tip survives elsewhere)* | allow |
| `git stash` / `git stash pop` *(any branch — adds no commit, rewrites no history, recoverable by design)* | allow |
| `git commit -m "fix"` *(on `main`)* | **ask** |
| editing a file whose repo is on `main` *(Edit/Write/MultiEdit/NotebookEdit)* | **ask** |
| editing a symlink in a gitignored dir that points at a tracked file, on `main` *(the write lands on branch contents)* | **ask** |
| writing a new file into a directory that doesn't exist yet, on `main` *(`src/newdir/f.py`)* | **ask** |
| `git push origin main` / `git push origin HEAD:main` | **ask** |
| `git push origin other-branch` *(strict policy — no lease naming the destination)* | **ask** |
| `git push --force-with-lease=main origin HEAD:main` / `git push --delete --force-with-lease=other origin other` *(protected target; a deletion)* | **ask** |
| `git push origin v1.3.0` / `git push origin refs/tags/v1.3.0` / `git push --tags` *(publishes a tag, strict policy)* | **ask** |
| `git push` *(worktree branch, but the base has moved into the same lines this branch edits)* | **ask** |
| `git reset --hard HEAD~1` *(uncommitted changes to tracked files, or a tip nothing else reaches, or on `main`)* | **ask** |
| `git clean -fd` | **ask** |
| `git stash drop` / `git stash clear` *(discards a stash)* | **ask** |
| `git branch -D old` *(tip reachable from nothing else, and the branch carries commits of its own)* | **ask** |
| `git branch -D tmp-conflict` *(its merge was resolved by hand, so that tree exists nowhere else)* | **ask** |
| `git branch -d main` / `git branch -D main` / `git branch -m x main` *(protected branch, any spelling)* | **ask** |
| `git branch -f old main` / `git branch -M x old` *(moves an existing branch off commits nothing else reaches)* | **ask** |
| `gh pr close 5 --delete-branch` / `gh pr close 5 -d` *(deletes a branch whose work was never merged)* | **ask** |
| `gh repo delete owner/repo` / `gh label delete bug` *(deletes a resource)* | **ask** |
| `gh release delete v1` / `gh release delete-asset v1 file.zip` / `gh secret delete X` / `gh variable delete Y` / `gh gist delete abc` / `gh cache delete 1` *(deletes a resource; `secret`/`variable` also via the `remove` alias)* | **ask** |
| `gh workflow disable ci.yml` *(disables a workflow)* | **ask** |
| `gh api -X DELETE …/git/refs/heads/feature-x` *(deletes a branch/tag ref)* | **ask** |
| `gh api -X DELETE …/labels/bug` *(deletes a label)* | **ask** |
| `gh api -X DELETE repos/o/r` *(deletes a repository — exact `repos/{o}/{r}` path)* | **ask** |
| `git restore file.txt` *(discards working changes)* | **ask** |
| `git worktree remove --force ../wt` *(deletes a worktree holding modified or untracked files)* | **ask** |
| `git config --global user.name x` | **ask** |
| `BRANCH_GUARD_OVERRIDE=<reason> git restore file.txt` *(break-glass on a local-loss ask — see below)* | allow |
| `BRANCH_GUARD_OVERRIDE=<reason> git push origin other` / `… gh repo delete o/r` / `… git branch -D main` *(the break-glass reaches none of these)* | **ask** |
| `git pull` / `git pull --rebase` *(on `main` — lands a merge, or rewrites history)* | **ask** |
| `git rebase`/`git merge` *(onto `main`)* | **ask** |
| editing a **gitignored** path on `main` *(`tmp/scratch.json` — nothing the branch can contain)* | defer |
| `git status && rm -rf foo` *(non-git segment)* | defer |
| `git log --format=… > out.txt` *(redirects git output to a real file)* | defer |
| `git status ; echo x > out.txt` *(benign segment writes a file)* | defer |
| `git log \| cat file.txt` *(filter reads a file)* / `git status \| tee out` *(filter writes)* | defer |
| `head -5` / `echo hi` *(no git/gh segment)* | defer |
| `` git status `touch evil` `` / `git commit -m "$(touch evil)"` *(hidden command substitution, not in the pure registry)* | defer |
| `git status <(touch evil)` *(process substitution)* | defer |
| `git checkout file.txt` *(ambiguous: branch vs. file)* | defer |
| `git -c core.pager=cat log` *(inline-config escape hatch)* | defer |
| `gh pr create` / `gh pr merge 5` / `gh pr merge 5 --delete-branch` / `gh run rerun` *(gh mutation; the merge lands the work before the branch is deleted)* | defer |
| `gh api -X POST …` / `gh api … -f k=v` *(a write: non-GET method or a request body)* | defer |
| `gh api -X DELETE user/following/x` / `gh api -X DELETE repos/o/r/issues/comments/1` *(non-repo API delete — not a recognized destructive endpoint)* | defer |
| `ls -la` *(not a git/gh command)* | defer |

A few rows show the design's caution. `git status && rm -rf foo` **defers** rather
than allowing: auto-approval requires *every* segment to be a recognized-safe
git/gh invocation, so a trailing command can't ride along. The substitution rows
defer for the same reason a level down — `` `…` ``, `$(…)`, and `<(…)`/`>(…)` run
a command the classifier never sees (even inside a quoted argument or a redirect
target like `` git diff > `evil` ``), so a would-be `allow` is downgraded to defer.
(A tiny registry of provably pure substitutions is the one exception — see below.)
An output redirect to a real file (`git log > out`, `echo x > out`) is treated the
same way — it's a write side-effect the classifier can't otherwise see, so the
segment is downgraded out of `allow`. This both hardens the read commands (a
redirected `git log --format=…` can't silently write attacker-influenced content)
and keeps a ride-along filter/label from sneaking a write through. Redirects to
`/dev/null` or the standard streams, and fd-duplications like `2>&1`, write no
file and keep allowing (`git fetch 2>/dev/null` stays auto-approved).
`git checkout file.txt` **defers** because `checkout` is ambiguous — it could
switch branches or discard a file's changes — and the hook defers on ambiguity
rather than guess. Only the unambiguous branch-create form (`git checkout -b`)
auto-approves.

### `git branch`: what the session owns, not how the verb looks

`git branch` is the one subcommand judged by its **target** rather than by its
verb. Deleting a scratch ref you created ten minutes ago and deleting a branch
nobody else can recover are the same command, and gating both prompts constantly
for the first while adding nothing to the second. So a target is auto-approved
when it is both:

- **recoverable** — its tip is reachable from a remote-tracking branch or from
  local `main`/`master`, so the commits survive the branch and the worst case is
  `git reset --hard <sha>`; and
- **private** — not in the protected set. A protected branch is shared, so it
  always asks.

These are independent questions, and the protected one is asked first for every
spelling. The non-force spellings need no *recoverability* check, because git
already enforces that one itself: `git branch -d` refuses to delete unmerged
work, and `git branch -m` and `-c` refuse to overwrite an existing destination.
Only the force spellings — `-D`, `-M`, `-C`, `-f`, and `-d --force` — can lose
commits, so only those are checked for recoverability. But git has no notion of
which branches you consider shared, so `git branch -d main` prompts exactly like
`git branch -D main`, as does any branch matching
[`BRANCH_GUARD_PROTECTED_BRANCHES`](#configuration). `git branch -f backup claude/x` creating a new ref
loses nothing and auto-approves; the same command pointed at a ref that already
exists is judged on what that ref currently points at.

A force-delete has one more way to be in bounds, because "the tip survives" and
"nothing is lost" turn out not to be the same question. Consider a scratch
branch that merged an integration ref to see what would happen:

```bash
git switch -c tmp-basecheck
git merge origin/main       # does the gate still pass over the merged tree?
git switch -
git branch -D tmp-basecheck
```

Its tip is unreachable *because* it merged — the merge commit is new, so no
remote-tracking ref can contain it — while what the delete orphans is that one
commit, both of whose parents stay exactly where they were. So the hook re-runs
the merge: `git merge-tree` recomputes a tree from the two parents, and if it
matches the tree the commit records, the commit holds nothing a plain
`git merge` wouldn't produce again. A merge whose conflicts you settled by hand
does **not** reproduce — that tree is authored work living nowhere else — so it
keeps prompting, as does a branch carrying any ordinary commit of its own, an
octopus merge, or a git too old for `merge-tree --write-tree` (2.38, 2022).
Only `-D` and `--delete --force` get this; the force move/copy forms still ask
on an unreachable tip.

The checks are local `git` queries and never touch the network. They can
only ever turn a prompt into an approval, and only on a positive answer — if git
can't be reached, the branch won't resolve, or a `git -C`/`--git-dir` option
points the command at a different repository than the one the queries read, the
command asks exactly as it did before.

One caveat worth knowing: "reachable from a remote-tracking branch" trusts your
last `git fetch`. A stale `refs/remotes/origin/x` left behind after the branch
was deleted on the remote still reads as recoverable. Like the rest of the hook
this is best-effort friction reduction, not a guarantee — see
[Limitations](#limitations).

`git reset --hard` gets the same test, but only when it has nothing else to
destroy. The command does two things: it moves the current branch pointer, and
it throws away uncommitted changes to tracked files. Uncommitted work exists in
no ref, so nothing can show it's recoverable — which is why a **dirty worktree
always prompts**. With a clean worktree the command is just the pointer move,
and the ordinary test applies: an unprotected branch whose tip survives
elsewhere auto-approves, because putting it back costs one
`git reset --hard <sha>`.

Untracked and ignored files don't count as dirty, because `reset` never deletes
them. A stray scratch file in your worktree isn't at risk, so it doesn't earn a
prompt.

The other destructive commands stay gated by what they are, not what they
target, because there's nothing for this test to check. `git clean -f` deletes
untracked files, which exist in no ref by definition, and a dropped stash
survives only in the reflog. Those prompts aren't friction to be tuned away —
they're the cases where the work really can vanish.

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

A second narrow relaxation covers the other constant habit: labelling output
between commands. A segment also counts as recognized-safe when it's a
**side-effect-free no-op** — `echo`, `printf`, `true`, `false`, `:` — so a label
line in an all-git chain (`git log … ; echo "---" ; git status`) auto-approves
instead of dropping the whole command to defer. These write only to stdout (or
just set an exit status), so the two ways they could do harm are both already
closed: an output redirect to a real file (`echo evil > ~/.gitconfig`) downgrades
the segment via the write check above, and a command substitution (`echo $(…)`)
downgrades the whole command. As with filters, the command must still contain a
git/gh segment (`echo hi` alone defers) and a protective `ask` still wins.

A third relaxation covers a constant idiom: passing a repo path or branch name to
a git/gh command via substitution. A `$(…)` or backtick substitution normally
downgrades the whole command to defer, but a tiny hardcoded registry of **pure
read-only substitutions** — `$(git rev-parse --show-toplevel)`,
`$(git branch --show-current)`, and `$(pwd)` — is exempt, so
`gh pr view "$(git branch --show-current)"` and
`git -C "$(git rev-parse --show-toplevel)" status` auto-approve instead of
prompting. The match is **structural**: the command inside the substitution must
tokenize to exactly a registry entry with no extra argument, separator, redirect,
or nested substitution — so `$(git branch --show-current; rm -rf x)`,
`$(git rev-parse --show-toplevel > f)`, and `$(git status)` all keep deferring.
Because the classifier reasons about the literal tokens and never resolves a
substitution's output, this can only lift the defer on an already-safe git/gh
chain — it never turns a destructive verdict or a protected-branch `ask` into an
`allow` (`git commit -m "$(pwd)"` on `main` still asks). A non-git segment still
can't ride along, so `cd "$(git rev-parse --show-toplevel)" && git status` keeps
deferring (the `cd` is workspace-guard's domain).

Heredoc bodies are treated as **opaque data**, not command segments. A body
(`git commit -F- <<'EOF' … EOF`, `gh pr create --body-file - <<'EOF' … EOF`) is
dropped before the command is lexed, so its lines can't split into foreign
segments and drop the surrounding git chain to a prompt (or unbalance the lexer
with an apostrophe). The operator line and anything after the terminator still
classify normally, so a `git push origin main` after the heredoc still asks. One
security nuance: the shell expands an **unquoted** heredoc body, so a command
substitution in it runs (`<<EOF … $(rm -rf /) … EOF`). Such a body is *not*
dropped — it's left in the stream so the substitution guard defers. A **quoted**
delimiter (`<<'EOF'`, `<<"EOF"`, `<<\EOF`) suppresses all expansion, so its body
is inert and always safe to drop. An unterminated or unparseable heredoc is left
unchanged (the body lexes and the command defers) rather than guessed at.

The **ask** rows assume a session where a prompt can be answered, which
includes `auto`. In a mode where none can (`dontAsk`, `bypassPermissions`) the
same commands return **deny** — equally blocking, with recoverable feedback for
the agent instead of a prompt no one can answer. See
[Configuration](#configuration).

The two paths share the cause and differ in what they offer, so a denial is never
mistaken for a prompt that is waiting to be answered:

```
ask   Push targets 'v1.3.0', not the worktree branch 'claude/x'
      — confirm before proceeding.

deny  Push targets 'v1.3.0', not the worktree branch 'claude/x'
      — branch-guard denied it: permission mode 'dontAsk' has no way to prompt
      for confirmation. Retrying won't help — either do it outside this session
      (e.g. run the command in a terminal), or re-run in an interactive
      permission mode.
```

The edit check resolves the branch of **the file's own repository**
(`git -C <dir-of-file>`), not the session's working directory — so it catches an
edit to a file checked out on `main` (e.g. a parent repo path) even while your
session's cwd is a feature-branch worktree. A **relative** `file_path` is first
resolved against the session's `cwd` (from the hook payload), so an edit inside a
nested worktree resolves to the worktree's branch even when the hook process runs
from the parent checkout — not falsely against the parent's `main`. When the
file's directory doesn't exist yet (a write into a new directory), the branch is
read from the nearest existing ancestor, which sits in the same repository; a
path under no repository still resolves to no branch and defers.

A **gitignored** path is exempt: writing `tmp/scratch.json` on `main` gets no
prompt, because an ignored file holds no branch contents and the decision would
be identical on a feature branch. The check is `git check-ignore`, run only when
the branch is protected — so a feature-branch edit costs nothing extra — and only
its "yes, ignored" answer withdraws the prompt. Every other answer, including
every answer it can't give (the path is outside the worktree, the repo won't
open, git isn't available), leaves the **ask** in place. A file that matches an
ignore rule but is *tracked* anyway (`git add -f`) still asks: `check-ignore`
consults the index, and edits to that file really do land on the branch. The
probe follows symlinks and asks about the file the write lands on, so a link
inside an ignored directory pointing at a tracked file still asks — a link to a
genuinely ignored file stays exempt.

## Break-glass: `BRANCH_GUARD_OVERRIDE`

In `dontAsk` and `bypassPermissions` an **ask** becomes a **deny**, and a deny
has no answer. That is right for a shared branch and wrong for a scratch one: the
session still has work to do, so it does the work some other way. A session that
couldn't run `git restore file.txt` edited the file back to its `HEAD` content by
hand instead — same end state, no atomicity, no guarantee the result matched
`HEAD`, and nothing in the log to review. Where no ungated equivalent exists (you
cannot delete a branch by editing a file), the state is simply stranded.

That session was in `auto`, which prompts now — so that example no longer plays
out there. The prefix is for the modes that still cannot prompt.

So one command prefix lifts an ask whose damage cannot leave this machine:

```bash
BRANCH_GUARD_OVERRIDE="reverting a superseded local change" git restore file.txt
```

The reason is **required** — a bare `BRANCH_GUARD_OVERRIDE=` lifts nothing — and
it is echoed into the emitted decision, so the approval is on the record rather
than silent. It is a command prefix rather than a `settings.json` variable because
a `PreToolUse` hook inherits Claude Code's environment, not the one the command is
about to run in; an env-var override could only be switched on for a whole
session, by hand, which is the opposite of scoping it to the moment.

**What it reaches.** Only these subcommands, each of which can lose local state
and nothing else: `restore`, `switch`, `branch`, `tag`, `worktree`, `stash`,
`reset`, `clean`, `config`, `reflog`, `filter-branch`, `gc`.

**What it does not reach**, whatever reason you give:

- **A protected branch.** `git reset --hard` on `main`, `git branch -D main`, a
  commit or edit on `main` — the cause of the ask is a shared ref, and that class
  of verdict is unliftable by construction, not by a list the override consults.
  This includes anything you add to
  [`BRANCH_GUARD_PROTECTED_BRANCHES`](#configuration).
- **Anything that leaves this machine.** Every `git push` form and every `gh`
  delete/disable. A push publishes; `gh repo delete` removes something other
  people can see.
- **A command that reaches further than the subcommand it was granted for.** An
  output redirect to a file (`… > out`), a `git -c`/`--config-env` escape hatch
  (which can run arbitrary code), and a `git -C`/`--git-dir` aimed at another
  repository all keep the ask.
- **A command carrying anything unrecognized.** The all-segments rule applies
  unchanged, so `BRANCH_GUARD_OVERRIDE=… git clean -fd && rm -rf junk` still asks.
  A safe segment alongside is fine: `… git status && git clean -fd` is lifted.

A denial that the prefix *would* lift says so, so an agent can find the route
without being told about it in advance. A denial it would not lift doesn't
mention it, because a hint that fails a second time is the dead end the wording
exists to avoid. The interactive prompt never mentions it either — approving the
prompt is the shorter path.

## Push guard

`git push` is evaluated according to the `BRANCH_GUARD_PUSH_POLICY` environment
variable:

| Policy | Behavior |
| --- | --- |
| `strict` *(default)* | **allow** a push of the worktree's own current branch, including a force push of it, and a *leased rewrite* of one other unprotected branch from it (see below). **ask** before any other push — a *different* branch (`git push origin other`), foreign refspecs (`git push origin HEAD:other`), wildcards, `--all`/`--mirror`, a tag (`git push origin v1.3.0`, `refs/tags/v1.3.0`, `--tags`), or a protected target. |
| `protected` | **ask** before a push whose target is `main`/`master` (including `git push origin main`, `HEAD:main`, deleting `main`, and `--all`/`--mirror`). Any other push defers. Never auto-approves. |
| `off` | Pushes are not guarded at all. |

A bare `git push` / `git push origin` pushes the current branch to its same-named
upstream: under `strict` it is auto-approved (it's the worktree branch); under
`protected` it defers.

Wherever these rows say `main`/`master`, they mean the protected set — which you
can widen with [`BRANCH_GUARD_PROTECTED_BRANCHES`](#configuration), so
`git push origin release/2.0` asks under `protected` once `release/*` is in it.

**Tags.** Publishing a tag isn't a push of the worktree branch, so under `strict`
it asks — whichever way it's spelled (`git push origin v1.3.0`,
`git push origin refs/tags/v1.3.0`, `git push --tags`). Cutting a release is
usually the one step worth a human keystroke, and `auto` gives you one rather
than a dead end (see [Configuration](#configuration)); creating the tag was
never gated at all. One gap is deliberate:
`git push --follow-tags` stays auto-approved, since it publishes only annotated
tags already reachable from the branch being pushed, and `push.followTags` can
turn on the same behavior from config where the hook can't see it. Under
`protected`, tag pushes defer as before — that policy only guards `main`/`master`.

**Leased rewrites of another branch.** Undoing a bad rebase means rewriting one
branch from another: fix it up on a scratch branch, then push that over the
original. The destination is never the worktree branch, so under `strict` every
spelling of it asked — and in a non-interactive mode an `ask` is a denial, so the
branch could not be repaired at all.

`--force-with-lease=<dst>` opens that path. git refuses the push unless the
remote is still at the commit the command named, so it cannot land on top of work
the session hasn't seen — the same reason the non-force `git branch` spellings
need no check of their own. Under `strict`:

```bash
git push --force-with-lease=claude/topic origin HEAD:claude/topic
```

is auto-approved when the lease **names the destination**, the source is the
worktree branch, and the destination isn't protected. Everything else still asks:
a bare `--force-with-lease` (it names no ref), a lease naming some other branch,
a deletion (`--delete`, or an empty source as in `origin :other`), a foreign
source branch, and `--no-force-with-lease` cancelling an earlier lease. Under
`protected` nothing changes — that policy never auto-approves a push.

What a lease proves is that the remote hasn't moved, not that the branch is
yours alone. Sharedness stays branch-guard's own question, answered by the
protected set: `git push --force-with-lease=main origin HEAD:main` asks like any
other push at `main`, and widening
[`BRANCH_GUARD_PROTECTED_BRANCHES`](#configuration) withdraws the auto-approve
for whatever you add.

**Overlap with a moved base.** An auto-approved push is in bounds. That says
nothing about the branch still being built on what it thinks it is. When the base
has moved into the same *lines* this branch edits, the merge is going to come out
wrong — and under a merge queue it comes out wrong late, after the queue has
validated the candidate and spent a whole check cycle on it. So the auto-approve
is withdrawn and the push asks, naming the files and the fix:

```
'origin/main' has moved since this branch left it, and its new commits edit the
same lines this branch does in hooks/branch-guard.py — the merge is going to come
out wrong, and a merge queue would spend a whole check cycle finding that.
`git fetch && git rebase origin/main` finds it now — confirm before proceeding.
```

Both sides are diffed from the fork point, so both sets of line numbers are
counted in that shared ancestor and can be compared at all. Hunks are read with
`-U0` and widened by the three lines of context a hunk carries, so edits within
six lines of each other meet and edits seven apart do not — sharing a *file* is
not sharing an edit.

The check runs only where a push would otherwise be auto-approved, so `protected`
and `off` never reach it. Every probe fails silent: a detached HEAD, a shallow
clone, an unresolvable base ref, a git too old for `merge-tree --write-tree`, or
no `origin` at all costs a missed catch rather than a blocked push. `--dry-run`
and `--delete` land nothing on the base, so neither is checked.

Release branches are skipped by name — `release/*`, `hotfix-*`, `v2.1` and the
rest of `BRANCH_GUARD_RELEASE_BRANCHES`. One is cut from the base and left
diverged on purpose, so telling it to rebase would publish everything merged
since the tag: a wrong answer rather than a noisy one. Nothing in the commit graph
tells a release branch from a stale topic branch — both sit behind the base and
ahead of the fork point — so the name is the only signal there is.

Three settings tune it, all under [Configuration](#configuration):
`BRANCH_GUARD_BASE_REF` (unset derives it from the clone's own `origin/HEAD`, so a
`master`-default repo needs no config), `BRANCH_GUARD_OVERLAP_IGNORE` for paths a
merge driver owns, and `BRANCH_GUARD_PUSH_OVERLAP_ENABLED=false` to switch the
check off.

This check came from [pipe-guard](https://github.com/karlkfi/claude-pipe-guard),
which shipped it first. branch-guard parses `push` to destination-ref depth, so it
lives here; pipe-guard keeps the matching `gh pr create` check.

The push guard is **best-effort**: it parses the Bash command Claude runs (so it
only governs Claude's `Bash` tool), and unusual refspecs may not be classified —
in which case it asks under `strict` / defers under `protected`, never silently
allowing. For a hard guarantee that no push reaches a protected branch —
regardless of how it's invoked or from which machine — pair it with a git
`pre-push` hook and/or server-side branch protection.

**Auto-allowed pushes and session wake-ups.** Under `strict`, a push of the
worktree branch runs without a prompt. If a session can be woken by
third-party-writable input — e.g. Claude Desktop's **Autofix pull requests**
setting, which resumes a session on PR review comments, a public-repo injection
channel — that same auto-allowed push is the permission an injected wake-up would
use to push commits unattended. This is bounded: the push lands on an unmerged
topic branch and is reversible, so the effective security boundary shifts to
**PR-merge review**. With autofix enabled, keep auto-merge off and treat human
merge review as the control this auto-allow leans on.

## Install

Install on any Claude Code surface that runs plugin `PreToolUse` hooks — the CLI,
the IDE extensions, or **Claude Code for Claude Desktop**.

**Claude Code (CLI or IDE extension)** — run the slash commands:

```
/plugin marketplace add karlkfi/claude-branch-guard
/plugin install branch-guard@branch-guard
```

**Claude Code for Claude Desktop** — use the **Customize** tab:

1. Open the **Customize** tab and go to its plugins / marketplaces section.
2. Add `karlkfi/claude-branch-guard` as a marketplace (the repo at
   `https://github.com/karlkfi/claude-branch-guard.git`).
3. Find **branch-guard** in that marketplace, install it, and make sure it's
   enabled.

After installing with either method:

- Requires Python 3 and `git` on your PATH. The hook is launched through
  `hooks/run-python-hook.cmd`, which resolves an interpreter by trying `py -3`,
  `python`, then `python3` (on Windows) or `python3`, then `python` (elsewhere),
  so a working Python under any of those names is enough. If none of them runs,
  the guard reports the problem on stderr rather than failing silently.
- Restart Claude Code so the hook is registered.
- **Won't fire where plugin `PreToolUse` hooks don't run** (e.g. surfaces that
  don't yet run plugin hooks); there the guard never fires.

To verify, ask Claude to run `git commit -m test` on a checkout sitting on `main`
— you should see a permission prompt citing the protected branch. Then ask it to
commit on a `claude/*` or feature branch; it should run without prompting.

**Keep it up to date — turn on auto-update (recommended).** Claude Code
auto-updates official Anthropic marketplaces only; third-party ones like this
never refresh on their own, so an install pins its version until you act. Install
time is the moment to decide — add the marketplace with `autoUpdate` on in
`~/.claude/settings.json` and new releases install themselves at startup:

```json
{
  "extraKnownMarketplaces": {
    "branch-guard": {
      "source": { "source": "git", "url": "https://github.com/karlkfi/claude-branch-guard.git" },
      "autoUpdate": true
    }
  }
}
```

Prefer to update by hand? Leave it off and pull new versions manually — see
[Upgrade](#upgrade).

**Already installed?** New releases don't install themselves — see
[Upgrade](#upgrade) to enable auto-update or pull the latest version.

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
repository's default branch (`main`). Claude Code auto-updates official Anthropic
marketplaces only; third-party ones like this have auto-update **off by default**,
so an install pins its version until you either turn auto-update on or update
manually. Either way, a running session won't pick up a newer release on its own:
auto-update is applied at startup and the installed version stays fixed for the
life of the session, so even after a new version is published you stay on the
loaded one until you update and reload.

### Set-and-forget: enable auto-update (recommended)

Turn on auto-update for the marketplace so new releases install at startup. Add
this to `~/.claude/settings.json` (the same block works from the
[Install](#install) step — it's here too so existing users can drop it in):

```json
{
  "extraKnownMarketplaces": {
    "branch-guard": {
      "source": { "source": "git", "url": "https://github.com/karlkfi/claude-branch-guard.git" },
      "autoUpdate": true
    }
  }
}
```

Claude Code then refreshes the marketplace and installs newer releases when it
starts. A restart (or `/reload-plugins` on the CLI/IDE) is still needed for a
freshly fetched version to become the one that runs, since the hook is registered
at startup.

### Manual update

Left auto-update off? Pull new versions by hand.

**Claude Code (CLI or IDE extension)** — run the slash commands:

```
/plugin marketplace update branch-guard
/plugin uninstall branch-guard@branch-guard
/plugin install branch-guard@branch-guard
```

The first command re-fetches the marketplace manifest from the repo; the
reinstall picks up the new version.

**Claude Code for Claude Desktop (macOS)** — the update control is tucked away:

1. Open **Customize > Plugins > Code**.
2. Click the **3-dot (⋯) menu next to the plugin name** (`branch-guard`) and
   choose **Check for updates**.
3. If an update is offered, apply it.

Desktop has no `/plugin` slash command, but the `claude` CLI shares Desktop's
plugin state, so you can update headlessly from a terminal instead of hunting for
the menu:

```bash
claude plugin marketplace update branch-guard
claude plugin update branch-guard@branch-guard
```

Restart the Desktop app afterward to load the new version.

**Restart Claude Code after updating** (on any surface). The `PreToolUse` hook is
registered at startup, so the new `branch-guard.py` only becomes the one that
actually runs once Claude Code reloads — on the CLI/IDE `/reload-plugins` will
re-register the hook without a full restart; on Desktop, restart the app.

To verify the new version is active, check the installed manifest and cache:

```bash
# Installed version + commit the harness resolved
python3 -m json.tool ~/.claude/plugins/installed_plugins.json | grep -A6 branch-guard

# The new version's files were fetched into the cache
ls ~/.claude/plugins/cache/branch-guard/branch-guard/
```

The `installed_plugins.json` entry should report the new `version` and a
`gitCommitSha` matching the release tag's commit, and a directory for the new
version should exist under
`~/.claude/plugins/cache/branch-guard/branch-guard/`. If the `version` or
`gitCommitSha` still shows the old release, the update didn't land — re-run the
update step and restart.

## How it works

0. **Strip heredoc bodies** first, quote-aware, so a heredoc's (data) contents
   aren't lexed as command segments (`git commit -F- <<'EOF' … EOF`). A quoted
   delimiter makes the body inert and always safe to drop; an unquoted body that
   the shell would expand (a command substitution in it runs) is kept so the
   substitution guard still defers; an unterminated one is left unchanged.
1. **Tokenize** the command with Python's `shlex` (POSIX mode, punctuation
   grouping) so quotes are respected and shell operators (`|`, `&&`, `>`, `;`,
   newlines) become their own tokens.
2. **Split** into simple-command segments on those operators and drop redirect
   targets aside, including fd-redirect forms (`git push … 2>&1`,
   `git log 2>/dev/null`) — the leading fd digit and the operator's target are
   both stripped so they aren't read as command arguments.
3. **Parse** each segment with `parse_invocation`: strip leading
   `NAME=VALUE` env prefixes (`GIT_AUTHOR_NAME=x git …`) and program global
   options (`git -C path`, `-c k=v`) to find the `git`/`gh` subcommand and its
   arguments. Combined short flags (`git clean -fd`) are decomposed.
4. **Classify** each segment as `allow` / `ask` / `defer` / non-git:
   read-only git and gh and harmless mutations (`add`, `restore --staged`,
   `switch -c`, `worktree add`, branch/tag create) allow on any branch;
   branch-sensitive mutations (`commit`, `merge`, `rebase`, `cherry-pick`,
   `stash`, `push`) allow on a feature branch and ask on a protected one;
   destructive commands (`reset --hard`, `clean -f`, `branch -D`, and gh
   deletes/disables — a branch via `gh pr close --delete-branch` or
   `gh api -X DELETE …/git/refs/heads/…`; a repo via `gh repo delete` or
   `gh api -X DELETE repos/{o}/{r}`; a label via `gh label delete` /
   `gh api -X DELETE …/labels/…`; a release/secret/variable/gist/cache via
   `gh <sub> delete` (`secret`/`variable` also accept `remove`; a release asset
   via `gh release delete-asset`); a workflow via
   `gh workflow disable`) ask; unknown or
   ambiguous forms defer. The branch is resolved with
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
   are dropped, so `` git diff > `evil` `` is caught too. A small registry of
   provably pure substitutions (`$(git rev-parse --show-toplevel)`,
   `$(git branch --show-current)`, `$(pwd)`) is exempt from that second downgrade
   — matched structurally, so only the exact read-only command qualifies.
6. **Fail safe** where no prompt can be shown (`dontAsk`, `bypassPermissions`):
   a would-be `ask` is emitted as `deny`, since no human is present to answer it.
   The reason names the mode and says retrying won't help, so the agent hands off
   instead of re-running a command that can't be approved from the session.

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
- **Scratch files go in a gitignored path.** Writing `tmp/notes.json` (or any
  path covered by `.gitignore`) never prompts, on any branch — an ignored file
  holds no branch contents. A file that's tracked despite matching an ignore
  rule still prompts on main/master.
- **Push the worktree's own branch.** `git push` / `git push -u origin HEAD`
  auto-approves; pushing a different branch or a refspec like `HEAD:main` prompts.
  To rewrite another unprotected branch from this one, name it in a lease —
  `git push --force-with-lease=other origin HEAD:other`.
- **Prefer fast-forward pulls on a protected branch.** On a feature branch a
  bare `git pull` is auto-approved. On `main` it prompts, because it lands a
  merge or rewrites history — `git pull --ff-only` is auto-approved there, since
  it only advances the branch to what the remote already has.
- **Chaining git/gh with harmless labels is fine; a real command is not.**
  Read-only labels/no-ops ride along, so `git log … ; echo "---" ; git status`
  and `git log | head` auto-approve — but `git commit && <other-command>` prompts
  because `<other-command>` can't ride along. Keep genuinely separate work (`rm`,
  builds, file writes) in its own call. Two forms still drop a git+label chain to
  a prompt: redirecting output to a file (`echo x > f`, `git log > f`) and command
  substitution (`echo $(…)`).
- **A few pure substitutions are exempt.** `$(git rev-parse --show-toplevel)`,
  `$(git branch --show-current)`, and `$(pwd)` don't trip the substitution guard,
  so `git -C "$(git rev-parse --show-toplevel)" status` and
  `gh pr view "$(git branch --show-current)"` auto-approve. Any other `$(…)` (or
  adding an argument/redirect inside these) still prompts — prefer these exact
  forms.
- **Expect a prompt for destructive commands** (`reset --hard`, `clean -f`,
  `branch -D`, `restore <path>`, `config --global`) — that's by design.
- **When a destructive command is denied and you meant it, say why rather than
  working around it.** In a non-interactive mode that prompt is a denial with no
  answer, and the tempting workaround — hand-editing a file back to its `HEAD`
  content instead of `git restore` — is the unsafe path *and* the ungated one.
  Re-run with a reason instead:
  `BRANCH_GUARD_OVERRIDE="reverting a superseded local change" git restore file.txt`.
  It works only for losses confined to this machine, so a push, a `gh` deletion,
  or anything on main/master stays denied — for those, ask the human.
```

## Configuration

- **Push policy** — set `BRANCH_GUARD_PUSH_POLICY` to `strict` (default),
  `protected`, or `off` (see [Push guard](#push-guard)). Set it in
  `~/.claude/settings.json` (all projects) or a project's
  `.claude/settings.json`:

  ```json
  { "env": { "BRANCH_GUARD_PUSH_POLICY": "protected" } }
  ```

- **Protected branches** — `main` and `master` are always protected. Protect more
  by setting `BRANCH_GUARD_PROTECTED_BRANCHES` to a comma-separated list of glob
  patterns, in the same `settings.json`:

  ```json
  { "env": { "BRANCH_GUARD_PROTECTED_BRANCHES": "release/*,integration" } }
  ```

  Each pattern matches a whole branch name, case-sensitively, and `*` spans `/` —
  so `release/*` covers both `release/2.0` and `release/2.0/rc`. Empty and
  whitespace-only entries are ignored.

  The list **extends** the defaults rather than replacing them. There is no way
  to configure `main` or `master` out of the protected set, so a typo (or a
  value the hook can't make sense of) can only ever protect more than you meant,
  never less. The setting reaches every place the guard consults a branch:
  commits and branch-sensitive mutations, the `Edit`/`Write` check, and the push
  guard's protected-target rule under both `strict` and `protected`.

- **Push overlap** — on by default (see [Push guard](#push-guard)). Four knobs,
  all optional:

  ```json
  {
    "env": {
      "BRANCH_GUARD_BASE_REF": "origin/main",
      "BRANCH_GUARD_OVERLAP_IGNORE": "CHANGELOG.md,docs/roadmap.md",
      "BRANCH_GUARD_RELEASE_BRANCHES": "ship/*",
      "BRANCH_GUARD_PUSH_OVERLAP_ENABLED": "false"
    }
  }
  ```

  `BRANCH_GUARD_BASE_REF` names the integration ref this branch is measured
  against. Leave it unset and the clone's own `origin/HEAD` answers it, so a
  `master`-default repo works without configuration; a ref that doesn't resolve
  switches the check off rather than blocking anything.

  `BRANCH_GUARD_OVERLAP_IGNORE` is a comma-separated glob list for paths whose
  overlap is expected — a changelog, or anything a custom merge driver owns, which
  nearly every branch touches and which would otherwise fire on every push. The
  discount is **conditional**: such a path still counts when `git merge-tree` says
  the merge genuinely conflicts there, so an ignore entry suppresses the noise
  without hiding a real collision.

  `BRANCH_GUARD_RELEASE_BRANCHES` **extends** the built-in release-branch globs
  rather than replacing them, the same way `BRANCH_GUARD_PROTECTED_BRANCHES` does.

  `BRANCH_GUARD_PUSH_OVERLAP_ENABLED` switches the check off when set to `false`,
  `0`, `no`, or `off`. Any other value — including one nobody meant as false —
  leaves it on, so a typo costs a prompt somebody can answer rather than a guard
  that quietly stopped running.

- **Non-interactive modes** — in `dontAsk` and `bypassPermissions` an `ask` is
  automatically emitted as `deny` so the guard fails safe when no human is
  present. The denial says so plainly (see [Behavior](#behavior)): there is no
  confirmation to grant in this mode, so the way through is to run the command
  yourself, re-run the session interactively, or — for the narrow set of asks it
  covers — use the
  [`BRANCH_GUARD_OVERRIDE` break-glass](#break-glass-branch_guard_override).
  (Claude Code ignores hook decisions entirely under `bypassPermissions`, so a
  hard guarantee there still needs a git `pre-push` hook or server-side branch
  protection.)

  **`auto` is not one of them.** The name suggests an unattended session and it
  usually isn't one: an `ask` in `auto` reaches a real prompt, which somebody
  answers. Denying it there removed the human rather than protecting them — a
  session could create an annotated release tag and then never publish it, so
  tagging always finished in a terminal instead.

- **Break-glass** — `BRANCH_GUARD_OVERRIDE=<reason>` as a command prefix lifts an
  ask whose damage stops at this machine. It is deliberately *not* a
  `settings.json` variable, and it reaches no protected branch, no push, and no
  `gh` deletion. See
  [Break-glass: `BRANCH_GUARD_OVERRIDE`](#break-glass-branch_guard_override).

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
  auto-approving, since those run code the classifier can't see. The one
  exception is a tiny hardcoded registry of provably pure, read-only
  substitutions (`$(git rev-parse --show-toplevel)`, `$(git branch --show-current)`,
  `$(pwd)`), matched structurally so nothing else rides in. It is a best-effort
  lexical check, not a sandbox — the filesystem boundary is workspace-guard's
  job, and a hard guarantee belongs in a git `pre-push` hook or server-side
  branch protection.
- The push guard parses the command string, so unusual refspecs may not be
  classified (it asks/defers rather than allowing). Auto-approval is a
  convenience layer, not a security boundary — for hard guarantees use a git
  `pre-push` hook and/or server-side branch protection.
- A `--force-with-lease` rewrite of another branch is auto-approved on git's
  guarantee that the remote hasn't moved, which says nothing about who else uses
  that branch. Add anything shared to
  [`BRANCH_GUARD_PROTECTED_BRANCHES`](#configuration); a branch with an open PR
  is not shared as far as the guard is concerned.
- The [break-glass](#break-glass-branch_guard_override) is self-served: the agent
  writes its own reason, and the guard checks only that one was given. It buys
  legibility over the ungated alternative — the operation stays atomic and the
  reason is recorded — not a second opinion. What keeps it bounded is its scope,
  so treat "could this reach past this machine?" as the question when considering
  a new entry.
- The [push overlap check](#push-guard) reads local refs, so it trusts your last
  `git fetch` — a base that moved since then looks unmoved, and the push is
  auto-approved. It also compares line *ranges*, not semantics: two edits six
  lines apart are reported as meeting whether or not they interact, and a rename
  or a moved function reads as unrelated. Treat it as a cheap prompt to rebase,
  not proof the merge is clean. One shape is deliberately excluded: a release
  branch is skipped on its *name*, so a topic branch named like a release
  (`hotfix-typo`) is never checked.
- The [`git branch` recoverability check](#git-branch-what-the-session-owns-not-how-the-verb-looks)
  reads local refs only, so it trusts your last `git fetch`. A remote-tracking
  ref left stale after the branch was deleted upstream still counts as
  recoverable, and a branch pushed since the last fetch may not. It also has no
  notion of a branch being shared beyond the protected set — a branch with an
  open PR is not treated as shared, though deleting it locally leaves both the
  remote branch and the PR intact.

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
analytics. It reads the pending Bash/edit command and asks `git` a few read-only
questions about the repository — the current branch (`symbolic-ref`), whether a
branch exists and where its commits survive (`show-ref`, `for-each-ref`), and
whether a path is ignored (`check-ignore`) — then decides in memory. It never
opens the contents of the file being edited and never writes anything to disk.

## Contributing

Bugs, ideas, and questions go in
[GitHub Issues](https://github.com/karlkfi/claude-branch-guard/issues).

Run the test suite (spins up a throwaway git repo under `tmp/` and asserts the
decision for each command/branch combination):

```bash
./test/run.sh
```

It needs Python 3 and `git`, plus `jq` to read the hook's JSON output. On
Windows, run it from Git Bash — that is the shell Claude Code's Bash tool uses
there, and it is how CI runs the suite on `windows-latest`.

Each case invokes the hook the same way Claude Code does, through
`hooks/run-python-hook.cmd`, so the launcher is exercised by the whole suite
rather than only in real use. Git Bash routes a `.cmd` through the Windows
command processor, so the `windows-latest` job covers the batch half of the
launcher and the Linux jobs cover the POSIX half.

## License

MIT — see [LICENSE](LICENSE).
