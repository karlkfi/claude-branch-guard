#!/usr/bin/env bash
#
# Pipe-tests for hooks/branch-guard.py, driven through hooks/run-python-hook.cmd
# the way hooks/hooks.json drives it. Spins up a throwaway git repo under tmp/,
# exercises each tool/branch combination, and asserts the emitted
# permissionDecision. Requires Python 3, jq, and git on PATH; on Windows it
# runs under Git Bash, which is the shell Claude Code's Bash tool uses there.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Every fixture goes through the launcher, named exactly as hooks/hooks.json
# names it, so the suite covers the path Claude Code actually takes. Invoking
# the .py directly leaves the launcher untested — and because Claude Code
# treats a failed PreToolUse hook as non-blocking, a broken launcher does not
# surface as an error, it surfaces as a guard that quietly enforces nothing.
# The launcher probes for a working Python 3 itself, so the harness doesn't.
LAUNCHER="$REPO_ROOT/hooks/run-python-hook.cmd"
HOOK_SCRIPT="branch-guard.py"

# Mode is load-bearing on macOS/Linux: hooks.json execs the launcher directly,
# so a checkout that dropped the bit fails every invocation with exit 126.
# Assert the mode *git records*, not the filesystem bit — that is the thing a
# fresh clone inherits, and it is checkable from any platform. `test -x` is not:
# Windows checks out under core.filemode=false and does not mark a .cmd
# executable, so it reports a problem that does not exist where mode matters.
if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  launcher_mode="$(git -C "$REPO_ROOT" ls-files -s -- hooks/run-python-hook.cmd \
    | cut -d' ' -f1)"
  if [[ "$launcher_mode" != 100755 ]]; then
    printf 'hooks/run-python-hook.cmd is mode %s in git, must be 100755\n' \
      "${launcher_mode:-unset}" >&2
    exit 1
  fi
fi

# Claude Code hands the hook native paths, so the fixtures must too. Under Git
# Bash a path is `/d/a/repo/…`, which a native Python reads through ntpath —
# where a leading slash is drive-relative, so the path lands on the hook
# process's drive and the repo lookup silently misses. `cygpath -w` is a no-op
# off Windows because the case never matches an MSYS-only prefix there.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) NATIVE_PATHS=yes ;;
  *)                    NATIVE_PATHS=no  ;;
esac

