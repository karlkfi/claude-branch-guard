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

A command is auto-approved only when EVERY segment in it is recognized-safe — a
git/gh invocation classified `allow`, a read-only pager piped after one
(`git log | head`), or a side-effect-free label/no-op (`echo "---"`) — so a
non-git command can't ride along into an approval (`git status && rm -rf foo`
defers rather than allows). A segment that writes a file via an output redirect
(`git log > f`, `echo x > f`) is downgraded out of `allow` for the same reason.
A command/process substitution (`` `…` ``, `$(…)`, `<(…)`) likewise downgrades a
would-be `allow` to defer — except a small registry of provably pure ones
(`$(git rev-parse --show-toplevel)`, `$(git branch --show-current)`, `$(pwd)`),
which are treated as substitution-free so idioms like
`gh pr view "$(git branch --show-current)"` stay auto-approvable.

Heredoc bodies are dropped before lexing (`strip_heredocs`) so their (data)
contents aren't parsed as command segments — a `git commit -F- <<'EOF' … EOF`
stays auto-approvable instead of deferring on the body's foreign-looking lines.
An unquoted-delimiter body that the shell would expand (a command substitution
in it runs) is kept in the stream so the substitution guard still defers.

Also guards file edits (Edit/Write/MultiEdit/NotebookEdit) against the branch of
the file's own repository, and `git push` according to BRANCH_GUARD_PUSH_POLICY.

Reads the hook JSON on stdin, emits a PreToolUse decision on stdout. On any
parsing uncertainty (unbalanced quotes, empty input, unresolvable branch,
unknown subcommand) it defers silently so normal permissions apply — never
fail closed.

In a non-interactive permission mode (auto / dontAsk / bypassPermissions) there
is no human to answer a prompt, so a would-be `ask` is emitted as `deny`
instead — the guard fails safe. (`bypassPermissions` ignores hook decisions
entirely, but emitting `deny` there is harmless and future-proof.) A classifier
reason states only the CAUSE; `confirm()` adds the closing clause, so the two
paths read honestly — an `ask` offers a confirmation, a `deny` says there is
none to be had and points at the terminal instead.

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
# Includes the fd-duplication forms (`>&`/`<&`, as in `2>&1`); shlex's
# punctuation grouping lexes `2>&1` as the three tokens `2`, `>&`, `1`.
REDIR = {'>', '>>', '<', '<<', '<<<', '>|', '&>', '&>>', '>&', '<&'}
# Redirect operators that can take a leading fd-number prefix (`2>`, `0<&3`).
# Excludes `&>`/`&>>`, where the `&` already means both stdout+stderr and bash
# forbids an fd prefix — so a digit before them is a real argument, not an fd.
FD_PREFIX_REDIR = REDIR - {'&>', '&>>'}
# Output redirects whose target is always a FILE (a write side-effect). A
# segment carrying one downgrades a would-be `allow` to defer; the dup form
# `>&` is handled separately (it writes only when its target is a filename, not
# an fd like `2>&1`), and input redirects (`<`, `<<`, `<<<`, `<&`) never write.
WRITE_REDIR_OPS = frozenset({'>', '>>', '>|', '&>', '&>>'})
# Redirect targets that create no real file: the bit bucket and the standard
# streams (writing here is equivalent to no redirect). A redirect to one of
# these is NOT treated as a file write, so ubiquitous noise-silencing forms
# (`git fetch 2>/dev/null`, `… >/dev/null 2>&1`) stay auto-approvable.
DISCARD_TARGETS = frozenset({'/dev/null', '/dev/stdout', '/dev/stderr'})
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

# Read-only gh (subcommand, sub-subcommand) pairs — auto-allowed. Every entry is
# a pure read (view/list/status/diff/checks/search/watch); a mutation
# (`gh pr create/edit/merge/comment`, `gh run rerun/cancel`, `gh workflow run`)
# is deliberately absent so it defers — most are outward-facing publishes that
# should keep a human in the loop. `gh run watch` only polls a run to completion;
# `gh search …` only queries. `gh api` is handled separately (`classify_gh_api`)
# because its safety depends on the HTTP method, not the subcommand name.
READONLY_GH = frozenset({
    ('pr', 'view'), ('pr', 'list'), ('pr', 'status'), ('pr', 'diff'), ('pr', 'checks'),
    ('issue', 'view'), ('issue', 'list'), ('issue', 'status'),
    ('repo', 'view'), ('repo', 'list'),
    ('run', 'view'), ('run', 'list'), ('run', 'watch'),
    ('release', 'view'), ('release', 'list'),
    ('workflow', 'view'), ('workflow', 'list'),
    ('search', 'prs'), ('search', 'issues'), ('search', 'repos'),
    ('search', 'code'), ('search', 'commits'),
    ('cache', 'list'), ('label', 'list'),
    ('secret', 'list'), ('variable', 'list'),
    ('ruleset', 'list'), ('ruleset', 'view'),
    ('gist', 'list'), ('gist', 'view'),
    ('auth', 'status'),
    ('status', ''),
})

