#!/usr/bin/env python3
"""branch-guard: a Claude Code PreToolUse hook.

Reduces git/branch-related approval prompts while keeping a human in the loop
for anything that touches a protected branch (main/master) or is destructive.
For Bash `git`/`gh` commands it emits a per-command decision:

  allow  — safe to auto-approve (read-only git/gh, staging, branch creation,
           fetch, a commit/push of a feature/worktree branch, …);
  ask    — confirm first (commit/edit/push to a protected branch, or a
           destructive command like `reset --hard`, `clean -f`, `branch -D`);
  (none) — defer: emit nothing, so the normal permission flow applies.

A command is auto-approved only when EVERY segment in it is a recognized-safe
git/gh invocation, so a non-git command can't ride along into an approval
(`git status && rm -rf foo` defers rather than allows).

Also guards file edits (Edit/Write/MultiEdit/NotebookEdit) against the branch of
the file's own repository, and `git push` according to BRANCH_GUARD_PUSH_POLICY.

Reads the hook JSON on stdin, emits a PreToolUse decision on stdout. On any
parsing uncertainty (unbalanced quotes, empty input, unresolvable branch,
unknown subcommand) it defers silently so normal permissions apply — never
fail closed.

In a non-interactive permission mode (auto / dontAsk / bypassPermissions) there
is no human to answer a prompt, so a would-be `ask` is emitted as `deny`
instead — the guard fails safe. (`bypassPermissions` ignores hook decisions
entirely, but emitting `deny` there is harmless and future-proof.)

Scope note: branch-guard reasons about git/branch *semantics*. The filesystem
boundary (commands touching paths outside the workspace) is workspace-guard's
job; the two don't overlap.
"""
import sys, os, json, re, shlex, subprocess

PROTECTED_BRANCH_RE = re.compile(r'^(main|master)$')

# POSIX command-prefix assignment (`FOO=bar git commit`): NAME then `=`.
# Bash treats leading assignments as inline env exports; they don't change
# the command name lookup.
ASSIGNMENT_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*=')

# Operator-run tokens that separate one simple command from the next.
SEPARATORS = {'|', '||', '&&', '&', ';', '\n', '(', ')'}
# Redirect operators; the following token is a target, not part of a command.
REDIR = {'>', '>>', '<', '<<', '<<<', '>|', '&>', '&>>'}
# Every char shlex treats as punctuation (matches the tokenizer below).
PUNCT_CHARS = frozenset(';()<>|&\n')

# git global options that consume a separate following value token (so the
# subcommand isn't mistaken for the value). `--opt=value` forms are a single
# token and need no entry here.
GIT_VALUE_OPTS = {
    '-C', '-c', '--git-dir', '--work-tree', '--namespace',
    '--super-prefix', '--config-env', '--exec-path',
}
# gh global options that consume a following value token.
GH_VALUE_OPTS = {'-R', '--repo'}

# git global flags that let an otherwise-safe command run arbitrary code via
# inline config (`git -c core.pager='!sh -c …' log`). Their presence blocks
# auto-allow (the command defers) but never suppresses an `ask`.
GIT_ESCAPE_HATCHES = {'-c', '--config-env'}

# Read-only git subcommands — auto-allowed on any branch.
READONLY_GIT = frozenset({
    'status', 'diff', 'log', 'show', 'blame', 'describe', 'shortlog',
    'whatchanged', 'ls-files', 'ls-tree', 'cat-file', 'rev-parse', 'rev-list',
    'merge-base', 'name-rev', 'show-branch', 'for-each-ref', 'cherry',
    'diff-tree', 'diff-index', 'count-objects', 'var', 'version', 'help',
    'grep', 'fetch', 'ls-remote',
})

