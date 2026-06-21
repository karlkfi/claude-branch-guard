#!/usr/bin/env bash
#
# Pipe-tests for hooks/branch-guard.py. Spins up a throwaway git repo under
# tmp/, exercises each tool/branch combination, and asserts the emitted
# permissionDecision. Requires python3, jq, and git on PATH.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/hooks/branch-guard.py"

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
  out="$( cd "$cwd" && printf '%s' "$payload" | env ${env_kv} python3 "$HOOK" )"
  if [[ -z "$out" ]]; then
    printf 'none'
  else
    printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision'
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

setup_repo

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
check "env-prefixed commit on main -> ask" ask \
  "$(decision_for "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"GIT_AUTHOR_NAME=x git -C $WORK commit -m y\"}}" "$WORK")"

# 3f. `git log` is read-only (the `commit` substring is not a commit invocation).
check "git log --grep=commit -> allow" allow \
  "$(decision_for '{"tool_name":"Bash","tool_input":{"command":"git log --grep=commit"}}' "$WORK")"

# 4. edit of a file whose repo is on main -> ask
git -C "$WORK" checkout -q main
check "edit on main -> ask" ask \
  "$(decision_for "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$WORK/file.txt\"}}" "$REPO_ROOT")"

# 5. edit of a file whose repo is on a non-protected branch -> no decision
git -C "$WORK" checkout -q claude/x
check "write on claude/x -> none" none \
  "$(decision_for "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$WORK/file.txt\"}}" "$REPO_ROOT")"

# 5b. NotebookEdit (path comes in as `notebook_path`) is guarded like the other
#     edit tools: ask on main, defer on a feature branch.
git -C "$WORK" checkout -q main
check "notebook edit on main -> ask" ask \
  "$(decision_for "{\"tool_name\":\"NotebookEdit\",\"tool_input\":{\"notebook_path\":\"$WORK/file.txt\"}}" "$REPO_ROOT")"
git -C "$WORK" checkout -q claude/x
check "notebook edit on claude/x -> none" none \
  "$(decision_for "{\"tool_name\":\"NotebookEdit\",\"tool_input\":{\"notebook_path\":\"$WORK/file.txt\"}}" "$REPO_ROOT")"

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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