# `gh <sub> <subsub>` pairs that REMOVE or disable a resource — destructive, so
# ask (mirrors the git destructive tier; `confirm()` upgrades this to deny in
# non-interactive modes). Each maps to the action phrase used in the prompt
# (`gh repo delete` drops an entire repository; `gh workflow disable` stops a
# workflow from running). `secret`/`variable` accept `remove` as an alias for
# `delete`, so both spellings are listed. `gh ruleset` has no delete subcommand,
# so it's deliberately absent. Branch deletion (`gh pr merge|close
# --delete-branch`, `gh api -X DELETE …/git/refs/…`) and repo deletion via the
# api (`gh api -X DELETE repos/{o}/{r}`) are handled separately because they're
# flag-/path-driven, not a subcommand name.
DESTRUCTIVE_GH = {
    ('repo', 'delete'): 'deletes a repository',
    ('label', 'delete'): 'deletes a label',
    ('release', 'delete'): 'deletes a release',
    ('release', 'delete-asset'): 'deletes a release asset',
    ('secret', 'delete'): 'deletes a secret',
    ('secret', 'remove'): 'deletes a secret',
    ('variable', 'delete'): 'deletes a variable',
    ('variable', 'remove'): 'deletes a variable',
    ('gist', 'delete'): 'deletes a gist',
    ('cache', 'delete'): 'deletes a cache',
    ('workflow', 'disable'): 'disables a workflow',
}

# `gh api` options that consume a SEPARATE following value token, so the value
# isn't re-read as another option. (`--opt=value` and attached short forms like
# `-XPOST` are a single token and need no entry.)
GH_API_VALUE_OPTS = {
    '-X', '--method', '-H', '--header', '-q', '--jq', '-t', '--template',
    '-F', '--field', '-f', '--raw-field', '--input', '--cache', '--hostname',
    '-p', '--preview',
}
# `gh api` options that supply a request BODY. gh defaults to a POST when any of
# these is present, so the call is a WRITE — its presence forces a defer
# regardless of method. (`--input -` reads the body from stdin.)
GH_API_BODY_OPTS = ('--field', '--raw-field', '--input', '-F', '-f')

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

# Side-effect-free no-op / label commands. With no file-writing redirect (see
# `command_segments`' writes flag) and no shell substitution (see
# `has_shell_substitution`), these write only to stdout or just set an exit
# status — touching neither the filesystem nor the process table. One may ride
# along AFTER a recognized-safe git/gh segment, so a label line in an otherwise
# all-git chain (`git log … ; echo "---" ; git log …`) stays auto-approved
# instead of dropping the whole command to defer. Deliberately tiny: anything
# that can write a file or run code on its own stays out, and the
# redirect/substitution gating is what keeps even these safe (`echo x > f` and
# `echo $(…)` both still defer).
BENIGN_COMMANDS = frozenset({'echo', 'printf', 'true', 'false', ':'})

# Command substitutions treated as PURE for chain classification. A `$(…)` /
# backtick substitution (even inside a quoted argument) normally downgrades a
# would-be `allow` to defer, because it runs a command the classifier never
# inspects. The entries here are the narrow exceptions: each inner command is
# read-only, side-effect-free, deterministic, and reveals nothing the git/gh
# segments in the same chain couldn't already read — so a substitution matching
# one of them does NOT force the chain to defer. Any OTHER substitution keeps
# today's conservative behavior. Matched STRUCTURALLY (the inner command must
# tokenize to exactly this tuple, with no separators/redirects — see
# `is_pure_substitution`), never as a loose substring, so no extra argument or
# chained command can ride inside a match. Kept deliberately tiny: this only
# ever removes friction from an already-auto-approvable git/gh chain — the
# per-segment classifier still runs, so it never turns an `ask`/destructive
# verdict into an `allow`. Adding an entry needs the same scrutiny as a new
# READONLY_GIT member: it must be provably side-effect-free.
PURE_SUBSTITUTIONS = frozenset({
    ('git', 'rev-parse', '--show-toplevel'),   # repo root path
    ('git', 'branch', '--show-current'),        # current branch name
    ('pwd',),                                   # working directory path
})

# `git push` options that consume a separate following value token.
PUSH_VALUE_OPTS = {'--repo', '-o', '--push-option', '--receive-pack', '--exec'}
# `git push` flags that push more than the current branch.
PUSH_MANY_FLAGS = {'--all', '--mirror', '--branches'}
# `git push` flags that publish tags alongside (or instead of) a branch. `--tags`
# pushes every local tag, including release tags unrelated to the worktree
# branch, so under `strict` it asks like any other non-branch push.
# `--follow-tags` is deliberately absent: it pushes only annotated tags reachable
# from the branch already being pushed, and `push.followTags` can enable the same
# behavior from config where the hook can't see it — see README "Limitations".
PUSH_TAG_FLAGS = {'--tags'}