# Read-only gh (subcommand, sub-subcommand) pairs — auto-allowed.
READONLY_GH = frozenset({
    ('pr', 'view'), ('pr', 'list'), ('pr', 'status'), ('pr', 'diff'), ('pr', 'checks'),
    ('issue', 'view'), ('issue', 'list'), ('issue', 'status'),
    ('repo', 'view'),
    ('run', 'view'), ('run', 'list'),
    ('release', 'view'), ('release', 'list'),
    ('workflow', 'view'), ('workflow', 'list'),
    ('auth', 'status'),
    ('status', ''),
})

# Pure read-only "filter" programs — pagers/formatters that read stdin (or a
# file) and write only to stdout. A segment running one of these is safe to ride
# along AFTER a recognized-safe git/gh segment in a pipe (`git log | head -20`)
# without dropping the whole command from `allow` to `defer`. Curated to a set
# with no file-writing or code-running behavior when invoked with no positional
# argument. Deliberately EXCLUDES sed/awk (write via `-i` / `>` or run code),
# tr (no write but easy to confuse), and tee/dd (write by definition).
SAFE_READ_FILTERS = frozenset({
    'head', 'tail', 'cat', 'wc', 'nl', 'sort', 'uniq', 'cut', 'column',
    'less', 'more',
})

# Per-program filter options that consume a SEPARATE following value token, so
# the value (`tail -n 5`) isn't mistaken for a disqualifying file positional.
# Missing an option here only makes a form defer (safe), never allow — so these
# cover common usage rather than every flag. `--opt=value` is one token and
# needs no entry. sort's `-o`/`--output` is intentionally absent: it WRITES a
# file and is rejected by FILTER_WRITE_OPT_RE instead.
FILTER_VALUE_OPTS = {
    'head':   {'-n', '-c'},
    'tail':   {'-n', '-c'},
    'cut':    {'-f', '-d', '-c', '-b'},
    'sort':   {'-k', '-t', '-S', '-T'},
    'uniq':   {'-f', '-s', '-w'},
    'nl':     {'-w', '-s', '-b', '-v'},
    'column': {'-s', '-c'},
}

# Filter options that make the program WRITE to a file — their presence
# disqualifies the segment (it defers). Currently only sort's output option,
# including its attached forms (`-o file`, `-ofile`, `--output file`,
# `--output=file`). The separate-token form is already caught by the
# no-positional rule; this regex additionally catches the attached forms that
# would otherwise look like a single harmless flag. Tightened so it doesn't
# swallow cut's read-only `--output-delimiter`.
FILTER_WRITE_OPT_RE = re.compile(r'^(-o|--output(=|$))')

# `git push` options that consume a separate following value token.
PUSH_VALUE_OPTS = {'--repo', '-o', '--push-option', '--receive-pack', '--exec'}
# `git push` flags that push more than the current branch.
PUSH_MANY_FLAGS = {'--all', '--mirror', '--branches'}

# Push-guard policy (env var BRANCH_GUARD_PUSH_POLICY):
#   strict (default) — auto-approve a push of the worktree's own current branch
#                      (including force pushes); ask before any other push
#                      (other branches, foreign refspecs like HEAD:main,
#                      wildcards, --all/--mirror, or a protected target).
#   protected        — ask before a push whose target is main/master; otherwise
#                      defer. Never auto-approves a push.
#   off              — don't guard pushes at all.
PUSH_POLICIES = ('off', 'protected', 'strict')

# Permission modes with no human present to answer a prompt; a would-be `ask`
# is converted to `deny` so the guard fails safe. Defined as a set so unknown /
# version-specific mode names simply don't match.
NON_INTERACTIVE_MODES = frozenset({'auto', 'dontAsk', 'bypassPermissions'})


def split_newline_separators(tokens):
    """Peel newlines out of operator-run tokens so each becomes its own token.

    `\\n` is a punctuation char, so a newline command boundary surfaces as a
    token, but it can glue onto adjacent operators (`;\\n`, `|\\n`). Those
    wouldn't match SEPARATORS, so a newline-only boundary would merge two
    commands. Split applies only to pure operator runs; a quoted filename
    containing a newline is a word token and is left intact.
    """
    out = []
    for t in tokens:
        if t and '\n' in t and all(c in PUNCT_CHARS for c in t):
            out += [p for p in re.split(r'(\n)', t) if p]
        else:
            out.append(t)
    return out