# nat PATH -> PATH in the platform's native form (identity off Windows, and for
# a relative path, which needs no conversion on either).
nat() {
  if [[ "$NATIVE_PATHS" == yes && "$1" == /* ]]; then
    cygpath -w "$1"
  else
    printf '%s' "$1"
  fi
}

# Each run gets its own throwaway repo under tmp/ so concurrent or back-to-back
# invocations never share (and clobber) a working dir. The EXIT trap removes
# only this run's dir — no blanket `rm -rf tmp` that would nuke a sibling run.
mkdir -p "$REPO_ROOT/tmp"
WORK="$(mktemp -d "$REPO_ROOT/tmp/test-repo.XXXXXX")"
# One fixture (5f) needs a directory that is inside NO repo, which nothing under
# tmp/ can be — this checkout is itself a repo. The platform temp dir is the
# only such place the suite can reach, so it lives outside tmp/ deliberately;
# the case that uses it asserts the not-a-repo precondition rather than assuming
# it.
OUTSIDE="$(mktemp -d "${TMPDIR:-/tmp}/branch-guard-outside.XXXXXX")"

# Keep tests hermetic regardless of the caller's shell.
unset BRANCH_GUARD_PUSH_POLICY

pass=0
fail=0

cleanup() {
  rm -rf "$WORK" ${OUTSIDE:+"$OUTSIDE"}
}
trap cleanup EXIT INT TERM

setup_repo() {
  rm -rf "$WORK"
  mkdir -p "$WORK"
  git -C "$WORK" init -q -b main
  git -C "$WORK" config user.name "Test"
  git -C "$WORK" config user.email "test@example.com"
  printf 'hello\n' > "$WORK/file.txt"
  # A gitignored scratch dir, plus a file that matches an ignore rule yet is
  # tracked anyway (`add -f`) — the case that separates "ignored" from "has no
  # branch contents". See section 5d.
  printf 'tmp/\nforced.txt\n' > "$WORK/.gitignore"
  mkdir -p "$WORK/tmp"
  printf 'tracked anyway\n' > "$WORK/forced.txt"
  git -C "$WORK" add -A
  git -C "$WORK" add -f forced.txt
  git -C "$WORK" commit -q -m "init"
  git -C "$WORK" branch claude/x
}

# decision_for PAYLOAD CWD [NAME=value ...] -> echoes the permissionDecision, or
# "none". Trailing args go into the hook's environment. They are passed to `env`
# quoted (`"$@"`), so a value may contain a glob (`release/*`) without the shell
# expanding it against the working directory.
decision_for() {
  local payload="$1" cwd="$2" out
  shift 2
  out="$( cd "$cwd" && printf '%s' "$payload" | env "$@" "$LAUNCHER" "$HOOK_SCRIPT" )"
  if [[ -z "$out" ]]; then
    printf 'none'
  else
    printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision'
  fi
}

# reason_for PAYLOAD CWD [NAME=value ...] -> echoes the permissionDecisionReason,
# or "".
reason_for() {
  local payload="$1" cwd="$2" out
  shift 2
  out="$( cd "$cwd" && printf '%s' "$payload" | env "$@" "$LAUNCHER" "$HOOK_SCRIPT" )"
  if [[ -n "$out" ]]; then
    printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason'
  fi
}

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s (%s)\n' "$name" "$actual"
    pass=$((pass + 1))
  else
    printf 'FAIL - %s: expected %s, got %s\n' "$name" "$expected" "$actual"
    fail=$((fail + 1))
  fi
}

# check_text NAME has|lacks NEEDLE TEXT -> assert a substring is present/absent.
check_text() {
  local name="$1" mode="$2" needle="$3" text="$4" found=no
  [[ "$text" == *"$needle"* ]] && found=yes
  if [[ ( "$mode" == has && "$found" == yes ) || ( "$mode" == lacks && "$found" == no ) ]]; then
    printf 'ok   - %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'FAIL - %s: expected reason to %s %q, got: %s\n' "$name" "$mode" "$needle" "$text"
    fail=$((fail + 1))
  fi
}

# edit_payload TOOL KEY PATH [CWD] [MODE] -> an edit-tool payload as JSON. PATH
# and CWD arrive in native form and jq json-encodes them, so a Windows path's
# backslashes survive the trip instead of reading as JSON escapes.
edit_payload() {
  jq -nc --arg tool "$1" --arg key "$2" --arg path "$(nat "$3")" \
         --arg cwd "$(nat "${4:-}")" --arg mode "${5:-}" '
    {tool_name: $tool, tool_input: {($key): $path}}
    + (if $cwd == "" then {} else {cwd: $cwd} end)
    + (if $mode == "" then {} else {permission_mode: $mode} end)'
}

# bash_payload COMMAND -> a Bash payload with COMMAND json-encoded (it may
# contain newlines, quotes, or a native path).
bash_payload() {
  jq -nc --arg cmd "$1" '{tool_name: "Bash", tool_input: {command: $cmd}}'
}

setup_repo

# 0. The launcher's own error path, which nothing else covers. A missing script
#    must fail loudly: the harness reads silence as a legitimate defer, so a
#    launcher that dies quietly looks exactly like a guard that chose not to
#    act — the same silent non-enforcement the launcher exists to prevent.
launcher_err="$(printf '' | "$LAUNCHER" definitely-not-a-real-script.py 2>&1)" \
  && launcher_rc=0 || launcher_rc=$?
check "launcher rejects a missing script -> exit 1" 1 "$launcher_rc"
check_text "launcher says why it failed" has "script not found" "$launcher_err"

#    The launcher-coverage claim, asserted directly. Every fixture reaches the
#    hook through `decision_for`/`reason_for`, and both invoke "$LAUNCHER" --
#    but that is a convention, and a convention is what a new fixture breaks.
#    A case count never checked this: a fixture running the interpreter itself
#    would increment the count, pass, and quietly leave the launcher covered by
#    one case instead of all of them. So check the property, not a proxy for it.
bypasses="$(grep -nE '(^|[^-A-Za-z_])(python3?)([^-A-Za-z_]|$).*branch-guard\.py' \
  "$SCRIPT_DIR/run.sh" || true)"
check "no fixture invokes the hook outside the launcher" "" "$bypasses"
check "both hook helpers go through the launcher" 2 \
  "$(grep -c '"\$LAUNCHER" "\$HOOK_SCRIPT"' "$SCRIPT_DIR/run.sh")"

#    Which half of the polyglot answered is itself a coverage claim, so pin it.
#    Git Bash hands a .cmd to the Windows command processor, so the batch branch
#    runs there (`%~dp0`, backslashes) and the POSIX tail runs everywhere else
#    (`pwd`, forward slashes) — which is the only reason CI covers both. If that
#    ever flips, the cmd.exe half loses its sole coverage without a single
#    fixture going red, so catch it here instead.
if [[ "$NATIVE_PATHS" == yes ]]; then
  check_text "launcher answers from its cmd.exe half" has '\hooks\' "$launcher_err"
else
  check_text "launcher answers from its POSIX half" has '/hooks/' "$launcher_err"
fi

# 1. git commit on a non-protected branch -> allow
git -C "$WORK" checkout -q claude/x
check "commit on claude/x -> allow" allow \
  "$(decision_for '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}' "$WORK")"

# 2. git commit on main -> ask
git -C "$WORK" checkout -q main
check "commit on main -> ask" ask \
  "$(decision_for '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}' "$WORK")"

# 3. read-only git auto-approves; non-git defers.
check "git status -> allow" allow \
  "$(decision_for '{"tool_name":"Bash","tool_input":{"command":"git status"}}' "$WORK")"
check "ls -> none" none \
  "$(decision_for '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' "$WORK")"

# 3b. all-git chain containing a commit on a feature branch -> allow
git -C "$WORK" checkout -q claude/x
check "add && commit on claude/x -> allow" allow \
  "$(decision_for '{"tool_name":"Bash","tool_input":{"command":"git add -A && git commit -m x"}}' "$WORK")"

# 3c. commit chained with a NON-git command on a feature branch -> defer
#     (the bug the python port fixes: the trailing command must not ride along
#     into an auto-approve).
check "commit && rm on claude/x -> none" none \
  "$(decision_for '{"tool_name":"Bash","tool_input":{"command":"git commit -m x && rm -rf foo"}}' "$WORK")"

# 3d. same mixed chain on main -> ask (commit targets a protected branch)
git -C "$WORK" checkout -q main
check "commit && rm on main -> ask" ask \
  "$(decision_for '{"tool_name":"Bash","tool_input":{"command":"git commit -m x && rm -rf foo"}}' "$WORK")"

# 3e. env-prefixed / global-flag commit still detected on main -> ask
#     The path is single-quoted because that is how a real command names a
#     native Windows path: the hook lexes with shlex, which eats an unquoted
#     backslash exactly as bash does. A no-op on a POSIX path.
check "env-prefixed commit on main -> ask" ask \
  "$(decision_for "$(bash_payload "GIT_AUTHOR_NAME=x git -C '$(nat "$WORK")' commit -m y")" "$WORK")"

# 3f. `git log` is read-only (the `commit` substring is not a commit invocation).
check "git log --grep=commit -> allow" allow \
  "$(decision_for '{"tool_name":"Bash","tool_input":{"command":"git log --grep=commit"}}' "$WORK")"

# 4. edit of a file whose repo is on main -> ask
git -C "$WORK" checkout -q main
check "edit on main -> ask" ask \
  "$(decision_for "$(edit_payload Edit file_path "$WORK/file.txt")" "$REPO_ROOT")"

# 5. edit of a file whose repo is on a non-protected branch -> no decision
git -C "$WORK" checkout -q claude/x
check "write on claude/x -> none" none \
  "$(decision_for "$(edit_payload Write file_path "$WORK/file.txt")" "$REPO_ROOT")"

# 5b. NotebookEdit (path comes in as `notebook_path`) is guarded like the other
#     edit tools: ask on main, defer on a feature branch.
git -C "$WORK" checkout -q main
check "notebook edit on main -> ask" ask \
  "$(decision_for "$(edit_payload NotebookEdit notebook_path "$WORK/file.txt")" "$REPO_ROOT")"
git -C "$WORK" checkout -q claude/x
check "notebook edit on claude/x -> none" none \
  "$(decision_for "$(edit_payload NotebookEdit notebook_path "$WORK/file.txt")" "$REPO_ROOT")"

# 5c. Nested worktree: a RELATIVE file_path resolves against the payload `cwd`
#     (the session's worktree), not the hook process's own cwd. Here the process
#     runs from the main checkout (on `main`) while the payload cwd points at a
#     worktree on the feature branch — the edit must NOT falsely flag `main`.
git -C "$WORK" checkout -q main
WT="$WORK/.claude/worktrees/wt"
git -C "$WORK" worktree add -q "$WT" claude/x
check "edit rel path honors payload cwd (worktree on claude/x) -> none" none \
  "$(decision_for "$(edit_payload Edit file_path file.txt "$WT")" "$WORK")"
# And the converse still catches main when the payload cwd is the main checkout.
check "edit rel path honors payload cwd (main checkout) -> ask" ask \
  "$(decision_for "$(edit_payload Edit file_path file.txt "$WORK")" "$REPO_ROOT")"
git -C "$WORK" worktree remove -f "$WT"

# 5d. A gitignored path holds no branch contents, so editing one on a protected
#     branch is the same operation it would be on a feature branch — no prompt.
#     The tracked-but-ignored file is the security half of this: `git add -f`
#     puts it in the index, its edits DO land on the branch, and `check-ignore`
#     reports it as not-ignored precisely because it consults the index. That
#     is what makes one probe sufficient, so pin it — a `--no-index` here would
#     read the pattern alone and silently drop the guard on a tracked file.
git -C "$WORK" checkout -q main
check "edit gitignored path on main -> none" none \
  "$(decision_for "$(edit_payload Write file_path "$WORK/tmp/scratch.json")" "$REPO_ROOT")"
check "edit tracked-but-ignored path on main -> ask" ask \
  "$(decision_for "$(edit_payload Edit file_path "$WORK/forced.txt")" "$REPO_ROOT")"
#     The ignored path is also reached via a relative file_path + payload cwd,
#     so the skip resolves the same path the branch check does.
check "edit gitignored rel path on main -> none" none \
  "$(decision_for "$(edit_payload Write file_path tmp/scratch.json "$WORK")" "$REPO_ROOT")"
#     And it is a skip, not a blanket exemption: a non-ignored sibling in the
#     same directory still asks.
check "edit non-ignored path on main -> ask" ask \
  "$(decision_for "$(edit_payload Edit file_path "$WORK/file.txt")" "$REPO_ROOT")"
#     The skip must not fire where no human could answer it either way — an
#     ignored path defers rather than denying under a non-interactive mode.
check "[auto] edit gitignored path on main -> none" none \
  "$(decision_for "$(edit_payload Write file_path "$WORK/tmp/scratch.json" "" auto)" "$REPO_ROOT")"

# 5e. The probe must answer about the file the write LANDS on. A symlink inside
#     an ignored dir is itself ignored, but its target need not be — so probing
#     the link as given exempted an edit that really did change branch contents.
#     Git Bash's `ln -s` copies the file unless Windows permits a real link, so
#     assert against what the fixture actually is rather than the platform: with
#     a copy there is no target to follow and the ignored-dir exemption holds.
printf 'scratch\n' > "$WORK/tmp/scratch.json"
ln -s ../file.txt "$WORK/tmp/to-tracked.txt" 2>/dev/null || true
ln -s ./scratch.json "$WORK/tmp/to-ignored.json" 2>/dev/null || true
if [[ -L "$WORK/tmp/to-tracked.txt" ]]; then
  check "edit symlink in ignored dir -> tracked file on main -> ask" ask \
    "$(decision_for "$(edit_payload Edit file_path "$WORK/tmp/to-tracked.txt")" "$REPO_ROOT")"
else
  check "edit copy in ignored dir (no symlink support) on main -> none" none \
    "$(decision_for "$(edit_payload Edit file_path "$WORK/tmp/to-tracked.txt")" "$REPO_ROOT")"
fi
#     A link to a genuinely ignored file stays exempt, so the feature survives —
#     and a copy of one is ignored too, which is why this expectation doesn't
#     move with symlink support.
check "edit symlink in ignored dir -> ignored file on main -> none" none \
  "$(decision_for "$(edit_payload Write file_path "$WORK/tmp/to-ignored.json")" "$REPO_ROOT")"

# 5f. An edit names where the file WILL be, and that directory need not exist —
#     agents create files in new directories constantly. `git -C` fails on a
#     missing directory before it ever looks for a repo, so the branch read as
#     unresolvable and the write went unguarded on `main`, silently. The two
#     axes cross here: the branch (protected vs feature) and whether the
#     not-yet-existing path is ignored, since neither alone pins the outcome.
check "edit new file in a new dir on main -> ask" ask \
  "$(decision_for "$(edit_payload Write file_path "$WORK/newdir/f.py")" "$REPO_ROOT")"
check "edit new file in deeply nested new dirs on main -> ask" ask \
  "$(decision_for "$(edit_payload Write file_path "$WORK/a/b/c/f.py")" "$REPO_ROOT")"
#     The #58 gitignored skip still applies once the branch resolves: a new dir
#     under an ignored one holds no branch contents either.
check "edit new file in a new dir under a gitignored dir on main -> none" none \
  "$(decision_for "$(edit_payload Write file_path "$WORK/tmp/newdir/f.py")" "$REPO_ROOT")"
#     Walking up only ever reaches an ancestor of the file, so a path in no repo
#     still resolves to no branch — the fail-safe half. Assert the precondition
#     rather than trusting it: if the system temp dir were itself inside a repo,
#     the case below would pass for the wrong reason.
outside_is_repo=no
git -C "$OUTSIDE" rev-parse --is-inside-work-tree >/dev/null 2>&1 && outside_is_repo=yes
check "system temp dir sits in no repo (precondition)" no "$outside_is_repo"
check "edit new file in a new dir outside any repo -> none" none \
  "$(decision_for "$(edit_payload Write file_path "$OUTSIDE/newdir/f.py")" "$REPO_ROOT")"

git -C "$WORK" checkout -q claude/x
#     And the feature-branch control: the walk resolves a branch there too, it
#     just isn't one worth prompting about.
check "edit new file in a new dir on claude/x -> none" none \
  "$(decision_for "$(edit_payload Write file_path "$WORK/newdir/f.py")" "$REPO_ROOT")"

# 6. unknown tool / missing file_path -> no decision
check "unknown tool -> none" none \
  "$(decision_for '{"tool_name":"Read","tool_input":{"file_path":"/etc/hosts"}}' "$REPO_ROOT")"
check "edit missing file_path -> none" none \
  "$(decision_for '{"tool_name":"Edit","tool_input":{}}' "$REPO_ROOT")"
check "notebook edit missing notebook_path -> none" none \
  "$(decision_for '{"tool_name":"NotebookEdit","tool_input":{}}' "$REPO_ROOT")"

# ---------------------------------------------------------------------------
# Push guard. Run from the worktree on the feature branch unless noted.
git -C "$WORK" checkout -q claude/x

# JSON payload helpers.
push()      { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }
push_mode() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"permission_mode":"%s"}' "$1" "$2"; }

PROT='BRANCH_GUARD_PUSH_POLICY=protected'
OFF='BRANCH_GUARD_PUSH_POLICY=off'

# 7. strict is the default: auto-approve a push of the worktree's own branch
#    (including force pushes); ask for anything else.
check "[default=strict] bare push -> allow" allow \
  "$(decision_for "$(push 'git push')" "$WORK")"
check "[default=strict] push origin HEAD -> allow" allow \
  "$(decision_for "$(push 'git push origin HEAD')" "$WORK")"
check "[default=strict] push origin claude/x -> allow" allow \
  "$(decision_for "$(push 'git push origin claude/x')" "$WORK")"
check "[default=strict] force-push worktree branch -> allow" allow \
  "$(decision_for "$(push 'git push --force origin claude/x')" "$WORK")"
check "[default=strict] force-push (-f) bare -> allow" allow \
  "$(decision_for "$(push 'git push -f')" "$WORK")"
check "[default=strict] commit && push (worktree) -> allow" allow \
  "$(decision_for "$(push 'git commit -m x && git push')" "$WORK")"
check "[default=strict] push origin main -> ask" ask \
  "$(decision_for "$(push 'git push origin main')" "$WORK")"
check "[default=strict] push origin feature-y -> ask" ask \
  "$(decision_for "$(push 'git push origin feature-y')" "$WORK")"
check "[default=strict] push origin HEAD:other -> ask" ask \
  "$(decision_for "$(push 'git push origin HEAD:other')" "$WORK")"
check "[default=strict] force-push to main -> ask" ask \
  "$(decision_for "$(push 'git push -f origin main')" "$WORK")"
check "[default=strict] push --all -> ask" ask \
  "$(decision_for "$(push 'git push --all origin')" "$WORK")"
check "[default=strict] push && rm (worktree) -> none" none \
  "$(decision_for "$(push 'git push && rm -rf foo')" "$WORK")"

# 7a. Publishing a tag is not a push of the worktree branch, however it's
#     spelled. A bare name already asked; a fully-qualified ref used to sail
#     past every branch check into the auto-approve, because a non-`refs/heads/`
#     ref read as "no branch involved".
check "[default=strict] push origin v1.3.0 (bare tag name) -> ask" ask \
  "$(decision_for "$(push 'git push origin v1.3.0')" "$WORK")"
check "[default=strict] push origin refs/tags/v1.3.0 -> ask" ask \
  "$(decision_for "$(push 'git push origin refs/tags/v1.3.0')" "$WORK")"
check "[default=strict] push --tags -> ask" ask \
  "$(decision_for "$(push 'git push --tags')" "$WORK")"
check "[default=strict] push --tags origin -> ask" ask \
  "$(decision_for "$(push 'git push --tags origin')" "$WORK")"
check "[default=strict] delete a tag ref -> ask" ask \
  "$(decision_for "$(push 'git push origin --delete refs/tags/v1.3.0')" "$WORK")"
check_text "[default=strict] tag-ref reason names it a non-branch ref" has \
  "a tag or other non-branch ref" \
  "$(reason_for "$(push 'git push origin refs/tags/v1.3.0')" "$WORK")"
# A fully-qualified BRANCH ref is still the worktree branch -> unchanged.
check "[default=strict] push origin refs/heads/claude/x -> allow" allow \
  "$(decision_for "$(push 'git push origin refs/heads/claude/x')" "$WORK")"
# --follow-tags pushes only tags reachable from the branch already being pushed,
# and push.followTags does the same from config where the hook can't see it, so
# it stays auto-approved. Pinned so the gap is a decision, not a drift.
check "[default=strict] push --follow-tags -> allow" allow \
  "$(decision_for "$(push 'git push --follow-tags')" "$WORK")"

# 7b. A rebase-and-force-push flow rewrites one branch from another, so the
#     destination is never the worktree branch and every spelling of it asked.
#     `--force-with-lease=<dst>` makes git abort unless the remote is still at
#     the commit the command named, so the push cannot clobber work the session
#     hasn't seen — the same "git already enforces it" argument the non-force
#     `git branch` spellings rest on. The lease must NAME the destination, so a
#     cross-name push states its target twice.
check "[default=strict] leased rewrite of another branch -> allow" allow \
  "$(decision_for "$(push 'git push --force-with-lease=other:abc123 origin claude/x:other')" "$WORK")"
check "[default=strict] leased rewrite, lease without a sha -> allow" allow \
  "$(decision_for "$(push 'git push --force-with-lease=other origin claude/x:other')" "$WORK")"
check "[default=strict] leased rewrite from HEAD -> allow" allow \
  "$(decision_for "$(push 'git push --force-with-lease=other origin HEAD:other')" "$WORK")"
check "[default=strict] leased rewrite, fully-qualified dst -> allow" allow \
  "$(decision_for "$(push 'git push --force-with-lease=refs/heads/other origin HEAD:refs/heads/other')" "$WORK")"
# The cells that must stay closed, crossed against each question a lease does
# NOT answer. Recoverability and sharedness are independent, and git enforces
# only the first: `is_protected` runs before the strict block, so no lease can
# reach past it onto a protected destination.
check "[default=strict] cross-name push without a lease -> ask" ask \
  "$(decision_for "$(push 'git push origin claude/x:other')" "$WORK")"
check "[default=strict] bare --force-with-lease names no dst -> ask" ask \
  "$(decision_for "$(push 'git push --force-with-lease origin claude/x:other')" "$WORK")"
check "[default=strict] lease names a different branch -> ask" ask \
  "$(decision_for "$(push 'git push --force-with-lease=elsewhere origin claude/x:other')" "$WORK")"
check "[default=strict] leased rewrite of main -> ask" ask \
  "$(decision_for "$(push 'git push --force-with-lease=main origin claude/x:main')" "$WORK")"
# The source must be the worktree branch: a lease bounds the destination, not
# which local branch is being sent.
check "[default=strict] leased push of a foreign source -> ask" ask \
  "$(decision_for "$(push 'git push --force-with-lease=other origin feature-y:other')" "$WORK")"
# A lease bounds what the remote is when the ref goes, not whether removing it
# is in bounds — so both deletion spellings keep asking.
check "[default=strict] leased --delete -> ask" ask \
  "$(decision_for "$(push 'git push --delete --force-with-lease=other origin other')" "$WORK")"
check "[default=strict] leased delete via empty source -> ask" ask \
  "$(decision_for "$(push 'git push --force-with-lease=other origin :other')" "$WORK")"
# git lets a later --no-force-with-lease cancel every earlier lease, so the
# guard has to as well or the flag would allow a push git then refuses to fence.
check "[default=strict] --no-force-with-lease cancels the lease -> ask" ask \
  "$(decision_for "$(push 'git push --force-with-lease=other --no-force-with-lease origin HEAD:other')" "$WORK")"
# A lease naming a non-branch ref names no destination branch (section 7a).
check "[default=strict] lease on a tag ref -> ask" ask \
  "$(decision_for "$(push 'git push --force-with-lease=refs/tags/v1 origin HEAD:refs/tags/v1')" "$WORK")"
# The whole point of the relaxation is auto mode, where the ask it replaces was
# a deny with no way to answer it — so pin both halves under 'auto'.
check "[auto] leased rewrite of another branch -> allow" allow \
  "$(decision_for "$(push_mode 'git push --force-with-lease=other origin HEAD:other' 'auto')" "$WORK")"
check "[auto] cross-name push without a lease -> deny" deny \
  "$(decision_for "$(push_mode 'git push origin HEAD:other' 'auto')" "$WORK")"
# `protected` never auto-approves, so the lease must not leak a push into it.
check "[protected] leased rewrite of another branch -> none" none \
  "$(decision_for "$(push 'git push --force-with-lease=other origin HEAD:other')" "$WORK" "$PROT")"

# 8. protected policy: ask only on a protected target; never auto-approve.
check "[protected] push origin main -> ask" ask \
  "$(decision_for "$(push 'git push origin main')" "$WORK" "$PROT")"
check "[protected] push origin HEAD:main -> ask" ask \
  "$(decision_for "$(push 'git push origin HEAD:main')" "$WORK" "$PROT")"
check "[protected] delete main (:main) -> ask" ask \
  "$(decision_for "$(push 'git push origin :main')" "$WORK" "$PROT")"
check "[protected] worktree-branch push -> none" none \
  "$(decision_for "$(push 'git push origin HEAD')" "$WORK" "$PROT")"
check "[protected] push other feature branch -> none" none \
  "$(decision_for "$(push 'git push origin feature-y')" "$WORK" "$PROT")"
# protected only guards main/master, so a tag push defers there as before —
# the strict-only tag rule must not leak into it.
check "[protected] push origin refs/tags/v1.3.0 -> none" none \
  "$(decision_for "$(push 'git push origin refs/tags/v1.3.0')" "$WORK" "$PROT")"
check "[protected] push --tags -> none" none \
  "$(decision_for "$(push 'git push --tags')" "$WORK" "$PROT")"

# 9. off policy: pushes are not guarded.
check "[off] push origin main -> none" none \
  "$(decision_for "$(push 'git push origin main')" "$WORK" "$OFF")"

# 10. non-interactive ('auto') modes: a would-be ask becomes deny (fail safe),
#     while allow and defer are unaffected.
check "[auto] push origin main -> deny" deny \
  "$(decision_for "$(push_mode 'git push origin main' 'auto')" "$WORK")"
check "[bypassPermissions] push origin main -> deny" deny \
  "$(decision_for "$(push_mode 'git push origin main' 'bypassPermissions')" "$WORK")"
check "[auto] worktree-branch push -> allow (unchanged)" allow \
  "$(decision_for "$(push_mode 'git push' 'auto')" "$WORK")"
check "[acceptEdits] push origin main -> ask (human present)" ask \
  "$(decision_for "$(push_mode 'git push origin main' 'acceptEdits')" "$WORK")"

# 11. non-interactive mode also converts a commit-on-protected ask to deny.
git -C "$WORK" checkout -q main
check "[auto] commit on main -> deny" deny \
  "$(decision_for "$(push_mode 'git commit -m x' 'auto')" "$WORK")"
git -C "$WORK" checkout -q claude/x

# 11a. Reason wording: an `ask` offers a confirmation; a `deny` must not, or the
#      agent retries a command that cannot succeed in this session (issue #33).
#      A release-tag push is the case that surfaced it.
tag_ask="$(reason_for "$(push_mode 'git push origin v1.3.0' 'default')" "$WORK")"
check_text "[default] tag push reason states the cause" has \
  "Push targets 'v1.3.0', not the worktree branch 'claude/x'" "$tag_ask"
check_text "[default] tag push reason invites confirmation" has \
  "— confirm before proceeding." "$tag_ask"

tag_deny="$(reason_for "$(push_mode 'git push origin v1.3.0' 'auto')" "$WORK")"
check_text "[auto] tag push deny keeps the cause" has \
  "Push targets 'v1.3.0', not the worktree branch 'claude/x'" "$tag_deny"
check_text "[auto] tag push deny is not confirm-shaped" lacks \
  "confirm before proceeding" "$tag_deny"
check_text "[auto] tag push deny names the mode" has "permission mode 'auto'" "$tag_deny"
check_text "[auto] tag push deny says retrying won't help" has \
  "Retrying won't help" "$tag_deny"

# The same wording split applies to every ask site, not just pushes.
git -C "$WORK" checkout -q main
check_text "[auto] commit-on-main deny is not confirm-shaped" lacks "confirm before proceeding" \
  "$(reason_for "$(push_mode 'git commit -m x' 'auto')" "$WORK")"
check_text "[auto] edit-on-main deny is not confirm-shaped" lacks "confirm before proceeding" \
  "$(reason_for "$(edit_payload Edit file_path "$WORK/file.txt" "" auto)" "$WORK")"
check_text "[default] edit-on-main ask invites confirmation" has "— confirm before proceeding." \
  "$(reason_for "$(edit_payload Edit file_path "$WORK/file.txt" "" default)" "$WORK")"
git -C "$WORK" checkout -q claude/x

# 11b. detached HEAD resolves to no branch, so the hook defers (even though the
#      detached commit is really main's) — `rev-parse --abbrev-ref` would print
#      "HEAD" and mis-treat it as an ordinary feature branch.
git -C "$WORK" checkout -q --detach
check "[detached HEAD] commit -> none (defer)" none \
  "$(decision_for '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}' "$WORK")"
git -C "$WORK" checkout -q claude/x

# ---------------------------------------------------------------------------
# 12. Read-only git allowlist — auto-allow on any branch.
bash_cmd() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }

for c in "git diff" "git log --oneline -5" "git show HEAD" "git branch" \
         "git rev-parse HEAD" "git fetch origin" "git remote -v" \
         "git stash list" "git config --get user.name" "git status && git log"; do
  check "readonly: $c -> allow" allow "$(decision_for "$(bash_cmd "$c")" "$WORK")"
done

# 13. Feature-safe mutations: allow on any branch (staging/branch-create) or on
#     a feature branch (commit-bearing); destructive variants ask.
check "git add -A -> allow" allow \
  "$(decision_for "$(bash_cmd 'git add -A')" "$WORK")"
check "git switch -c new -> allow" allow \
  "$(decision_for "$(bash_cmd 'git switch -c newbranch')" "$WORK")"
check "git checkout -b new -> allow" allow \
  "$(decision_for "$(bash_cmd 'git checkout -b newbranch')" "$WORK")"
check "git worktree add -> allow" allow \
  "$(decision_for "$(bash_cmd 'git worktree add ../wt feature')" "$WORK")"
check "git restore --staged -> allow" allow \
  "$(decision_for "$(bash_cmd 'git restore --staged file.txt')" "$WORK")"
check "git checkout <ambiguous> -> none (defer)" none \
  "$(decision_for "$(bash_cmd 'git checkout file.txt')" "$WORK")"

# 14. Destructive git commands ask (and deny when unattended).
#     `git reset --hard` does two things and only one is a ref operation: it
#     moves the branch pointer, and it discards uncommitted changes to tracked
#     files. Uncommitted work is in no ref, so a dirty worktree always asks; a
#     clean one reduces the command to the pointer move, where the same
#     shared/recoverable pair applies. Crossed both ways, per the rule above.
printf 'dirty\n' >> "$WORK/file.txt"
check "git reset --hard, dirty worktree -> ask" ask \
  "$(decision_for "$(bash_cmd 'git reset --hard HEAD~1')" "$WORK")"
check "[auto] git reset --hard, dirty worktree -> deny" deny \
  "$(decision_for "$(push_mode 'git reset --hard' 'auto')" "$WORK")"
git -C "$WORK" checkout -q -- file.txt
check "git reset --hard, clean worktree on a recoverable branch -> allow" allow \
  "$(decision_for "$(bash_cmd 'git reset --hard HEAD~1')" "$WORK")"
#     `reset` never deletes untracked or ignored files, so an untracked file
#     must not read as dirty -- that is what `--porcelain -uno` buys, and
#     without it this prompts for something the command cannot destroy.
printf 'scratch\n' > "$WORK/untracked-scratch.txt"
check "git reset --hard, only an untracked file present -> allow" allow \
  "$(decision_for "$(bash_cmd 'git reset --hard HEAD~1')" "$WORK")"
rm -f "$WORK/untracked-scratch.txt"
#     Shared first, as everywhere else.
git -C "$WORK" checkout -q main
check "git reset --hard on protected -> ask" ask \
  "$(decision_for "$(bash_cmd 'git reset --hard HEAD~1')" "$WORK")"
git -C "$WORK" checkout -q claude/x
#     A tip nothing else reaches keeps the ask even with a clean worktree.
git -C "$WORK" checkout -q -b reset-orphan
git -C "$WORK" commit -q --allow-empty -m "unreachable from anything"
check "git reset --hard on an irrecoverable tip -> ask" ask \
  "$(decision_for "$(bash_cmd 'git reset --hard HEAD~1')" "$WORK")"
git -C "$WORK" checkout -q claude/x
#     The probes read the session repo, so a foreign one keeps the ask.
check "git -C other-repo reset --hard -> ask" ask \
  "$(decision_for "$(bash_cmd 'git -C /somewhere/else reset --hard')" "$WORK")"
check "git reset --soft -> none (defer)" none \
  "$(decision_for "$(bash_cmd 'git reset --soft HEAD~1')" "$WORK")"
check "git clean -fd -> ask" ask \
  "$(decision_for "$(bash_cmd 'git clean -fd')" "$WORK")"
check "git branch -D -> ask" ask \
  "$(decision_for "$(bash_cmd 'git branch -D old')" "$WORK")"
# A non-force rename can't lose commits -- git refuses to clobber an existing
# destination itself -- so it is auto-approved rather than prompted.
check "git branch -m rename -> allow" allow \
  "$(decision_for "$(bash_cmd 'git branch -m old new')" "$WORK")"
# `-f` neither deletes nor renames: it creates, or force-moves an existing
# pointer. Creating a name nothing holds loses nothing, so it allows.
check "git branch -f creating a free name -> allow" allow \
  "$(decision_for "$(bash_cmd 'git branch -f backup old')" "$WORK")"
branch_D_reason="$(reason_for "$(bash_cmd 'git branch -D old')" "$WORK")"
check_text "git branch -D reason names the delete" has \
  'force-deletes' "$branch_D_reason"
check_text "git branch -D reason does not claim a rename" lacks \
  'Deleting/renaming' "$branch_D_reason"
# `-D` is `--delete --force` spelled long; the delete reason must win.
check_text "git branch -d --force reason names the delete" has \
  'force-deletes' \
  "$(reason_for "$(bash_cmd 'git branch -d --force old')" "$WORK")"
check "git restore (worktree) -> ask" ask \
  "$(decision_for "$(bash_cmd 'git restore file.txt')" "$WORK")"
#     git refuses to remove a worktree holding modified OR untracked files
#     (exit 128, "use --force to delete it"), so the non-force form cannot
#     destroy uncommitted work -- the same "git enforces it" reasoning as
#     `branch -d`. Crossed against the force spelling, which can.
check "git worktree remove -> allow (git refuses a dirty one)" allow \
  "$(decision_for "$(bash_cmd 'git worktree remove ../wt')" "$WORK")"
check "git worktree remove --force -> ask" ask \
  "$(decision_for "$(bash_cmd 'git worktree remove --force ../wt')" "$WORK")"
check "git worktree remove -f -> ask" ask \
  "$(decision_for "$(bash_cmd 'git worktree remove -f ../wt')" "$WORK")"
check "git worktree prune -> ask" ask \
  "$(decision_for "$(bash_cmd 'git worktree prune')" "$WORK")"
check "git worktree move -> ask" ask \
  "$(decision_for "$(bash_cmd 'git worktree move ../wt ../wt2')" "$WORK")"
check "git config --global -> ask" ask \
  "$(decision_for "$(bash_cmd 'git config --global user.name x')" "$WORK")"
check "git stash drop -> ask" ask \
  "$(decision_for "$(bash_cmd 'git stash drop')" "$WORK")"
#     Stashing adds no commit and rewrites no history, so the branch a session
#     sits on is the wrong question for it -- and it is recoverable by
#     construction, which is the whole point. Only the forms that discard a
#     stash are gated. Nothing crossed stash against a protected branch before,
#     which is how the wrong axis went unnoticed.
check "git stash -> allow" allow \
  "$(decision_for "$(bash_cmd 'git stash')" "$WORK")"
check "git stash pop -> allow" allow \
  "$(decision_for "$(bash_cmd 'git stash pop')" "$WORK")"
check "git stash branch (unlisted form) -> none (defer)" none \
  "$(decision_for "$(bash_cmd 'git stash branch recovered')" "$WORK")"
git -C "$WORK" checkout -q main
check "git stash on main -> allow (touches no branch history)" allow \
  "$(decision_for "$(bash_cmd 'git stash')" "$WORK")"
check "git stash pop on main -> allow" allow \
  "$(decision_for "$(bash_cmd 'git stash pop')" "$WORK")"
check "git stash drop on main -> ask (still discards a stash)" ask \
  "$(decision_for "$(bash_cmd 'git stash drop')" "$WORK")"
git -C "$WORK" checkout -q claude/x
check "readonly + destructive chain -> ask" ask \
  "$(decision_for "$(bash_cmd 'git status && git clean -fd')" "$WORK")"
check "[auto] git clean -fd -> deny" deny \
  "$(decision_for "$(push_mode 'git clean -fd' 'auto')" "$WORK")"

# 15. Branch-sensitive mutations: feature -> allow, protected -> ask.
check "git rebase on feature -> allow" allow \
  "$(decision_for "$(bash_cmd 'git rebase origin/main')" "$WORK")"
check "git merge on feature -> allow" allow \
  "$(decision_for "$(bash_cmd 'git merge feature-y')" "$WORK")"
check "git rebase --abort -> allow" allow \
  "$(decision_for "$(bash_cmd 'git rebase --abort')" "$WORK")"
check "git pull --ff-only -> allow" allow \
  "$(decision_for "$(bash_cmd 'git pull --ff-only')" "$WORK")"
#     `pull` is `fetch` + `merge`-or-`rebase`, all three of which allow on a
#     feature branch, so gating the composite there was stricter than any of
#     its parts. Crossed against the protected branch below.
check "git pull (non-ff) on a feature branch -> allow" allow \
  "$(decision_for "$(bash_cmd 'git pull')" "$WORK")"
check "git pull --rebase on a feature branch -> allow" allow \
  "$(decision_for "$(bash_cmd 'git pull --rebase')" "$WORK")"
git -C "$WORK" checkout -q main
check "git rebase on main -> ask" ask \
  "$(decision_for "$(bash_cmd 'git rebase origin/main')" "$WORK")"
check "git merge on main -> ask" ask \
  "$(decision_for "$(bash_cmd 'git merge feature-y')" "$WORK")"
check "git pull (non-ff) on main -> ask" ask \
  "$(decision_for "$(bash_cmd 'git pull')" "$WORK")"
check "git pull --rebase on main -> ask" ask \
  "$(decision_for "$(bash_cmd 'git pull --rebase')" "$WORK")"
check_text "git pull on main names the branch" has \
  "protected branch 'main'" "$(reason_for "$(bash_cmd 'git pull')" "$WORK")"
#     A fast-forward adds no local work to the branch, so it stays allowed even
#     on a protected one -- it only advances main to what the remote already has.
check "git pull --ff-only on main -> allow" allow \
  "$(decision_for "$(bash_cmd 'git pull --ff-only')" "$WORK")"
git -C "$WORK" checkout -q claude/x

# 16. Inline-config escape hatch blocks auto-allow but not a protective ask.
check "git -c pager log -> none (defer, not allow)" none \
  "$(decision_for "$(bash_cmd 'git -c core.pager=cat log')" "$WORK")"
git -C "$WORK" checkout -q main
check "git -c k=v commit on main -> ask (still gated)" ask \
  "$(decision_for "$(bash_cmd 'git -c user.name=x commit -m y')" "$WORK")"
git -C "$WORK" checkout -q claude/x

# 17. Read-only gh allowlist; gh mutations defer to the normal flow.
check "gh pr list -> allow" allow \
  "$(decision_for "$(bash_cmd 'gh pr list')" "$WORK")"
check "gh pr view 1 -> allow" allow \
  "$(decision_for "$(bash_cmd 'gh pr view 1')" "$WORK")"
check "gh repo view -> allow" allow \
  "$(decision_for "$(bash_cmd 'gh repo view')" "$WORK")"
check "gh status && git status -> allow" allow \
  "$(decision_for "$(bash_cmd 'gh pr list && git status')" "$WORK")"
check "gh pr create -> none (defer)" none \
  "$(decision_for "$(bash_cmd 'gh pr create --fill')" "$WORK")"
# 17b. Read-only gh reads added to the allowlist (run watch / search / list-view).
for c in "gh run watch 123" "gh run watch 123 --exit-status" \
         "gh search prs --state open" "gh search code foo" \
         "gh repo list karlkfi" "gh secret list" "gh variable list" \
         "gh ruleset list" "gh ruleset view 1" "gh cache list" \
         "gh label list" "gh gist list" "gh gist view abc"; do
  check "readonly gh: $c -> allow" allow "$(decision_for "$(bash_cmd "$c")" "$WORK")"
done
# gh mutations that are NOT in the allowlist still defer (outward-facing writes).
for c in "gh run rerun 123" "gh run cancel 123" "gh workflow run ci.yml" \
         "gh pr merge 5" "gh pr comment 5 --body hi" "gh secret set X" \
         "gh release download v1"; do
  check "gh mutation: $c -> none (defer)" none "$(decision_for "$(bash_cmd "$c")" "$WORK")"
done
#      `--delete-branch` on a MERGE defers with it. The merge lands the work on
#      the base branch before the delete runs, so the delete adds no risk beyond
#      the merge -- and escalating it to `ask` while `gh pr merge` defers
#      overrode the user's own settings for the safer of the two spellings.
#      Crossed against `gh pr close`, where the work was never merged, below.
for c in "gh pr merge 5 --delete-branch" "gh pr merge 5 -d" \
         "gh pr merge 5 --squash --delete-branch"; do
  check "gh pr merge + delete: $c -> none (defer)" none \
    "$(decision_for "$(bash_cmd "$c")" "$WORK")"
done

# 17c. `gh api` is classified by HTTP method: a default/explicit GET reads (allow);
#      a write method or a request body (--field/--raw-field/--input) defers.
for c in "gh api repos/o/r" "gh api repos/o/r --jq .name" \
         "gh api -H Accept:x repos/o/r" "gh api repos/o/r --paginate" \
         "gh api -X GET repos/o/r/issues" "gh api --method GET user"; do
  check "gh api GET: $c -> allow" allow "$(decision_for "$(bash_cmd "$c")" "$WORK")"
done
for c in "gh api -X POST repos/o/r/issues" "gh api --method=PATCH repos/o/r" \
         "gh api repos/o/r -f title=x" \
         "gh api repos/o/r -F n=1" "gh api repos/o/r --field title=x" \
         "gh api --input body.json repos/o/r" "gh api graphql -f query=x"; do
  check "gh api write: $c -> none (defer)" none "$(decision_for "$(bash_cmd "$c")" "$WORK")"
done
# A non-repo, non-ref, non-label DELETE via the API still defers (e.g. unfollow,
# or a sub-resource path that isn't an exact `repos/{o}/{r}`).
for c in "gh api -X DELETE user/following/x" \
         "gh api -X DELETE repos/o/r/issues/comments/1"; do
  check "gh api other delete: $c -> none (defer)" none "$(decision_for "$(bash_cmd "$c")" "$WORK")"
done
# 17d. Destructive gh deletes/disables are escalated to ask (mirrors the git
#      destructive tier: `git branch -D` / `git push --delete`). Branch: the api
#      refs endpoint (all method spellings) and `--delete-branch`/`-d` on pr
#      merge/close. Resource: native `gh <sub> delete` subcommands
#      (repo/label/release/secret/variable/gist/cache, the `release delete-asset`
#      form, plus the `remove` alias for secret/variable and `gh workflow
#      disable`), a label/repo delete via
#      the api, and a repo delete via the api refs/labels/repos endpoints.
check_text "gh pr close --delete-branch reason says the work was never merged" has \
  "work was never merged" \
  "$(reason_for "$(bash_cmd 'gh pr close 5 --delete-branch')" "$WORK")"
for c in "gh api -X DELETE repos/o/r/git/refs/heads/feature-x" \
         "gh api -XDELETE repos/o/r/git/refs/heads/main" \
         "gh api --method DELETE repos/o/r/git/refs/tags/v1" \
         "gh pr close 5 --delete-branch" "gh pr close 5 -d" \
         "gh repo delete owner/repo" "gh repo delete owner/repo --yes" \
         "gh label delete bug" "gh label delete bug --yes" \
         "gh release delete v1" "gh release delete v1 --yes" \
         "gh release delete-asset v1 file.zip" \
         "gh secret delete TOKEN" "gh secret remove TOKEN" \
         "gh variable delete VAR" "gh variable remove VAR" \
         "gh gist delete abc123" "gh cache delete 42" "gh cache delete --all" \
         "gh workflow disable ci.yml" \
         "gh api -XDELETE repos/o/r/labels/bug" \
         "gh api -X DELETE repos/o/r/labels/wont%20fix" \
         "gh api -X DELETE repos/o/r" "gh api -XDELETE /repos/o/r"; do
  check "gh destructive delete: $c -> ask" ask "$(decision_for "$(bash_cmd "$c")" "$WORK")"
done

# 18. Shell-substitution bypass guard: a would-be `allow` defers when a raw
#     token hides a command the classifier never sees (command/process
#     substitution, unrecognized operator runs). Single-quote the command so
#     the test shell doesn't expand the substitutions itself.
check "backtick cmd-subst -> none (defer)" none \
  "$(decision_for "$(bash_cmd 'git status `touch PWNED`')" "$WORK")"
check "|& operator run -> none (defer)" none \
  "$(decision_for "$(bash_cmd 'git status |& touch PWNED')" "$WORK")"
check "process-subst <( ) -> none (defer)" none \
  "$(decision_for "$(bash_cmd 'git status <(touch PWNED)')" "$WORK")"
check "process-subst >( ) -> none (defer)" none \
  "$(decision_for "$(bash_cmd 'git status >(touch PWNED)')" "$WORK")"
check 'cmd-subst in quoted arg -> none (defer)' none \
  "$(decision_for '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"$(touch PWNED)\""}}' "$WORK")"
# Subtler: substitution in a redirect TARGET. command_segments drops the
# redirect operator and its target, so the check must run over the RAW tokens.
check "cmd-subst in redirect target -> none (defer)" none \
  "$(decision_for "$(bash_cmd 'git diff > `evil`')" "$WORK")"
# Already-correct defers stay deferring (these split into a non-git segment).
check "\$(...) splits into a segment -> none (defer)" none \
  "$(decision_for "$(bash_cmd 'git status $(touch x)')" "$WORK")"
check "; separator -> none (defer)" none \
  "$(decision_for "$(bash_cmd 'git status; touch x')" "$WORK")"

# ---------------------------------------------------------------------------
# 18b. Pure-substitution registry: a quoted `$(…)` / backtick substitution whose
#      inner command is a recognized pure/read-only one (PURE_SUBSTITUTIONS)
#      does NOT drop an otherwise-auto-approvable git/gh chain to defer, while
#      any other substitution keeps deferring. Payloads are built by hand (the
#      commands carry double quotes, which bash_cmd doesn't escape) and are
#      single-quoted so the test shell never expands the substitutions.
git -C "$WORK" checkout -q claude/x
# Pure substitution inside a quoted arg -> the chain still auto-approves.
check 'gh pr view "$(git branch --show-current)" -> allow' allow \
  "$(decision_for '{"tool_name":"Bash","tool_input":{"command":"gh pr view \"$(git branch --show-current)\""}}' "$WORK")"
check 'git -C "$(git rev-parse --show-toplevel)" status -> allow' allow \
  "$(decision_for '{"tool_name":"Bash","tool_input":{"command":"git -C \"$(git rev-parse --show-toplevel)\" status"}}' "$WORK")"
check 'git log "$(pwd)" -> allow' allow \
  "$(decision_for '{"tool_name":"Bash","tool_input":{"command":"git log \"$(pwd)\""}}' "$WORK")"
# Backtick spelling and trailing literal text after the substitution both allow.
check 'git log "`pwd`" (backtick) -> allow' allow \
  "$(decision_for '{"tool_name":"Bash","tool_input":{"command":"git log \"`pwd`\""}}' "$WORK")"
check 'git -C "$(git rev-parse --show-toplevel)/sub" status -> allow' allow \
  "$(decision_for '{"tool_name":"Bash","tool_input":{"command":"git -C \"$(git rev-parse --show-toplevel)/sub\" status"}}' "$WORK")"
# A non-registry substitution still defers (only the tiny registry is exempt).
check 'git log "$(git status)" -> none (not in registry)' none \
  "$(decision_for '{"tool_name":"Bash","tool_input":{"command":"git log \"$(git status)\""}}' "$WORK")"
# An appended command, an inner redirect, or a pure+impure pair keep deferring —
# the structural match rejects anything but the exact pure command.
check 'git commit -m "$(git branch --show-current; touch PWNED)" -> none' none \
  "$(decision_for '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"$(git branch --show-current; touch PWNED)\""}}' "$WORK")"
check 'git log "$(git rev-parse --show-toplevel > f)" -> none (inner redirect)' none \
  "$(decision_for '{"tool_name":"Bash","tool_input":{"command":"git log \"$(git rev-parse --show-toplevel > f)\""}}' "$WORK")"
check 'git commit -m "$(pwd)$(touch PWNED)" -> none (pure + impure)' none \
  "$(decision_for '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"$(pwd)$(touch PWNED)\""}}' "$WORK")"
# A pure substitution never overrides a protective ask: commit on main still asks.
git -C "$WORK" checkout -q main
check 'git commit -m "$(pwd)" on main -> ask' ask \
  "$(decision_for '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"$(pwd)\""}}' "$WORK")"
git -C "$WORK" checkout -q claude/x
# A non-git segment can't ride along even with a pure substitution (cd is nongit).
check 'cd "$(git rev-parse --show-toplevel)" && git status -> none' none \
  "$(decision_for '{"tool_name":"Bash","tool_input":{"command":"cd \"$(git rev-parse --show-toplevel)\" && git status"}}' "$WORK")"

# ---------------------------------------------------------------------------
# 19. Pipe to a pure read-only filter: a recognized-safe git/gh segment piped
#     into a pager/formatter (head/tail/wc/…) stays `allow` instead of
#     deferring. A filter with a file positional, a write option, a non-filter
#     program, or no git/gh segment at all does NOT ride along.
check "git log | head -> allow" allow \
  "$(decision_for "$(bash_cmd 'git log | head')" "$WORK")"
check "gh pr checks | head -20 -> allow" allow \
  "$(decision_for "$(bash_cmd 'gh pr checks 123 | head -20')" "$WORK")"
check "git diff --stat | tail -n 5 -> allow" allow \
  "$(decision_for "$(bash_cmd 'git diff --stat | tail -n 5')" "$WORK")"
check "git log | wc -l -> allow" allow \
  "$(decision_for "$(bash_cmd 'git log | wc -l')" "$WORK")"
check "git commit | head on feature -> allow" allow \
  "$(decision_for "$(bash_cmd 'git commit -m x | head')" "$WORK")"
# Protective ask still wins over a trailing read filter.
git -C "$WORK" checkout -q main
check "git commit | head on main -> ask" ask \
  "$(decision_for "$(bash_cmd 'git commit -m x | head')" "$WORK")"
git -C "$WORK" checkout -q claude/x
# A read filter alone (no git/gh segment) keeps deferring.
check "head -5 (no git) -> none" none \
  "$(decision_for "$(bash_cmd 'head -5')" "$WORK")"
check "cat somefile (no git) -> none" none \
  "$(decision_for "$(bash_cmd 'cat somefile')" "$WORK")"
# A filter with a file positional reads a file (workspace-guard's domain) -> defer.
check "git log | cat file.txt -> none" none \
  "$(decision_for "$(bash_cmd 'git log | cat file.txt')" "$WORK")"
check "git log | sort big.txt -> none" none \
  "$(decision_for "$(bash_cmd 'git log | sort big.txt')" "$WORK")"
# A filter that can WRITE never rides along.
check "git log | sort -o out -> none" none \
  "$(decision_for "$(bash_cmd 'git log | sort -o out')" "$WORK")"
check "git log | sort -oout (attached) -> none" none \
  "$(decision_for "$(bash_cmd 'git log | sort -oout')" "$WORK")"
check "git log | sed -i s/a/b/ file -> none" none \
  "$(decision_for "$(bash_cmd 'git log | sed -i s/a/b/ file')" "$WORK")"
check "git status | tee out -> none" none \
  "$(decision_for "$(bash_cmd 'git status | tee out')" "$WORK")"
# A trailing non-filter command after a filter still can't ride along.
check "git log | head; rm -rf x -> none" none \
  "$(decision_for "$(bash_cmd 'git log | head ; rm -rf x')" "$WORK")"

# ---------------------------------------------------------------------------
# 20. fd redirects (`2>&1`, `2>/dev/null`, `1>out`). shlex lexes `2>&1` as the
#     three tokens `2`, `>&`, `1`; the segmenter must recognize `>&`/`<&` as
#     redirect operators AND drop the single-digit fd prefix, so the redirect
#     isn't read as command positionals (the bug: `2` looked like a refspec).
check "git push origin HEAD 2>&1 | tail -5 -> allow" allow \
  "$(decision_for "$(bash_cmd 'git push -u origin HEAD 2>&1 | tail -5')" "$WORK")"
check "git status 2>&1 -> allow" allow \
  "$(decision_for "$(bash_cmd 'git status 2>&1')" "$WORK")"
check "git log 2>/dev/null -> allow" allow \
  "$(decision_for "$(bash_cmd 'git log 2>/dev/null')" "$WORK")"
# A real-file target (not /dev/null or an fd dup) is a write side-effect: the
# single-digit fd prefix is still dropped, but the would-be allow is downgraded
# to defer by the redirect-write awareness (see section 21).
check "git log 1>out 2>err -> none (writes real files)" none \
  "$(decision_for "$(bash_cmd 'git log 1>out 2>err')" "$WORK")"
# `>&2` with no fd prefix means redirect stdout to stderr — no positional dropped.
check "git push origin HEAD >&2 -> allow" allow \
  "$(decision_for "$(bash_cmd 'git push origin HEAD >&2')" "$WORK")"
# A multi-digit numeric branch name is NOT an fd prefix; it stays a refspec, so
# pushing it (not the worktree branch) still asks under the strict policy.
check "git push origin 123 >log (branch, not fd) -> ask" ask \
  "$(decision_for "$(bash_cmd 'git push origin 123 >log')" "$WORK")"
# `&>`/`&>>` can't take an fd prefix in bash, so a single digit before them is a
# real argument (refspec), not an fd — pushing branch `2` still asks.
check "git push origin 2 &>log (branch, not fd) -> ask" ask \
  "$(decision_for "$(bash_cmd 'git push origin 2 &>log')" "$WORK")"
# But a single-digit fd before an fd-accepting operator IS dropped (&>1 here is
# the &> redirect to a file named 1; the redirect to /dev/null is the common form).
check "git log &>/dev/null -> allow" allow \
  "$(decision_for "$(bash_cmd 'git log &>/dev/null')" "$WORK")"
# A redirect doesn't weaken a protective ask.
check "git push origin main 2>&1 -> ask" ask \
  "$(decision_for "$(bash_cmd 'git push origin main 2>&1')" "$WORK")"
check "git clean -fd 2>&1 -> ask" ask \
  "$(decision_for "$(bash_cmd 'git clean -fd 2>&1')" "$WORK")"

# ---------------------------------------------------------------------------
# 21. Redirect-write awareness (hardening). An output redirect to a real FILE is
#     a write side-effect the classifier can't see (`git log --format=… > f`
#     writes possibly-attacker-influenced content), so a would-be `allow` is
#     downgraded to defer. Redirects to /dev/null or a standard stream, and fd
#     duplications (`2>&1`), create no file and keep allowing.
check "git log > realfile -> none (write downgrade)" none \
  "$(decision_for "$(bash_cmd 'git log > out.txt')" "$WORK")"
check "git diff >> realfile -> none (write downgrade)" none \
  "$(decision_for "$(bash_cmd 'git diff >> out.txt')" "$WORK")"
check "git log --format > realfile -> none (the write primitive)" none \
  "$(decision_for "$(bash_cmd 'git log --format=%s -1 > pwned')" "$WORK")"
check "git status 2>realfile -> none (stderr to file)" none \
  "$(decision_for "$(bash_cmd 'git status 2>err.txt')" "$WORK")"
# Discard / standard-stream targets create no file -> still allow.
check "git log >/dev/null -> allow" allow \
  "$(decision_for "$(bash_cmd 'git log >/dev/null')" "$WORK")"
check "git log >/dev/stdout -> allow" allow \
  "$(decision_for "$(bash_cmd 'git log >/dev/stdout')" "$WORK")"
# A file-writing redirect must NOT weaken a protective ask.
check "git clean -fd > out -> ask (write doesn't weaken ask)" ask \
  "$(decision_for "$(bash_cmd 'git clean -fd > out.txt')" "$WORK")"
# A bare redirect with no command writes a file -> it blocks the chain.
check "> out ; git status -> none (bare write blocks)" none \
  "$(decision_for "$(bash_cmd '> out.txt ; git status')" "$WORK")"

# ---------------------------------------------------------------------------
# 22. Benign label/no-op segments (echo/printf/true/false/:). With no
#     file-writing redirect and no shell substitution these are side-effect-free
#     (stdout / exit status only), so one may ride along after a recognized-safe
#     git/gh segment — keeping an all-git chain with a label line auto-approved.
check 'git log ; echo label ; git status -> allow' allow \
  "$(decision_for '{"tool_name":"Bash","tool_input":{"command":"git log --oneline -1 ; echo \"---\" ; git status"}}' "$WORK")"
check "git status && echo done -> allow" allow \
  "$(decision_for "$(bash_cmd 'git status && echo done')" "$WORK")"
check "git status ; printf -> allow" allow \
  "$(decision_for "$(bash_cmd 'git status ; printf hello')" "$WORK")"
check "git status ; true -> allow" allow \
  "$(decision_for "$(bash_cmd 'git status ; true')" "$WORK")"
check "git status ; : -> allow" allow \
  "$(decision_for "$(bash_cmd 'git status ; :')" "$WORK")"
check "git fetch || echo failed -> allow" allow \
  "$(decision_for "$(bash_cmd 'git fetch || echo failed')" "$WORK")"
# A benign-only command (no git/gh segment) still defers.
check "echo hi (no git) -> none" none \
  "$(decision_for "$(bash_cmd 'echo hi')" "$WORK")"
check "echo hi ; true (no git) -> none" none \
  "$(decision_for "$(bash_cmd 'echo hi ; true')" "$WORK")"
# An echo that writes a file is NOT benign (redirect) -> defer.
check "git status ; echo evil > f -> none (echo write)" none \
  "$(decision_for "$(bash_cmd 'git status ; echo evil > pwned')" "$WORK")"
# echo to /dev/null is harmless and rides along.
check "git status ; echo x >/dev/null -> allow" allow \
  "$(decision_for "$(bash_cmd 'git status ; echo x >/dev/null')" "$WORK")"
# Substitution inside a benign segment still downgrades the whole command.
check 'git status ; echo $(rm) -> none (subst)' none \
  "$(decision_for "$(bash_cmd 'git status ; echo $(rm -rf x)')" "$WORK")"
# A real non-git command still can't ride along behind a benign one.
check "git status && echo done && rm -rf foo -> none" none \
  "$(decision_for "$(bash_cmd 'git status && echo done && rm -rf foo')" "$WORK")"
# A benign segment must NOT weaken a protective ask.
check "git clean -fd ; echo done -> ask" ask \
  "$(decision_for "$(bash_cmd 'git clean -fd ; echo done')" "$WORK")"

# ---------------------------------------------------------------------------
# 23. Heredoc bodies are treated as opaque data, not command segments. A body
#     (a quoted delimiter is always inert; an unquoted one with no substitution)
#     is dropped before lexing, so an all-git chain wrapping a heredoc stays
#     auto-approved instead of deferring on the body's foreign-looking lines.
#     The operator line and anything after the terminator still classify.
git -C "$WORK" checkout -q claude/x
# A quoted-delimiter body whose lines look like foreign segments (&&/;/rm) is
# inert data -> the commit auto-approves.
check "commit + quoted heredoc (foreign-looking body) -> allow" allow \
  "$(decision_for "$(bash_payload "$(printf 'git commit -F- <<'"'"'EOF'"'"'\nfeat: x\n\n- a && b ; rm -rf /\nEOF')")" "$WORK")"
# An unquoted delimiter with a plain body (no expansion vectors) also strips.
check "commit + unquoted heredoc (plain body) -> allow" allow \
  "$(decision_for "$(bash_payload "$(printf 'git commit -F- <<EOF\nfeat: x\nEOF')")" "$WORK")"
# A <<- heredoc with a tab-indented terminator strips too.
check "commit + <<- heredoc (indented terminator) -> allow" allow \
  "$(decision_for "$(bash_payload "$(printf 'git commit -F- <<-'"'"'EOF'"'"'\n\tbody\n\tEOF')")" "$WORK")"
# A command after the terminator still classifies: a push to main asks.
check "heredoc body then push origin main -> ask" ask \
  "$(decision_for "$(bash_payload "$(printf 'git commit -F- <<'"'"'EOF'"'"'\nmsg\nEOF\ngit push origin main')")" "$WORK")"
# A real trailing command after the terminator can't ride along -> defer.
check "heredoc body then rm -> none" none \
  "$(decision_for "$(bash_payload "$(printf 'git commit -F- <<'"'"'EOF'"'"'\nmsg\nEOF\nrm -rf foo')")" "$WORK")"
# SECURITY: an UNQUOTED body with a command substitution the shell would run is
# NOT stripped (left in the stream) -> the substitution guard defers.
check "unquoted heredoc body with substitution -> none (defer)" none \
  "$(decision_for "$(bash_payload "$(printf 'git commit -F- <<EOF\n$(touch PWNED)\nEOF')")" "$WORK")"
# A QUOTED delimiter suppresses expansion, so the same body is inert -> allow.
check "quoted heredoc body with substitution (inert) -> allow" allow \
  "$(decision_for "$(bash_payload "$(printf 'git commit -F- <<'"'"'EOF'"'"'\n$(touch PWNED)\nEOF')")" "$WORK")"
# A heredoc feeding a NON-git command (body full of git-looking text) has no
# git/gh segment once stripped -> defer (no false-positive prompt).
check "cat heredoc with git-looking body -> none (defer)" none \
  "$(decision_for "$(bash_payload "$(printf 'cat <<'"'"'EOF'"'"'\ngit push origin main\nEOF')")" "$WORK")"
# An unterminated heredoc is left unchanged (fail safe): the body lexes and the
# chain defers rather than silently allowing.
check "unterminated heredoc -> none (defer)" none \
  "$(decision_for "$(bash_payload "$(printf 'git commit -F- <<EOF\nbody with no terminator line')")" "$WORK")"
# A commit wrapping a heredoc on main still asks (protected branch).
git -C "$WORK" checkout -q main
check "commit + heredoc on main -> ask" ask \
  "$(decision_for "$(bash_payload "$(printf 'git commit -F- <<'"'"'EOF'"'"'\nmsg\nEOF')")" "$WORK")"
git -C "$WORK" checkout -q claude/x

# 24. `git branch` scoped to what the session owns, not to the verb. A target is
#     in bounds when it is recoverable (tip reachable from a remote-tracking ref
#     or main) and private (not protected). The probes can only ever relax a
#     would-be `ask` into an `allow`, so every case they can't answer for --
#     a branch that doesn't exist, a foreign repo -- keeps asking.
#
#     Fixture branches: `merged` sits at main's tip (recoverable via
#     refs/heads/main); `orphan` carries a commit reachable from nothing else.
git -C "$WORK" branch merged
git -C "$WORK" checkout -q -b orphan
git -C "$WORK" commit -q --allow-empty -m "unreachable work"
git -C "$WORK" checkout -q claude/x

#     `pushed` carries a commit main can't reach, recoverable only because a
#     remote-tracking ref holds it — the case the whole model turns on, and the
#     one a repo with no remote would otherwise never exercise.
git -C "$WORK" checkout -q -b pushed
git -C "$WORK" commit -q --allow-empty -m "work that survives on the remote"
git -C "$WORK" update-ref refs/remotes/origin/pushed \
  "$(git -C "$WORK" rev-parse pushed)"
git -C "$WORK" checkout -q claude/x

#     Non-force spellings need no probe: git enforces the same check itself.
check "git branch -d (git refuses unmerged) -> allow" allow \
  "$(decision_for "$(bash_cmd 'git branch -d merged')" "$WORK")"
check "git branch -d on an unmerged branch -> allow (git refuses it)" allow \
  "$(decision_for "$(bash_cmd 'git branch -d orphan')" "$WORK")"

#     Shared and recoverable are INDEPENDENT questions, and git only enforces
#     the second one. `-d` can't orphan commits, but it still drops the local
#     ref, so a protected target asks either way. This crossing -- a non-force
#     spelling against a protected branch -- is the gap that let `git branch -d
#     main` auto-approve: every protected assertion used a force spelling, and
#     every non-force case named an unprotected branch.
check "git branch -d protected -> ask" ask \
  "$(decision_for "$(bash_cmd 'git branch -d main')" "$WORK")"
check "git branch --delete protected -> ask" ask \
  "$(decision_for "$(bash_cmd 'git branch --delete main')" "$WORK")"
#     Same for a branch protected only by configuration -- otherwise the
#     BRANCH_GUARD_PROTECTED_BRANCHES set is bypassable by lowercasing a flag.
#     The unset control is what makes the pair mean anything: without it the
#     `ask` below could come from anywhere, and a `-d` that asked unconditionally
#     would pass too.
check "[unset] git branch -d release/1.2 -> allow" allow \
  "$(decision_for "$(bash_cmd 'git branch -d release/1.2')" "$WORK")"
check "[configured] git branch -d release/1.2 -> ask" ask \
  "$(decision_for "$(bash_cmd 'git branch -d release/1.2')" "$WORK" \
     'BRANCH_GUARD_PROTECTED_BRANCHES=release/*')"
#     The same crossing on every remaining verb. `-d`/`-D`/`-m`/`-f` had it;
#     `-M`, `-c`, and `-C` did not, so three of the seven forms that can name a
#     protected target were asserted nowhere. One shared check covers them all
#     now, and these pin that it does -- a per-verb check is what let the
#     orderings drift apart in the first place.
check "git branch -m onto protected (non-force) -> ask" ask \
  "$(decision_for "$(bash_cmd 'git branch -m merged main')" "$WORK")"
check "git branch -M onto protected (force move) -> ask" ask \
  "$(decision_for "$(bash_cmd 'git branch -M merged main')" "$WORK")"
check "git branch -c onto protected (copy) -> ask" ask \
  "$(decision_for "$(bash_cmd 'git branch -c merged main')" "$WORK")"
check "git branch -C onto protected (force copy) -> ask" ask \
  "$(decision_for "$(bash_cmd 'git branch -C merged main')" "$WORK")"
check "git branch -m rename -> allow" allow \
  "$(decision_for "$(bash_cmd 'git branch -m orphan renamed')" "$WORK")"
check "git branch -c copy -> allow" allow \
  "$(decision_for "$(bash_cmd 'git branch -c orphan copy')" "$WORK")"

#     Force delete: recoverable target allows, orphaning target asks.
check "git branch -D recoverable -> allow" allow \
  "$(decision_for "$(bash_cmd 'git branch -D merged')" "$WORK")"
check "git branch -D irrecoverable -> ask" ask \
  "$(decision_for "$(bash_cmd 'git branch -D orphan')" "$WORK")"
check "git branch -D of several, one irrecoverable -> ask" ask \
  "$(decision_for "$(bash_cmd 'git branch -D merged orphan')" "$WORK")"
check "git branch -D protected -> ask" ask \
  "$(decision_for "$(bash_cmd 'git branch -D main')" "$WORK")"
#     Unreachable from main, but the remote still has it.
check "git branch -D recoverable via remote-tracking ref -> allow" allow \
  "$(decision_for "$(bash_cmd 'git branch -D pushed')" "$WORK")"
#     `-r` deletes the local cache of a remote ref; a fetch restores it.
check "git branch -rD remote-tracking ref -> allow" allow \
  "$(decision_for "$(bash_cmd 'git branch -rD origin/pushed')" "$WORK")"
#     `-d --force` is `-D` spelled long, so force must be read from the whole
#     flag set -- reading only the letter `d` would auto-approve a real delete.
check "git branch -d --force irrecoverable -> ask" ask \
  "$(decision_for "$(bash_cmd 'git branch -d --force orphan')" "$WORK")"
check "git branch --delete --force recoverable -> allow" allow \
  "$(decision_for "$(bash_cmd 'git branch --delete --force merged')" "$WORK")"

#     Force move/copy: creating a new ref loses nothing; moving an existing one
#     depends on whether its CURRENT tip survives elsewhere.
check "git branch -f creating a backup ref -> allow" allow \
  "$(decision_for "$(bash_cmd 'git branch -f backup claude/x')" "$WORK")"
check "git branch -f onto a recoverable branch -> allow" allow \
  "$(decision_for "$(bash_cmd 'git branch -f merged main')" "$WORK")"
check "git branch -f onto an irrecoverable branch -> ask" ask \
  "$(decision_for "$(bash_cmd 'git branch -f orphan main')" "$WORK")"
check "git branch -f protected -> ask" ask \
  "$(decision_for "$(bash_cmd 'git branch -f main claude/x')" "$WORK")"
check "git branch -M onto a new name -> allow" allow \
  "$(decision_for "$(bash_cmd 'git branch -M merged brand-new')" "$WORK")"
check "git branch -M onto an irrecoverable branch -> ask" ask \
  "$(decision_for "$(bash_cmd 'git branch -M merged orphan')" "$WORK")"
check "git branch -m from protected -> ask" ask \
  "$(decision_for "$(bash_cmd 'git branch -m main renamed')" "$WORK")"
check "git branch -C onto an irrecoverable branch -> ask" ask \
  "$(decision_for "$(bash_cmd 'git branch -C merged orphan')" "$WORK")"

#     Unprovable cases keep today's `ask`: a branch that doesn't exist can't be
#     shown recoverable, and a `-C` global points the command at another repo
#     than the one the probes read.
check "git branch -D nonexistent -> ask" ask \
  "$(decision_for "$(bash_cmd 'git branch -D no-such-branch')" "$WORK")"
check "git -C other-repo branch -D -> ask" ask \
  "$(decision_for "$(bash_cmd 'git -C /somewhere/else branch -D merged')" "$WORK")"

#     Listing is untouched, and the unattended fail-safe still applies.
check "git branch --list -> allow" allow \
  "$(decision_for "$(bash_cmd 'git branch -a -v')" "$WORK")"
check "[auto] git branch -D irrecoverable -> deny" deny \
  "$(decision_for "$(push_mode 'git branch -D orphan' 'auto')" "$WORK")"

#     Wording: the reason has to say what is actually happening. `git branch -f`
#     creating a ref was reported as "Deleting/renaming a git branch", which is
#     the opposite of the truth and invites approving for the wrong reason.
branch_reason="$(reason_for "$(bash_cmd 'git branch -f orphan main')" "$WORK")"
check_text "branch -f reason names the move, not a delete" has \
  "moves existing branch 'orphan'" "$branch_reason"
check_text "branch -f reason drops the old delete/rename wording" lacks \
  "Deleting/renaming" "$branch_reason"
check_text "branch -f ask still invites a confirmation" has \
  "confirm before proceeding" "$branch_reason"
del_reason="$(reason_for "$(bash_cmd 'git branch -D orphan')" "$WORK")"
check_text "branch -D reason says why it isn't recoverable" has \
  "isn't reachable from any remote-tracking branch or main" "$del_reason"

# 25. The protected set is configurable at runtime via
#     BRANCH_GUARD_PROTECTED_BRANCHES (comma-separated globs), the same way the
#     push policy is. It EXTENDS main/master rather than replacing them, so no
#     value — however garbled — can unprotect the defaults.
git -C "$WORK" branch release/1.2
git -C "$WORK" branch release/2.0/rc
git -C "$WORK" branch integration
BR='BRANCH_GUARD_PROTECTED_BRANCHES=release/*,integration'

# Unset, a release branch is an ordinary feature branch: this is the behavior
# that used to need an edit to the hook file to change.
git -C "$WORK" checkout -q release/1.2
check "[unset] commit on release/1.2 -> allow" allow \
  "$(decision_for "$(bash_cmd 'git commit -m x')" "$WORK")"
check "[configured] commit on release/1.2 -> ask" ask \
  "$(decision_for "$(bash_cmd 'git commit -m x')" "$WORK" "$BR")"
check_text "[configured] reason names the configured branch" has \
  "Targets protected branch 'release/1.2'" \
  "$(reason_for "$(bash_cmd 'git commit -m x')" "$WORK" "$BR")"
# fnmatch's `*` spans `/`, so one `release/*` entry covers nested release refs.
git -C "$WORK" checkout -q release/2.0/rc
check "[configured] commit on release/2.0/rc -> ask" ask \
  "$(decision_for "$(bash_cmd 'git commit -m x')" "$WORK" "$BR")"
# A glob-free entry protects exactly that branch, and matching is
# case-sensitive (fnmatchcase), like git's own branch names.
git -C "$WORK" checkout -q integration
check "[configured] commit on integration -> ask" ask \
  "$(decision_for "$(bash_cmd 'git commit -m x')" "$WORK" "$BR")"
check "[configured] pattern 'Integration' doesn't match 'integration' -> allow" allow \
  "$(decision_for "$(bash_cmd 'git commit -m x')" "$WORK" \
     'BRANCH_GUARD_PROTECTED_BRANCHES=Integration')"
# Extend-only: the defaults survive a config that never mentions them, and a
# branch matching no pattern is unaffected.
git -C "$WORK" checkout -q main
check "[configured] commit on main still -> ask" ask \
  "$(decision_for "$(bash_cmd 'git commit -m x')" "$WORK" "$BR")"
git -C "$WORK" checkout -q claude/x
check "[configured] commit on claude/x -> allow" allow \
  "$(decision_for "$(bash_cmd 'git commit -m x')" "$WORK" "$BR")"
# Garbled input (empty and whitespace-only entries) fails safe to the defaults
# rather than protecting nothing.
git -C "$WORK" checkout -q main
check "[garbled] commit on main still -> ask" ask \
  "$(decision_for "$(bash_cmd 'git commit -m x')" "$WORK" \
     'BRANCH_GUARD_PROTECTED_BRANCHES=  , ,')"
git -C "$WORK" checkout -q claude/x
check "[garbled] commit on claude/x -> allow" allow \
  "$(decision_for "$(bash_cmd 'git commit -m x')" "$WORK" \
     'BRANCH_GUARD_PROTECTED_BRANCHES=  , ,')"
# The edit path and the push guard's protected-target check read the same set.
git -C "$WORK" checkout -q release/1.2
check "[configured] edit of a file on release/1.2 -> ask" ask \
  "$(decision_for "$(edit_payload Edit file_path "$WORK/file.txt")" "$WORK" "$BR")"
git -C "$WORK" checkout -q claude/x
check "[protected] push origin release/1.2 -> none (unset)" none \
  "$(decision_for "$(push 'git push origin release/1.2')" "$WORK" "$PROT")"
check "[protected+configured] push origin release/1.2 -> ask" ask \
  "$(decision_for "$(push 'git push origin release/1.2')" "$WORK" "$PROT" "$BR")"
# And a configured ask still becomes a deny where no human can answer.
check "[protected+configured][auto] push origin integration -> deny" deny \
  "$(decision_for "$(push_mode 'git push origin integration' 'auto')" "$WORK" "$PROT" "$BR")"

# `git branch`'s ownership tier (section 24) calls a target in bounds only when
# it is recoverable AND private, and reads "private" from `is_protected` — so
# configuring a branch withdraws that auto-approve too. release/1.2 sits at
# main's tip, so it stays recoverable throughout and only privacy moves.
check "[unset] branch -D release/1.2 -> allow (recoverable and private)" allow \
  "$(decision_for "$(bash_cmd 'git branch -D release/1.2')" "$WORK")"
check "[configured] branch -D release/1.2 -> ask (no longer private)" ask \
  "$(decision_for "$(bash_cmd 'git branch -D release/1.2')" "$WORK" "$BR")"

# The lease-scoped cross-name push (section 7b) reads "shared" from the same
# set, so configuring the destination withdraws that auto-approve too — a lease
# proves the remote hasn't moved, never that the branch is the session's alone.
check "[unset] leased rewrite of release/1.2 -> allow" allow \
  "$(decision_for "$(push 'git push --force-with-lease=release/1.2 origin HEAD:release/1.2')" "$WORK")"
check "[configured] leased rewrite of release/1.2 -> ask" ask \
  "$(decision_for "$(push 'git push --force-with-lease=release/1.2 origin HEAD:release/1.2')" "$WORK" "$BR")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"

# A FLOOR, not an exact count. The suite used to assert its own size against a
# number written in CLAUDE.md, which had two problems. It raced: the size is a
# global property but every branch validated it against its own base, so two
# fixture-adding PRs that each bumped correctly left main wrong by the second
# one's delta -- which is exactly how main went red at 316-documented-as-310.
# And it never checked the property it was advertised as defending: a fixture
# invoking the interpreter directly would increment the count and pass.
#
# The floor keeps the one thing the count genuinely caught -- a suite that
# silently collapses, because setup failed or a section exited early -- while
# conflicting with nobody. Raise it when the suite grows a lot; nothing breaks
# if it lags.
CASE_FLOOR=280
counts_ok=1
if [[ $((pass + fail)) -lt "$CASE_FLOOR" ]]; then
  printf 'suite ran %d cases, under the floor of %d — did setup fail, or a section exit early?\n' \
    "$((pass + fail))" "$CASE_FLOOR" >&2
  counts_ok=0
fi

[[ "$fail" -eq 0 && "$counts_ok" -eq 1 ]]