# Push-guard policy (env var BRANCH_GUARD_PUSH_POLICY):
#   strict (default) — auto-approve a push of the worktree's own current branch
#                      (including force pushes); ask before any other push
#                      (other branches, foreign refspecs like HEAD:main,
#                      wildcards, --all/--mirror, tags via --tags or an explicit
#                      refs/tags/… refspec, or a protected target).
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


def _has_body_substitution(line):
    """True if a heredoc body line contains a construct the shell would execute
    when the delimiter is UNQUOTED: command substitution (`$(…)`, `` `…` ``) or
    process substitution (`<(…)`/`>(…)`). Mirrors `has_shell_substitution`'s
    intent at the raw-string level (before tokenization). Deliberately coarse —
    `$((` arithmetic is matched by `$(` too, which only makes us bail toward the
    safe (unstripped -> defer) path, never toward allowing."""
    return '$(' in line or '`' in line or '<(' in line or '>(' in line


def _read_heredoc_delim(cmd, i):
    """Read a heredoc delimiter word starting at cmd[i]. Returns
    (delim, quoted, new_i): the delimiter after quote removal, whether any part
    was quoted or escaped (bash suppresses all body expansion for a quoted
    delimiter, making the body inert data), and the index just past the word.
    The word ends at unquoted whitespace or a shell metacharacter. Returns
    (None, False, i) when no delimiter word is present (`<<` at end of line)."""
    n = len(cmd)
    chars, quoted, started, q = [], False, False, None
    while i < n:
        c = cmd[i]
        if q is not None:
            if c == q:
                q = None; i += 1; continue
            if q == '"' and c == '\\' and i + 1 < n:
                chars.append(cmd[i + 1]); i += 2; continue
            chars.append(c); i += 1; continue
        if c == '\\' and i + 1 < n:
            chars.append(cmd[i + 1]); quoted = started = True; i += 2; continue
        if c in ('"', "'"):
            q = c; quoted = started = True; i += 1; continue
        if c in ' \t\n' or c in ';&|<>()':
            break
        chars.append(c); started = True; i += 1
    if not started:
        return None, False, i
    return ''.join(chars), quoted, i


def _consume_heredoc_bodies(cmd, i, pending):
    """Advance past the body lines of each queued heredoc (in order), returning
    the index just after the last terminator line — or None to signal the caller
    to leave the command unstripped. A body ends at the first line that, after
    stripping leading tabs for a `<<-` heredoc, equals the delimiter exactly
    (bash's rule). Returns None when a heredoc runs to EOF with no terminator, or
    when an UNQUOTED-delimiter body contains a command/process substitution the
    shell would execute — in that case the body must stay in the stream so the
    normal substitution guard sees it and defers (fail safe)."""
    n = len(cmd)
    for delim, strip_tabs, quoted in pending:
        found = False
        while i < n:
            end = cmd.find('\n', i)
            line, nxt = (cmd[i:], n) if end == -1 else (cmd[i:end], end + 1)
            candidate = line.lstrip('\t') if strip_tabs else line
            if candidate == delim:
                i = nxt; found = True
                break
            if not quoted and _has_body_substitution(line):
                return None
            i = nxt
        if not found:
            return None
    return i