def tokenize(cmd):
    """Lex a shell command into a flat token list (POSIX mode, punctuation
    grouping) with newline separators peeled out of operator runs. Quotes are
    respected and shell operators (`|`, `&&`, `>`, `;`, …) become their own
    tokens. Raises ValueError on unbalanced quotes."""
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=';()<>|&\n')
    lex.whitespace_split = True
    lex.whitespace = lex.whitespace.replace('\n', '')
    lex.commenters = ''            # `#` mid-command is not a comment in a shell line
    return split_newline_separators(list(lex))


def has_shell_substitution(tokens):
    """True if any raw token hides a command the classifier never inspects:
    command substitution (`` `…` `` or `$(…)`, including inside a quoted arg),
    process substitution (`<(…)`/`>(…)`), or an unrecognized operator run
    (`|&`, `;;`, `;&`) that would otherwise merge a trailing command into a
    git segment's args. Must run over the RAW token stream (before redirect
    targets are stripped) so a substitution in a redirect target
    (`git diff > `evil``) is caught too. Like GIT_ESCAPE_HATCHES, this only
    downgrades a would-be `allow` to defer — it never suppresses an `ask`."""
    for t in tokens:
        if '`' in t or '$(' in t:
            return True
        if t.startswith('<(') or t.startswith('>('):
            return True
        if t and all(c in PUNCT_CHARS for c in t) and t not in SEPARATORS and t not in REDIR:
            return True
    return False


def command_segments(tokens):
    """Split a flat token list (from `tokenize`) into simple-command segments.

    Returns a list of token-lists, one per command separated by top-level
    operators (`&&`, `||`, `;`, `|`, `&`, newlines, subshell parens) and with
    redirect targets stripped out.
    """
    segments, cur, i = [], [], 0
    while i < len(tokens):
        t = tokens[i]
        if t in SEPARATORS:
            if cur:
                segments.append(cur)
                cur = []
            i += 1
            continue
        if t in REDIR:
            i += 2 if i + 1 < len(tokens) else 1   # drop operator + its target
            continue
        cur.append(t)
        i += 1
    if cur:
        segments.append(cur)
    return segments


def parse_invocation(tokens):
    """If a segment is a `git` or `gh` invocation, return
    {'prog', 'sub', 'args', 'globals'}; otherwise None. Strips leading env
    assignments and program global options so
    `FOO=bar git -C path -c k=v commit -m x` ->
    {'prog': 'git', 'sub': 'commit', 'args': ['-m','x'], 'globals': ['-C','path','-c','k=v']}."""
    i = 0
    while i < len(tokens) and ASSIGNMENT_RE.match(tokens[i]):
        i += 1
    if i >= len(tokens):
        return None
    prog = tokens[i].rsplit('/', 1)[-1]
    if prog not in ('git', 'gh'):
        return None
    start = i = i + 1
    value_opts = GIT_VALUE_OPTS if prog == 'git' else GH_VALUE_OPTS
    while i < len(tokens):
        t = tokens[i]
        if t == '--':
            i += 1
            break
        if not t.startswith('-'):
            break
        i += 2 if t in value_opts else 1
    sub = tokens[i] if i < len(tokens) else None
    args = tokens[i + 1:] if i < len(tokens) else []
    return {'prog': prog, 'sub': sub, 'args': args, 'globals': tokens[start:i]}


