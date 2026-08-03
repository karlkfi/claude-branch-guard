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

# Keep tests hermetic regardless of the caller's shell.
unset BRANCH_GUARD_PUSH_POLICY

pass=0
fail=0

cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

setup_repo() {
  rm -rf "$WORK"
  mkdir -p "$WORK"
  git -C "$WORK" init -q -b main
  git -C "$WORK" config user.name "Test"
  git -C "$WORK" config user.email "test@example.com"
  printf 'hello\n' > "$WORK/file.txt"
  git -C "$WORK" add -A
  git -C "$WORK" commit -q -m "init"
  git -C "$WORK" branch claude/x
}

# decision_for PAYLOAD CWD [ENV_KV] -> echoes the permissionDecision, or "none".
# ENV_KV is an optional `NAME=value` passed into the hook's environment.
decision_for() {
  local payload="$1" cwd="$2" env_kv="${3:-}" out
  out="$( cd "$cwd" && printf '%s' "$payload" | env ${env_kv} "$LAUNCHER" "$HOOK_SCRIPT" )"
  if [[ -z "$out" ]]; then
    printf 'none'
  else
    printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision'
  fi
}

# reason_for PAYLOAD CWD [ENV_KV] -> echoes the permissionDecisionReason, or "".
reason_for() {
  local payload="$1" cwd="$2" env_kv="${3:-}" out
  out="$( cd "$cwd" && printf '%s' "$payload" | env ${env_kv} "$LAUNCHER" "$HOOK_SCRIPT" )"
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
git -C "$WORK" checkout -q claude/x

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
check "git reset --hard -> ask" ask \
  "$(decision_for "$(bash_cmd 'git reset --hard HEAD~1')" "$WORK")"
check "git reset --soft -> none (defer)" none \
  "$(decision_for "$(bash_cmd 'git reset --soft HEAD~1')" "$WORK")"
check "git clean -fd -> ask" ask \
  "$(decision_for "$(bash_cmd 'git clean -fd')" "$WORK")"
check "git branch -D -> ask" ask \
  "$(decision_for "$(bash_cmd 'git branch -D old')" "$WORK")"
check "git restore (worktree) -> ask" ask \
  "$(decision_for "$(bash_cmd 'git restore file.txt')" "$WORK")"
check "git worktree remove -> ask" ask \
  "$(decision_for "$(bash_cmd 'git worktree remove ../wt')" "$WORK")"
check "git config --global -> ask" ask \
  "$(decision_for "$(bash_cmd 'git config --global user.name x')" "$WORK")"
check "git stash drop -> ask" ask \
  "$(decision_for "$(bash_cmd 'git stash drop')" "$WORK")"
check "readonly + destructive chain -> ask" ask \
  "$(decision_for "$(bash_cmd 'git status && git reset --hard')" "$WORK")"
check "[auto] git reset --hard -> deny" deny \
  "$(decision_for "$(push_mode 'git reset --hard' 'auto')" "$WORK")"

# 15. Branch-sensitive mutations: feature -> allow, protected -> ask.
check "git rebase on feature -> allow" allow \
  "$(decision_for "$(bash_cmd 'git rebase origin/main')" "$WORK")"
check "git merge on feature -> allow" allow \
  "$(decision_for "$(bash_cmd 'git merge feature-y')" "$WORK")"
check "git rebase --abort -> allow" allow \
  "$(decision_for "$(bash_cmd 'git rebase --abort')" "$WORK")"
check "git pull --ff-only -> allow" allow \
  "$(decision_for "$(bash_cmd 'git pull --ff-only')" "$WORK")"
check "git pull (non-ff) -> ask" ask \
  "$(decision_for "$(bash_cmd 'git pull')" "$WORK")"
git -C "$WORK" checkout -q main
check "git rebase on main -> ask" ask \
  "$(decision_for "$(bash_cmd 'git rebase origin/main')" "$WORK")"
check "git merge on main -> ask" ask \
  "$(decision_for "$(bash_cmd 'git merge feature-y')" "$WORK")"
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
for c in "gh api -X DELETE repos/o/r/git/refs/heads/feature-x" \
         "gh api -XDELETE repos/o/r/git/refs/heads/main" \
         "gh api --method DELETE repos/o/r/git/refs/tags/v1" \
         "gh pr merge 5 --delete-branch" "gh pr merge 5 -d" \
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
check "git reset --hard 2>&1 -> ask" ask \
  "$(decision_for "$(bash_cmd 'git reset --hard 2>&1')" "$WORK")"

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
check "git reset --hard > out -> ask (write doesn't weaken ask)" ask \
  "$(decision_for "$(bash_cmd 'git reset --hard > out.txt')" "$WORK")"
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
check "git reset --hard ; echo done -> ask" ask \
  "$(decision_for "$(bash_cmd 'git reset --hard ; echo done')" "$WORK")"

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

printf '\n%d passed, %d failed\n' "$pass" "$fail"

# CLAUDE.md backs its launcher-coverage claim with this suite's case count.
# That number is prose, so nothing stopped a fixture from landing and leaving
# it stale -- it had drifted by three before anyone noticed. Assert it here
# rather than in CI: a case count is only knowable by running the suite, and
# the suite already runs on every job. This check is not itself a fixture, so
# it does not perturb the number it is checking.
counts_ok=1
if [[ -f "$REPO_ROOT/CLAUDE.md" ]]; then
  documented="$(grep -oE 'covered by all [0-9]+ cases' "$REPO_ROOT/CLAUDE.md" \
    | grep -oE '[0-9]+' || true)"
  if [[ -z "$documented" ]]; then
    printf 'CLAUDE.md no longer states a case count; update it or this check\n' >&2
    counts_ok=0
  elif [[ "$documented" -ne $((pass + fail)) ]]; then
    printf 'CLAUDE.md says %s cases, this run had %d\n' \
      "$documented" "$((pass + fail))" >&2
    counts_ok=0
  fi
fi

[[ "$fail" -eq 0 && "$counts_ok" -eq 1 ]]