def strip_heredocs(cmd):
    """Remove heredoc bodies from a shell command so their contents aren't lexed
    as command segments. A multi-line heredoc body would otherwise split into
    foreign segments (or contain an apostrophe that unbalances `shlex`), dropping
    an all-git chain from `allow` to a prompt (or a parse failure). Detects real
    `<<WORD` / `<<-WORD` operators (quote- and escape-aware, so a `<<` inside a
    string or a `<<<` here-string is not one) and drops each operator together
    with its body up to the terminator line; the rest of the command line — the
    git/gh invocation and anything after the terminator — is left to classify
    normally. Dropping the whole `<<WORD` operator (rather than re-emitting it)
    sidesteps `shlex`'s tokenization of `<<-` and quoted delimiters; the input
    redirection is irrelevant to git/gh classification.

    Security: a heredoc body is executed by the shell only when its delimiter is
    UNQUOTED — bash then expands the body, so a command substitution in it runs.
    A QUOTED delimiter (`<<'EOF'`, `<<"EOF"`, `<<\\EOF`) suppresses all expansion,
    so the body is inert data and is always safe to drop. An unquoted body is
    dropped only when it contains no command/process substitution; otherwise —
    and on any parse uncertainty (unterminated heredoc, missing delimiter) — the
    original command is returned unchanged so the normal pipeline sees it and
    defers (fail safe)."""
    if '<<' not in cmd:
        return cmd
    n = len(cmd)
    out = []
    i = 0
    quote = None
    pending = []          # queued (delim, strip_tabs, quoted) awaiting bodies
    while i < n:
        c = cmd[i]
        if quote is not None:                       # inside '…' or "…"
            out.append(c)
            if quote == '"' and c == '\\' and i + 1 < n:
                out.append(cmd[i + 1]); i += 2; continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c == '\\':                               # escaped next char
            out.append(c)
            if i + 1 < n:
                out.append(cmd[i + 1]); i += 2; continue
            i += 1; continue
        if c in ('"', "'"):
            quote = c; out.append(c); i += 1; continue
        if cmd.startswith('<<<', i):                # here-string: no body
            out.append('<<<'); i += 3; continue
        if cmd.startswith('<<', i):                 # heredoc operator: drop it
            j = i + 2
            if j < n and cmd[j] == '-':
                strip_tabs = True; j += 1
            else:
                strip_tabs = False
            while j < n and cmd[j] in ' \t':
                j += 1
            delim, quoted, j = _read_heredoc_delim(cmd, j)
            if delim is None:
                return cmd                          # no delimiter -> leave as-is
            pending.append((delim, strip_tabs, quoted))
            i = j
            continue
        out.append(c); i += 1
        if c == '\n' and pending:                   # bodies follow the newline
            r = _consume_heredoc_bodies(cmd, i, pending)
            if r is None:
                return cmd                          # unterminated / unsafe body
            i = r
            pending = []
    if pending:
        return cmd                                  # operator with no body -> as-is
    return ''.join(out)


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


def extract_command_substitutions(token):
    """Return the list of inner command strings for every command substitution
    (`$(…)` or `` `…` ``) in a token, or None if the token carries a
    substitution construct that can't be cleanly extracted (an unbalanced `$(`
    or backtick). Scans the whole token, so multiple and trailing-text forms
    (`$(pwd)/sub`, `` `a` `b` ``) are all found; a nested `$(…)` is returned as
    part of its enclosing inner string for the caller to reject. Fails safe:
    an unbalanced construct returns None so the caller blocks."""
    subs = []
    i, n = 0, len(token)
    while i < n:
        c = token[i]
        if c == '`':
            j = token.find('`', i + 1)
            if j == -1:
                return None                    # unbalanced backtick
            subs.append(token[i + 1:j])
            i = j + 1
            continue
        if c == '$' and i + 1 < n and token[i + 1] == '(':
            depth, j = 1, i + 2
            while j < n and depth:
                if token[j] == '(':
                    depth += 1
                elif token[j] == ')':
                    depth -= 1
                j += 1
            if depth:
                return None                    # unbalanced $(
            subs.append(token[i + 2:j - 1])
            i = j
            continue
        i += 1
    return subs


def is_pure_substitution(inner):
    """True if the inner command of a `$(…)`/backtick substitution is a
    recognized pure, read-only, side-effect-free one (PURE_SUBSTITUTIONS). The
    inner must tokenize to EXACTLY a registry tuple with no separator/redirect
    token — so an appended command (`git branch --show-current; evil`), a
    redirect (`… > f`), or a nested substitution all fail the match and keep the
    chain deferring. Unbalanced quotes (shlex raises) fail safe to False."""
    try:
        toks = tokenize(inner)
    except ValueError:
        return False
    if any(t in SEPARATORS or t in REDIR for t in toks):
        return False
    return tuple(toks) in PURE_SUBSTITUTIONS


def has_shell_substitution(tokens):
    """True if any raw token hides a command the classifier never inspects:
    command substitution (`` `…` `` or `$(…)`, including inside a quoted arg),
    process substitution (`<(…)`/`>(…)`), or an unrecognized operator run
    (`|&`, `;;`, `;&`) that would otherwise merge a trailing command into a
    git segment's args. Must run over the RAW token stream (before redirect
    targets are stripped) so a substitution in a redirect target
    (`git diff > `evil``) is caught too. Like GIT_ESCAPE_HATCHES, this only
    downgrades a would-be `allow` to defer — it never suppresses an `ask`.

    A command substitution is the one exception that does NOT block: when every
    substitution in a token is a recognized pure/read-only one
    (PURE_SUBSTITUTIONS), the token is treated as substitution-free, so a common
    idiom (`gh pr view "$(git branch --show-current)"`,
    `git -C "$(git rev-parse --show-toplevel)" status`) stays auto-approvable.
    Any non-registry or unparseable substitution still blocks."""
    for t in tokens:
        if t.startswith('<(') or t.startswith('>('):
            return True                        # process substitution — always blocks
        if '`' in t or '$(' in t:
            subs = extract_command_substitutions(t)
            if subs is None or any(not is_pure_substitution(s) for s in subs):
                return True
            continue                           # every substitution is pure — safe
        if t and all(c in PUNCT_CHARS for c in t) and t not in SEPARATORS and t not in REDIR:
            return True
    return False