def is_safe_read_filter(tokens):
    """True if a non-git segment is a pure read-only filter (a pager/formatter
    like `head`/`tail`/`wc`) safe to ride along after a recognized-safe git/gh
    segment in a pipe (`git log | head -20`). Requires the program (after
    stripping a leading path and any env prefix, like `parse_invocation`) to be
    in SAFE_READ_FILTERS and the segment to have NO non-flag positional argument
    — so it consumes stdin, not a file. `head`, `head -20`, `wc -l`, `tail -n 5`
    qualify; `cat file`, `sort big.txt` (read a file — workspace-guard's domain)
    and `sort -ofile` (writes a file) do not. Value-consuming options
    (`tail -n 5`) are accounted for so their value isn't read as a positional;
    a write option (`sort -o`) disqualifies. Fails safe: any token it can't
    prove is stdin-only makes the segment defer rather than allow."""
    i = 0
    while i < len(tokens) and ASSIGNMENT_RE.match(tokens[i]):
        i += 1
    if i >= len(tokens):
        return False
    prog = tokens[i].rsplit('/', 1)[-1]
    if prog not in SAFE_READ_FILTERS:
        return False
    value_opts = FILTER_VALUE_OPTS.get(prog, frozenset())
    args = tokens[i + 1:]
    j = 0
    while j < len(args):
        t = args[j]
        if t == '--':
            # Everything after `--` is a positional (a file path); only a bare
            # trailing `--` is acceptable.
            return j == len(args) - 1
        if t == '-':
            j += 1                       # bare `-` means stdin, not a file
            continue
        if t.startswith('-'):
            if FILTER_WRITE_OPT_RE.match(t):
                return False             # writes a file (e.g. sort -o) -> defer
            j += 2 if t in value_opts else 1
            continue
        return False                     # a non-flag positional (file path)
    return True


def ref_to_branch(ref, current):
    """Map one side of a push refspec to (branch_name_or_None, is_wildcard).
    `HEAD` -> current branch; `refs/heads/x` -> `x`; an empty side (deletion
    source) or a non-branch ref (`refs/tags/...`) -> None; a `*` glob sets the
    wildcard flag. A bare name is assumed to be a branch (best-effort: it could
    be a tag, but that only ever errs toward asking, never toward allowing)."""
    if ref == '':
        return (None, False)
    if '*' in ref:
        return (None, True)
    if ref == 'HEAD':
        return (current, False)
    if ref.startswith('refs/heads/'):
        return (ref[len('refs/heads/'):], False)
    if ref.startswith('refs/'):
        return (None, False)
    return (ref, False)


def parse_refspec(spec, current, delete):
    """Resolve a refspec to (src_branch, dst_branch, is_wildcard). With
    `--delete`, the token is a destination ref to remove (src is None)."""
    if delete:
        dst_b, glob = ref_to_branch(spec, current)
        return (None, dst_b, glob)
    if spec.startswith('+'):
        spec = spec[1:]
    src_raw, dst_raw = spec.split(':', 1) if ':' in spec else (spec, spec)
    src_b, src_glob = ref_to_branch(src_raw, current)
    dst_b, dst_glob = ref_to_branch(dst_raw, current)
    return (src_b, dst_b, src_glob or dst_glob)


def push_decision(args, current, policy):
    """Given the tokens after `push`, the worktree's current branch, and the
    policy, return (decision, reason) where decision is 'allow', 'ask', or None
    (defer). strict auto-approves a push of the worktree branch (incl. force);
    protected only asks on a protected target. Leans toward asking (strict) /
    deferring (protected) on parsing uncertainty, never toward allowing."""
    positionals, many, delete, i = [], False, False, 0
    while i < len(args):
        t = args[i]
        if t == '--':
            positionals += args[i + 1:]
            break
        if t.startswith('-'):
            if t in PUSH_MANY_FLAGS:
                many = True
            if t in ('--delete', '-d'):
                delete = True
            i += 2 if t in PUSH_VALUE_OPTS else 1
            continue
        positionals.append(t)
        i += 1

    if many:
        return ('ask', "Push targets multiple branches (--all/--mirror) — confirm before proceeding.")

    # positionals[0] is the repository; the rest are refspecs. With no refspec,
    # git pushes the current branch to its same-named upstream. Force flags
    # (-f / --force / --force-with-lease) don't change which branch is targeted,
    # so a force push of the worktree branch is treated like any other.
    refspecs = positionals[1:] if positionals else []
    pairs = ([parse_refspec(s, current, delete) for s in refspecs]
             if refspecs else [(current, current, False)])

    for src_b, dst_b, glob in pairs:
        if glob:
            return ('ask', "Push uses a wildcard refspec (multiple branches) — confirm before proceeding.")
        if dst_b and is_protected(dst_b):
            return ('ask', f"Push targets protected branch '{dst_b}' — confirm before proceeding.")
        if policy == 'strict':
            if dst_b is not None and dst_b != current:
                return ('ask', f"Push targets '{dst_b}', not the worktree branch "
                                f"'{current}' — confirm before proceeding.")
            if src_b is not None and src_b != current:
                return ('ask', f"Push sends local branch '{src_b}', not the worktree "
                                f"branch '{current}' — confirm before proceeding.")

    if policy == 'strict':
        return ('allow', f"Push of worktree branch '{current}' — auto-approved.")
    return (None, None)


