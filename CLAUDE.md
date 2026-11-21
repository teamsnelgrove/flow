# Flow, teamsnelgrove fork

Fork of [neurocyte/flow](https://git.flow-control.dev/neurocyte/flow). The goal
is helix-mode compatibility: find where flow's helix mode differs from helix,
fix it here, and upstream the parts that are wanted.

Upstream is one author pushing straight to `master`, many commits a day. He
reimplements more often than he merges, and he is wary of the API boundary
between the core editor and the vim/helix modes. `helix-refactoring@upstream`
is his stale attempt at that boundary (bound `self` for helix commands, no
inclusive selection mode). Read it for direction; do not build on it.

## Layout

This is a jj repo colocated with git. Use `jj`, not `git`, for anything that
writes. There are no git worktrees.

| Name | What it is |
|---|---|
| `master` | Mirror of `master@upstream`, which is `trunk()`. Never commit to it. |
| topic bookmarks | One per upstreamable change, each cut from `trunk()`. One topic is one PR. |
| `fork-infra` | This file, devenv, ignores. Never goes upstream. |
| `dev` | Merge commit of every topic. Build and run from here. |

Remotes: `upstream` (fetch only), `origin` (the fork on git.flow-control.dev,
where PRs are opened), `github` (mirror for machines that cannot reach
`origin`; not fetched by default).

Stack one topic on another only when it cannot compile without it
(`helix-known-gap` needs the test DSL from `helix-pair-textobjects`).

## jj recipes

```shell
jj git fetch                                  # upstream and origin
jj rebase -b dev -o 'trunk()'                 # move every topic and dev onto new upstream
jj git push -b master                         # keep the fork's mirror current
nix/update-zig-deps-hash.sh                   # no-op unless build.zig.zon changed

jj new dev                                    # start work on top of everything
jj squash --into <topic>                      # file the work into its topic
jj absorb                                     # or let jj route hunks to the commits that own those lines

jj new 'trunk()' -m 'type(scope): message'    # new topic
jj bookmark create <topic>
jj rebase -s dev -o 'dev-' -o <topic>         # add it to the dev merge

jj git push -b <topic>                        # publish or update a PR branch
```

Conflicts after a rebase are recorded in the commit, not blocking. Resolve
them in the topic that owns them (`jj new <conflicted>`, fix, `jj squash`).
When upstream lands its own version of a topic, keep upstream's code and
reduce the topic to whatever tests still add coverage.

## Gap workflow

1. A gap or bug in helix mode is reported.
2. Look for it: an existing `.known_gap` case in `test/`, or the coverage
   database for a missing or unbound command.
3. If there is no case, write one first, as `.known_gap`, in the annotation
   DSL (`test/annotation.zig`). Check the expected half against real helix.
4. Fix it, then flip the case to `.passes`. A gap that starts passing fails
   the suite with `error.KnownGapNowPasses` until it is flipped.

Limits of the test tier:

- A case can only call a function that exists. A missing command is tracked
  by the coverage database, not by a test.
- Cases call pure functions through `helix.test_internal`. Commands that go
  through `tui.mainview()` are not unit-testable yet.

## Where code goes

- Fix in the mode, not the core. Prefer `src/tui/mode/helix.zig` and
  `src/keybind/builtin/helix.json`.
- New fork-owned helix code goes in its own files under `src/tui/mode/helix/`,
  imported by `helix.zig`, so the import and dispatch lines are the only
  conflict surface. Not created yet; start it with the first gap that needs it.
- A change to the core (`src/tui/editor.zig`, `src/buffer/`) gets its own
  commit in its own topic, never mixed with mode code. Core changes are the
  first thing to offer upstream: each one is a statement of what the mode
  boundary has to expose.

## Commands

`devenv shell` (or direnv) provides zig, jj and the coverage script's tools.

```shell
zig build                                     # debug build, zig-out/bin/flow
zig build test --summary all                  # everything
zig build test -Dtest-filter=<substring>      # repeatable
flow-dev [args]                               # build this checkout and run it
scripts/helix-coverage.sh                     # rebuild scripts/.out/helix-coverage.duckdb
nix-build                                     # optimized package, result/bin/flow
```

`default.nix` pins the zig dependencies by hash in `nix/zig-deps.hash`. jj has
no commit hooks, so nothing refreshes it automatically; a stale hash fails
`nix-build` with a mismatch instead of building old dependencies. Fix it with
`nix/update-zig-deps-hash.sh` and squash the result into `fork-infra`.

The zig version must satisfy `minimum_zig_version` in `build.zig.zon`.
Upstream tracks new zig releases closely; when it moves, update `devenv.lock`.

## Conventions

- Commit subjects follow upstream: `type(scope): message`, for example
  `fix(helix): ...`. Each commit should stand alone as a suggestion he could
  take without the rest.
- US English spelling.
- Run `zig fmt` on changed files.