def redirect_writes_file(op, target):
    """True if a redirect operator+target writes to a FILE, so a would-be
    `allow` should be downgraded to defer. Output-to-file operators
    (`>`, `>>`, `>|`, `&>`, `&>>`) always write. The dup operator `>&` writes
    only when its target is a filename rather than an fd number or `-`
    (`>&2`/`2>&1` duplicate a descriptor and create no file). Input redirects
    (`<`, `<<`, `<<<`, `<&`) never write. A redirect to `/dev/null` or a
    standard stream (DISCARD_TARGETS) creates no real file and never counts."""
    if target in DISCARD_TARGETS:
        return False
    if op in WRITE_REDIR_OPS:
        return True
    if op == '>&':
        return target is not None and target != '-' and not target.isdigit()
    return False


def command_segments(tokens):
    """Split a flat token list (from `tokenize`) into simple-command segments.

    Returns a list of `(tokens, writes_file)` pairs, one per command separated
    by top-level operators (`&&`, `||`, `;`, `|`, `&`, newlines, subshell
    parens), with redirect targets stripped out. `writes_file` is True when the
    segment carries an output redirect to a FILE (`> f`, `2> f`, `&> f`,
    `>& f`) — used to downgrade a would-be `allow` to defer; fd-duplications
    (`2>&1`, `>&2`) and input redirects (`< f`) leave it False. A bare redirect
    with no command (`> f`) is kept as an empty writing segment so it still
    blocks auto-approval rather than vanishing.
    """
    segments, cur, writes, i = [], [], False, 0
    while i < len(tokens):
        t = tokens[i]
        if t in SEPARATORS:
            if cur or writes:
                segments.append((cur, writes))
            cur, writes = [], False
            i += 1
            continue
        if t in REDIR:
            # A bash fd prefix (`2>&1`, `1>out`, `0<in`) lexes as a separate
            # leading digit token immediately before the redirect operator; drop
            # it so it isn't read as a command positional (`git push origin HEAD
            # 2>&1` must not see `2` as a refspec). Restricted to a SINGLE digit
            # so a numeric branch name (`git push origin 123 >log`) isn't
            # mistaken for an fd, and only for operators that accept an fd prefix
            # (not `&>`/`&>>`, where a leading digit is a real argument).
            if t in FD_PREFIX_REDIR and cur and len(cur[-1]) == 1 and cur[-1].isdigit():
                cur.pop()
            target = tokens[i + 1] if i + 1 < len(tokens) else None
            if redirect_writes_file(t, target):
                writes = True
            i += 2 if i + 1 < len(tokens) else 1   # drop operator + its target
            continue
        cur.append(t)
        i += 1
    if cur or writes:
        segments.append((cur, writes))
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


def is_benign_segment(tokens):
    r"""True if a non-git segment is a side-effect-free no-op/label command
    (program in BENIGN_COMMANDS after stripping a leading path and any env
    prefix, like `parse_invocation`). The caller must independently ensure the
    segment has no file-writing redirect (`command_segments`' writes flag) and
    the command has no shell substitution (`has_shell_substitution`); with those
    closed these write only to stdout or set an exit status, so one can ride
    along after a recognized-safe git/gh segment. `echo "label"`,
    `printf '%s\n' x`, `true`, `:` qualify; the gating elsewhere still defers
    `echo x > f` (redirect) and `echo $(…)` (substitution). No option/positional
    inspection is needed: with redirect and substitution closed, no argument to
    these programs writes a file or runs code."""
    i = 0
    while i < len(tokens) and ASSIGNMENT_RE.match(tokens[i]):
        i += 1
    if i >= len(tokens):
        return False
    prog = tokens[i].rsplit('/', 1)[-1]
    return prog in BENIGN_COMMANDS


def ref_to_branch(ref, current):
    """Map one side of a push refspec to (branch_name_or_None, is_wildcard,
    non_branch_ref_or_None). `HEAD` -> current branch; `refs/heads/x` -> `x`; an
    empty side (a deletion's source) -> all None; a `*` glob sets the wildcard
    flag. A bare name is assumed to be a branch (best-effort: it could be a tag,
    but that only ever errs toward asking, never toward allowing).

    A fully-qualified ref that ISN'T a branch (`refs/tags/v1`, `refs/notes/…`)
    comes back as the third element rather than as a plain None. It names a real
    ref the push would publish, so the caller has to object to it — read as
    "no branch here" it would sail past every branch check into the strict
    auto-approve, which is how `git push origin refs/tags/v1.3.0` used to be
    allowed while the equivalent `git push origin v1.3.0` asked."""
    if ref == '':
        return (None, False, None)
    if '*' in ref:
        return (None, True, None)
    if ref == 'HEAD':
        return (current, False, None)
    if ref.startswith('refs/heads/'):
        return (ref[len('refs/heads/'):], False, None)
    if ref.startswith('refs/'):
        return (None, False, ref)
    return (ref, False, None)