def push_policy():
    """Read BRANCH_GUARD_PUSH_POLICY; default and fall back to 'strict'."""
    v = (os.environ.get('BRANCH_GUARD_PUSH_POLICY') or 'strict').strip().lower()
    return v if v in PUSH_POLICIES else 'strict'


def _feature(branch, reason=None):
    """Verdict for a mutation that's routine on a feature branch but should be
    confirmed on a protected one: allow on non-protected, ask on protected,
    defer when the branch can't be resolved."""
    if branch is None:
        return ('defer', None)
    if is_protected(branch):
        return ('ask', reason or f"Targets protected branch '{branch}' — confirm before proceeding.")
    return ('allow', None)


def short_flag_letters(args):
    """Letters from combined short-flag tokens (`-fd` -> {'f','d'}), so a
    bundled flag is recognized the same as if it were written separately."""
    letters = set()
    for a in args:
        if len(a) > 1 and a[0] == '-' and a[1] != '-':
            letters |= set(a[1:])
    return letters


def classify_git(sub, args, branch, policy):
    """Verdict ('allow' | 'ask' | 'defer', reason) for a `git <sub>` command."""
    flags = {a for a in args if a.startswith('-')}
    short = short_flag_letters(args)
    pos = [a for a in args if not a.startswith('-')]
    first = pos[0] if pos else ''

    if sub in READONLY_GIT:
        return ('allow', None)
    if sub == 'commit':
        return _feature(branch)
    if sub == 'push':
        if policy == 'off' or branch is None:
            return ('defer', None)
        decision, reason = push_decision(args, branch, policy)
        return (decision or 'defer', reason)

    # Harmless mutations — don't put work onto or rewrite a branch's history.
    if sub == 'add':
        return ('allow', None)
    if sub == 'restore':
        # `--staged`/`-S` unstages (safe); restoring the worktree discards changes.
        staged = '--staged' in flags or 'S' in short
        worktree = '--worktree' in flags or 'W' in short
        if staged and not worktree:
            return ('allow', None)
        return ('ask', "`git restore` discards working-tree changes — confirm before proceeding.")
    if sub == 'switch':
        if 'f' in short or flags & {'--force', '--discard-changes'}:
            return ('ask', "`git switch` would discard changes — confirm before proceeding.")
        return ('allow', None)            # create (-c) or plain switch; git refuses if unsafe
    if sub == 'checkout':
        if short & {'b', 'B'}:
            return ('allow', None)        # unambiguous branch create
        return ('defer', None)            # ambiguous (branch vs path discard) -> normal flow
    if sub == 'branch':
        if short & {'d', 'D', 'm', 'M', 'f'} or flags & {'--delete', '--move', '--force'}:
            return ('ask', "Deleting/renaming a git branch — confirm before proceeding.")
        return ('allow', None)            # list or create
    if sub == 'tag':
        if 'd' in short or '--delete' in flags:
            return ('ask', "Deleting a git tag — confirm before proceeding.")
        return ('allow', None)            # list or create
    if sub == 'worktree':
        if first in ('add', 'list', 'lock', 'unlock'):
            return ('allow', None)
        if first in ('remove', 'prune', 'move'):
            return ('ask', "Removing/moving a git worktree — confirm before proceeding.")
        return ('defer', None)
    if sub == 'stash':
        if first in ('list', 'show'):
            return ('allow', None)
        if first in ('drop', 'clear'):
            return ('ask', "Dropping stashed changes — confirm before proceeding.")
        return _feature(branch, "Stash operation on a protected branch — confirm before proceeding.")
    if sub in ('merge', 'cherry-pick', 'revert', 'am'):
        if flags & {'--abort', '--continue', '--skip', '--quit'}:
            return ('allow', None)        # control ops are safe
        return _feature(branch, f"`git {sub}` onto a protected branch — confirm before proceeding.")
    if sub == 'rebase':
        if flags & {'--abort', '--continue', '--skip', '--quit', '--edit-todo'}:
            return ('allow', None)
        return _feature(branch, "`git rebase` on a protected branch — confirm before proceeding.")
    if sub == 'pull':
        if '--ff-only' in flags:
            return ('allow', None)
        return ('ask', "`git pull` may merge or rebase — use --ff-only or confirm.")
    if sub == 'reset':
        if flags & {'--hard', '--merge', '--keep'}:
            return ('ask', "`git reset --hard` discards changes — confirm before proceeding.")
        return ('defer', None)            # soft/mixed -> normal flow
    if sub == 'clean':
        # clean is a no-op without --force; -f is what makes it delete.
        if 'f' in short or '--force' in flags:
            return ('ask', "`git clean` deletes untracked files — confirm before proceeding.")
        return ('defer', None)
    if sub == 'config':
        if flags & {'--global', '--system', '--add', '--unset', '--unset-all',
                    '--replace-all', '--remove-section', '--rename-section', '-e', '--edit'}:
            return ('ask', "Writing git config — confirm before proceeding.")
        if flags & {'--get', '--get-all', '--get-regexp', '--get-urlmatch', '--list', '-l'}:
            return ('allow', None)
        return ('defer', None)            # ambiguous `git config key [value]`
    if sub == 'remote':
        if first in ('', 'show', 'get-url'):
            return ('allow', None)
        return ('defer', None)
    if sub == 'reflog':
        if first in ('', 'show'):
            return ('allow', None)
        if first in ('expire', 'delete'):
            return ('ask', "Rewriting the reflog — confirm before proceeding.")
        return ('defer', None)
    if sub in ('filter-branch', 'gc'):
        return ('ask', f"`git {sub}` can rewrite or prune history — confirm before proceeding.")

    return ('defer', None)                # unknown subcommand -> normal flow


