# branch-guard

**This repository is archived and read-only. branch-guard now ships from
[karlkfi/claude-bouncer](https://github.com/karlkfi/claude-bouncer).**

```
/plugin marketplace add karlkfi/claude-bouncer
/plugin install branch-guard@claude-bouncer
```

Those two lines replace the pair this repo used to document. The plugin itself
did not change: same hook, same `main`/`master` protected set, same push
policies, same `BRANCH_GUARD_OVERRIDE=<reason>` prefix. All seven
`BRANCH_GUARD_*` variables keep their names and their defaults, so nothing in
your own repo or `settings.json` needs editing.

The five guards — `workspace-guard`, `branch-guard`, `prod-guard`,
`exit-status-guard`, `foreground-guard` — all parse the same Bash command
strings, and were re-implementing that parser five times over. They share one
now, so they share a repository, a test suite, and a release pipeline.

## Where the docs went

[`plugins/branch-guard`](https://github.com/karlkfi/claude-bouncer/tree/main/plugins/branch-guard)
in claude-bouncer: behavior table, the `git branch` ownership model, the push
guard and its overlap check, the break-glass, config reference.

Read that rather than anything in this repo. The last release here was `v1.9.0`
and claude-bouncer ships `1.10.0`, where two verdicts this README used to
document as `ask` are now `deny`: a `git reset --hard` onto a tip nothing else
reaches, and a push whose base moved into the lines the branch edits. The
behavior tables here and the pages under `docs/` describe a version that no
longer ships.

## Switching an existing install

The marketplace name changes from `branch-guard` to `claude-bouncer`, so an
existing install has to be removed and re-added — an update will not cross that
boundary, and the old marketplace still clones fine, so nothing tells you it has
gone quiet:

```
claude plugin uninstall branch-guard@branch-guard
claude plugin marketplace remove branch-guard
claude plugin marketplace add karlkfi/claude-bouncer
claude plugin install branch-guard@claude-bouncer
```

Restart Claude Code (or `/reload-plugins`) to apply. The hook is registered at
startup, so a running session stays on the version it loaded. The `/plugin` menu
does the same four steps interactively, on the CLI, the IDE extensions, and
Claude Code for Claude Desktop.

**Repoint auto-update too.** If you followed the old install instructions you
have an `extraKnownMarketplaces` entry in `~/.claude/settings.json` naming this
repository, and it will go on refreshing a marketplace that will never publish
another release. Replace it:

```json
{
  "extraKnownMarketplaces": {
    "claude-bouncer": {
      "source": { "source": "git", "url": "https://github.com/karlkfi/claude-bouncer.git" },
      "autoUpdate": true
    }
  }
}
```

The four sibling guards are one `install` line each against that same
marketplace — including `workspace-guard`, the path-boundary companion this
README used to send you to a separate repo for. See the
[claude-bouncer README](https://github.com/karlkfi/claude-bouncer#install).

## What is still here

History, and the links that point into it. Archiving keeps every issue, pull
request and tag resolving; it does not delete them. New issues and pull requests
belong on
[claude-bouncer](https://github.com/karlkfi/claude-bouncer/issues). The
pre-move documentation is readable at the
[`v1.9.0`](https://github.com/karlkfi/claude-branch-guard/tree/v1.9.0) tag.

## License

[MIT](LICENSE)