def parse_refspec(spec, current, delete):
    """Resolve a refspec to (src_branch, dst_branch, is_wildcard,
    non_branch_ref). With `--delete`, the token is a destination ref to remove
    (src is None)."""
    if delete:
        dst_b, glob, other = ref_to_branch(spec, current)
        return (None, dst_b, glob, other)
    if spec.startswith('+'):
        spec = spec[1:]
    src_raw, dst_raw = spec.split(':', 1) if ':' in spec else (spec, spec)
    src_b, src_glob, src_other = ref_to_branch(src_raw, current)
    dst_b, dst_glob, dst_other = ref_to_branch(dst_raw, current)
    return (src_b, dst_b, src_glob or dst_glob, dst_other or src_other)


def push_decision(args, current, policy):
    """Given the tokens after `push`, the worktree's current branch, and the
    policy, return (decision, reason) where decision is 'allow', 'ask', or None
    (defer). strict auto-approves a push of the worktree branch (incl. force);
    protected only asks on a protected target. Leans toward asking (strict) /
    deferring (protected) on parsing uncertainty, never toward allowing."""
    positionals, many, tags, delete, i = [], False, False, False, 0
    while i < len(args):
        t = args[i]
        if t == '--':
            positionals += args[i + 1:]
            break
        if t.startswith('-'):
            if t in PUSH_MANY_FLAGS:
                many = True
            if t in PUSH_TAG_FLAGS:
                tags = True
            if t in ('--delete', '-d'):
                delete = True
            i += 2 if t in PUSH_VALUE_OPTS else 1
            continue
        positionals.append(t)
        i += 1

    if many:
        return ('ask', "Push targets multiple branches (--all/--mirror)")
    if tags and policy == 'strict':
        return ('ask', "Push publishes every local tag (--tags), not just the "
                       f"worktree branch '{current}'")

    # positionals[0] is the repository; the rest are refspecs. With no refspec,
    # git pushes the current branch to its same-named upstream. Force flags
    # (-f / --force / --force-with-lease) don't change which branch is targeted,
    # so a force push of the worktree branch is treated like any other.
    refspecs = positionals[1:] if positionals else []
    pairs = ([parse_refspec(s, current, delete) for s in refspecs]
             if refspecs else [(current, current, False, None)])

    for src_b, dst_b, glob, other in pairs:
        if glob:
            return ('ask', "Push uses a wildcard refspec (multiple branches)")
        if dst_b and is_protected(dst_b):
            return ('ask', f"Push targets protected branch '{dst_b}'")
        if policy == 'strict':
            if other is not None:
                return ('ask', f"Push targets '{other}', a tag or other non-branch ref "
                               f"rather than the worktree branch '{current}'")
            if dst_b is not None and dst_b != current:
                return ('ask', f"Push targets '{dst_b}', not the worktree branch '{current}'")
            if src_b is not None and src_b != current:
                return ('ask', f"Push sends local branch '{src_b}', not the worktree branch '{current}'")

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
        return ('ask', reason or f"Targets protected branch '{branch}'")
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
        return ('ask', "`git restore` discards working-tree changes")
    if sub == 'switch':
        if 'f' in short or flags & {'--force', '--discard-changes'}:
            return ('ask', "`git switch` would discard changes")
        return ('allow', None)            # create (-c) or plain switch; git refuses if unsafe
    if sub == 'checkout':
        if short & {'b', 'B'}:
            return ('allow', None)        # unambiguous branch create
        return ('defer', None)            # ambiguous (branch vs path discard) -> normal flow
    if sub == 'branch':
        if short & {'d', 'D', 'm', 'M', 'f'} or flags & {'--delete', '--move', '--force'}:
            return ('ask', "Deleting/renaming a git branch")
        return ('allow', None)            # list or create
    if sub == 'tag':
        if 'd' in short or '--delete' in flags:
            return ('ask', "Deleting a git tag")
        return ('allow', None)            # list or create
    if sub == 'worktree':
        if first in ('add', 'list', 'lock', 'unlock'):
            return ('allow', None)
        if first in ('remove', 'prune', 'move'):
            return ('ask', "Removing/moving a git worktree")
        return ('defer', None)
    if sub == 'stash':
        if first in ('list', 'show'):
            return ('allow', None)
        if first in ('drop', 'clear'):
            return ('ask', "Dropping stashed changes")
        return _feature(branch, "Stash operation on a protected branch")
    if sub in ('merge', 'cherry-pick', 'revert', 'am'):
        if flags & {'--abort', '--continue', '--skip', '--quit'}:
            return ('allow', None)        # control ops are safe
        return _feature(branch, f"`git {sub}` onto a protected branch")
    if sub == 'rebase':
        if flags & {'--abort', '--continue', '--skip', '--quit', '--edit-todo'}:
            return ('allow', None)
        return _feature(branch, "`git rebase` on a protected branch")
    if sub == 'pull':
        if '--ff-only' in flags:
            return ('allow', None)
        return ('ask', "`git pull` may merge or rebase (use --ff-only to skip this check)")
    if sub == 'reset':
        if flags & {'--hard', '--merge', '--keep'}:
            return ('ask', "`git reset --hard` discards changes")
        return ('defer', None)            # soft/mixed -> normal flow
    if sub == 'clean':
        # clean is a no-op without --force; -f is what makes it delete.
        if 'f' in short or '--force' in flags:
            return ('ask', "`git clean` deletes untracked files")
        return ('defer', None)
    if sub == 'config':
        if flags & {'--global', '--system', '--add', '--unset', '--unset-all',
                    '--replace-all', '--remove-section', '--rename-section', '-e', '--edit'}:
            return ('ask', "Writing git config")
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
            return ('ask', "Rewriting the reflog")
        return ('defer', None)
    if sub in ('filter-branch', 'gc'):
        return ('ask', f"`git {sub}` can rewrite or prune history")

    return ('defer', None)                # unknown subcommand -> normal flow