def classify_gh(sub, args):
    """Verdict for a `gh <sub>` command: allow read-only ones, defer the rest."""
    pos = [a for a in args if not a.startswith('-')]
    subsub = pos[0] if pos else ''
    if (sub, subsub) in READONLY_GH or (sub, '') in READONLY_GH:
        return ('allow', None)
    return ('defer', None)


def classify_segment(inv, branch, policy):
    """Verdict ('nongit' | 'allow' | 'ask' | 'defer', reason) for one segment.
    'nongit' marks a segment that isn't a git/gh invocation (so the whole
    command can't be auto-approved)."""
    if inv is None:
        return ('nongit', None)
    if inv['prog'] == 'gh':
        return classify_gh(inv['sub'] or '', inv['args'])
    if inv['sub'] is None:
        return ('defer', None)            # bare `git`
    verdict, reason = classify_git(inv['sub'], inv['args'], branch, policy)
    # An inline-config escape hatch blocks auto-allow, but must not weaken a
    # protective `ask` (e.g. `git -c k=v commit` on main still asks).
    if verdict == 'allow' and (set(inv['globals']) & GIT_ESCAPE_HATCHES):
        return ('defer', None)
    return (verdict, reason)


def current_branch(cwd):
    """Current branch via `git -C <cwd> symbolic-ref --short -q HEAD`, or None
    if the directory isn't a repo / git is unavailable / HEAD won't resolve /
    git hangs. Unlike `rev-parse --abbrev-ref HEAD` (which prints the literal
    "HEAD" and exits 0 on a detached HEAD), `symbolic-ref -q` exits non-zero
    when HEAD is detached, so a detached HEAD resolves to None and the hook
    defers. The 5s timeout keeps a wedged repo or stuck git from blocking the
    hook until Claude Code's 10s hook timeout fires, degrading every tool call —
    on timeout we defer (fail safe) like any other unresolvable branch."""
    try:
        r = subprocess.run(
            ['git', '-C', cwd, 'symbolic-ref', '--short', '-q', 'HEAD'],
            capture_output=True, text=True, timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if r.returncode != 0:
        return None
    return r.stdout.strip() or None


def is_protected(branch):
    return bool(PROTECTED_BRANCH_RE.match(branch))


def emit(decision, reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": decision,
        "permissionDecisionReason": reason,
    }}))


def confirm(reason, mode):
    """Emit `ask`, or `deny` when running in a non-interactive permission mode
    where no human is present to answer the prompt (fail safe)."""
    emit('deny' if mode in NON_INTERACTIVE_MODES else 'ask', reason)


def main():
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return                                     # unparseable input -> defer
    if not isinstance(data, dict):
        return

    tool = data.get('tool_name') or ''
    tool_input = data.get('tool_input') or {}
    mode = data.get('permission_mode') or ''

    if tool == 'Bash':
        cmd = tool_input.get('command') or ''
        if not cmd.strip():
            return
        try:
            tokens = tokenize(cmd)
        except ValueError:
            return                                 # unbalanced quotes -> defer
        segments = command_segments(tokens)
        invs = [parse_invocation(seg) for seg in segments]
        if not any(invs):
            return                                 # no git/gh command -> defer

        policy = push_policy()
        branch = current_branch(data.get('cwd') or os.getcwd())
        verdicts = []
        for seg, inv in zip(segments, invs):
            if inv is None:
                # A non-git segment rides along only if it's a pure read-only
                # filter (`git log | head`); otherwise it's `nongit` and the
                # command can't be auto-approved. `not any(invs)` above already
                # guaranteed at least one git/gh segment, so a filter-only
                # command (`head -5`) defers rather than allows.
                verdicts.append(('filter', None) if is_safe_read_filter(seg)
                                else ('nongit', None))
            else:
                verdicts.append(classify_segment(inv, branch, policy))

        # A protective ask wins over everything (and becomes deny when no human
        # is present). Otherwise the command is auto-approved only when EVERY
        # segment is recognized-safe — a git/gh `allow` or a safe read filter —
        # so a non-git, non-filter command can't ride along.
        for verdict, reason in verdicts:
            if verdict == 'ask':
                confirm(reason, mode)
                return
        if all(verdict in ('allow', 'filter') for verdict, _ in verdicts):
            # A hidden command substitution / process substitution / unrecognized
            # operator would run code the classifier never saw, so it can't ride
            # along into an auto-approve — defer (the protective `ask` above is
            # left untouched).
            if has_shell_substitution(tokens):
                return
            emit('allow', (f"Safe git/gh operation on branch '{branch}' — auto-approved."
                           if branch else "Safe read-only git/gh operation — auto-approved."))
        return                                     # mixed / unknown -> defer

    if tool in ('Edit', 'Write', 'MultiEdit', 'NotebookEdit'):
        # NotebookEdit names the path `notebook_path`; the others use `file_path`.
        file_path = tool_input.get('notebook_path') or tool_input.get('file_path') or ''
        if not file_path:
            return
        branch = current_branch(os.path.dirname(file_path) or '.')
        if branch is None:
            return
        if is_protected(branch):
            confirm(f"Targets protected branch '{branch}' — confirm before proceeding.", mode)
        return

    # Any other tool -> defer.


if __name__ == '__main__':
    main()