def classify_gh_api(args):
    """Verdict for a `gh api` command. `gh api` defaults to a GET (read), so the
    proven-read form auto-allows; anything that could mutate defers. A call
    mutates when it carries a request BODY (a `--field`/`--raw-field`/`--input`
    flag — gh then defaults to POST) or an explicit non-GET/HEAD `--method`/`-X`.
    Fails safe: any method token we can't read as GET/HEAD, or any body flag,
    defers rather than allowing. Read-only modifiers (`--jq`, `--header`,
    `--paginate`, `--cache`, …) don't disqualify."""
    method = 'GET'
    positionals = []
    i = 0
    while i < len(args):
        t = args[i]
        # A request body makes gh default to POST -> a write (all spellings,
        # attached or separate: `-f`, `-fkey=v`, `--field`, `--field=k=v`, …).
        if any(t == o or t.startswith(o + '=') or
               (len(o) == 2 and t.startswith(o)) for o in GH_API_BODY_OPTS):
            return ('defer', None)
        # Explicit HTTP method, all spellings: `-X POST`, `-XPOST`,
        # `--method POST`, `--method=POST`.
        if t in ('-X', '--method'):
            method = args[i + 1] if i + 1 < len(args) else ''
            i += 2
            continue
        if t.startswith('-X') and len(t) > 2:
            method = t[2:]
            i += 1
            continue
        if t.startswith('--method='):
            method = t[len('--method='):]
            i += 1
            continue
        if t in GH_API_VALUE_OPTS:        # skip the value of other value-opts
            i += 2
            continue
        if not t.startswith('-'):
            positionals.append(t)        # the endpoint path is the first one
        i += 1
    if method.upper() == 'GET' or method.upper() == 'HEAD':
        return ('allow', None)
    # A DELETE against a recognizable destructive endpoint is escalated from
    # defer to ask (mirrors the git destructive tier). The canonical branch
    # endpoint is `DELETE /repos/{o}/{r}/git/refs/heads/{branch}`; a label is
    # `DELETE /repos/{o}/{r}/labels/{name}`; a whole repository is
    # `DELETE /repos/{o}/{r}` — exactly three path segments. Repo deletion is
    # matched by parsing the endpoint path (not a substring: a bare `repos/`
    # would also hit issue/label/sub-resource paths that aren't a repo delete),
    # so only the exact three-segment `repos/{o}/{r}` escalates. Other deletes
    # (`DELETE /user/following/x`, …) still defer.
    if method.upper() == 'DELETE':
        if any('git/refs/' in a for a in args):
            return ('ask', "`gh api` deletes a git ref (branch/tag)")
        if any('labels/' in a for a in args):
            return ('ask', "`gh api` deletes a label")
        endpoint = positionals[0] if positionals else ''
        segs = [s for s in endpoint.split('/') if s]
        if len(segs) == 3 and segs[0] == 'repos':
            return ('ask', "`gh api` deletes a repository")
    return ('defer', None)


def classify_gh(sub, args):
    """Verdict for a `gh <sub>` command: allow read-only ones, ask on
    destructive deletes/disables (repo/label/release/secret/variable/gist/cache,
    workflow disable, branch), defer the rest."""
    if sub == 'api':
        return classify_gh_api(args)
    pos = [a for a in args if not a.startswith('-')]
    subsub = pos[0] if pos else ''
    # `gh pr merge|close --delete-branch` (`-d`) removes the branch as a side
    # effect — destructive, so ask (mirrors `git branch -D` / `git push --delete`).
    if sub == 'pr' and subsub in ('merge', 'close') and (
            '--delete-branch' in args or 'd' in short_flag_letters(args)):
        return ('ask', "`gh pr {} --delete-branch` deletes the branch".format(subsub))
    # `gh repo delete`, `gh release delete`, `gh workflow disable`, … remove or
    # disable a resource — destructive.
    action = DESTRUCTIVE_GH.get((sub, subsub))
    if action is not None:
        return ('ask', "`gh {} {}` {}".format(sub, subsub, action))
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
    where no human is present to answer the prompt (fail safe).

    `reason` carries only the cause ("Push targets 'v1.3.0', not the worktree
    branch 'x'"); the closing clause is added here so each path says what is
    actually on offer. The `ask` path invites a confirmation. The `deny` path
    says plainly that there is none — a denial worded "confirm before
    proceeding" reads as a prompt waiting to be answered, so an agent retries a
    command that cannot succeed in this session until it gives up. Name the
    mode, and give the routes that do work."""
    if mode in NON_INTERACTIVE_MODES:
        emit('deny', f"{reason} — branch-guard denied it: permission mode "
                     f"'{mode}' has no way to prompt for confirmation. Retrying "
                     f"won't help — either do it outside this session (e.g. run "
                     f"the command in a terminal), or re-run in an interactive "
                     f"permission mode.")
        return
    emit('ask', f"{reason} — confirm before proceeding.")


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
        # Drop heredoc bodies before lexing so their (data) contents aren't
        # parsed as command segments — a large heredoc would otherwise split
        # into foreign segments and defer an all-git chain (see strip_heredocs).
        cmd = strip_heredocs(cmd)
        try:
            tokens = tokenize(cmd)
        except ValueError:
            return                                 # unbalanced quotes -> defer
        segments = command_segments(tokens)
        invs = [parse_invocation(seg) for seg, _ in segments]
        if not any(invs):
            return                                 # no git/gh command -> defer

        policy = push_policy()
        branch = current_branch(data.get('cwd') or os.getcwd())
        verdicts = []
        for (seg, writes), inv in zip(segments, invs):
            if inv is None:
                # A non-git segment rides along only if it's a pure read-only
                # filter (`git log | head`) or a side-effect-free label/no-op
                # (`echo "---"`). A segment that writes a file, or anything
                # else, is `nongit` so the command can't be auto-approved.
                # `not any(invs)` above already guaranteed at least one git/gh
                # segment, so a filter-/benign-only command (`head -5`,
                # `echo hi`) defers rather than allows.
                if writes:
                    verdicts.append(('nongit', None))
                elif is_safe_read_filter(seg):
                    verdicts.append(('filter', None))
                elif is_benign_segment(seg):
                    verdicts.append(('benign', None))
                else:
                    verdicts.append(('nongit', None))
            else:
                verdict, reason = classify_segment(inv, branch, policy)
                # An output redirect to a file is a write side-effect the
                # classifier can't see (`git log --format=… > f` writes
                # possibly-attacker-influenced content). Downgrade a would-be
                # allow to defer, but never weaken a protective `ask`.
                if writes and verdict == 'allow':
                    verdict = 'defer'
                verdicts.append((verdict, reason))

        # A protective ask wins over everything (and becomes deny when no human
        # is present). Otherwise the command is auto-approved only when EVERY
        # segment is recognized-safe — a git/gh `allow`, a safe read filter, or
        # a side-effect-free benign label — so a non-git, writing, or unknown
        # segment can't ride along.
        for verdict, reason in verdicts:
            if verdict == 'ask':
                confirm(reason, mode)
                return
        if all(verdict in ('allow', 'filter', 'benign') for verdict, _ in verdicts):
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
        # Resolve a relative file_path against the payload cwd (the session's
        # worktree), not the hook process's own cwd — Claude Code may launch the
        # hook from the parent/main checkout, so dirname() of a relative path
        # would land in the wrong repo and resolve the wrong branch.
        cwd = data.get('cwd') or os.getcwd()
        abs_path = file_path if os.path.isabs(file_path) else os.path.join(cwd, file_path)
        branch = current_branch(os.path.dirname(abs_path) or cwd)
        if branch is None:
            return
        if is_protected(branch):
            confirm(f"Targets protected branch '{branch}'", mode)
        return

    # Any other tool -> defer.


if __name__ == '__main__':
    main()
