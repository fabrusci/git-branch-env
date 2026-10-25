# `git-branch-env` — mise Plugin Documentation

**Author:** Francesco Abrusci | **Version:** 2.1.0

A mise environment plugin that automatically sets environment variables based on the current git branch, enabling branch-aware configurations without any manual switching.

---

## How It Works

When mise loads the environment (on `cd`, shell startup, or branch switch), the plugin:

1. Detects the current git branch by **reading `.git/HEAD` directly** — no `git` subprocess is spawned. It walks up from the project root the same way git itself resolves a repo, and follows `gitdir:` redirection for worktrees/submodules. Detached HEAD is reported as the literal string `HEAD` (same as `git rev-parse --abbrev-ref HEAD`).
2. Collects all matching configuration blocks (default, patterns, exact branches)
3. Merges them in priority order — higher priority values overwrite lower ones
4. Exports the resulting variables into the shell environment

> **v2 note:** v1 shelled out to `git` up to 3 times per call. Since mise re-evaluates env on every shell prompt while inside the project, this meant 2-3 `git` forks per prompt — harmless on an idle host, but on a host already under process/thread pressure it became a self-feeding fork storm that froze the shell entirely. v2 needs zero subprocess forks for branch detection (verified by running with `git` absent from `PATH`). Behavior and configuration are unchanged — this is a drop-in upgrade.

> **v2.1 note:** branch-switch pickup needed no extra wiring even before this change — v2's branch detection is cheap enough that it just runs on every hook-env evaluation, so a `git checkout`/`git switch` is already reflected on the next prompt. What v2.1 adds is that `MiseEnv` now returns `{ env, cacheable = true, watch_files = { head_path } }` instead of a bare array. `head_path` is the actual HEAD file resolved in step 1 above — under `.git/worktrees/<name>/` or `.git/modules/<name>/` when inside a worktree or submodule, not a hardcoded `.git/HEAD`. This is the shape mise's plugin docs describe for a hook that wants to opt into mise's own result caching (skip re-running the hook until the watched file changes); verified against mise 2026.10.18 to produce correct env vars with no regressions, though no skip-on-unchanged behavior was observable on that specific build (`MISE_DEBUG=1 mise env` still shows the hook running every call). It's a forward-compatible, zero-cost declaration either way. See [Automatic Reload on Branch Switch](#automatic-reload-on-branch-switch).

---

## Always-Available Variables

If you are inside a git repository, the plugin always exports:

| Variable | Description | Example |
|---|---|---|
| `GIT_BRANCH` | The raw current branch name | `feature/new-ui` |
| `GIT_BRANCH_SAFE` | Branch name sanitized for use in variable names (`/` and `-` replaced with `_`, uppercased) | `FEATURE_NEW_UI` |

---

## Configuration

All configuration lives under `[env._.git-branch-env.*]` in your `.mise.toml`.

### Default values

Applied to **every branch** (lowest priority):

```toml
[env._.git-branch-env.default]
LOG_LEVEL = "info"
APP_ENV   = "development"
```

### Exact branch match

Applied only when the current branch **exactly matches** the key:

```toml
[env._.git-branch-env.branches.main]
APP_ENV   = "production"
LOG_LEVEL = "warn"

[env._.git-branch-env.branches.develop]
APP_ENV   = "development"
LOG_LEVEL = "debug"
```

### Pattern matching

Applied when the branch name **starts with** the prefix, or **matches a glob** (`*`):

```toml
# Prefix match: applies to feature/foo, feature/bar-baz, etc.
[env._.git-branch-env.patterns."feature/"]
APP_ENV   = "feature"
LOG_LEVEL = "debug"

# Glob match: applies to feat, feature, feat-xyz, etc.
[env._.git-branch-env.patterns."feat*"]
APP_ENV = "development"
```

> **Pattern vs Prefix:** if the pattern string ends with `*`, it is treated as a glob. Otherwise it is treated as a prefix (the branch must start with that exact string).

---

## Priority and Merge Order

Variables are applied in this order — later values overwrite earlier ones:

```
default  ->  pattern (shorter first)  ->  exact branch match
 (low)                                          (high)
```

When multiple patterns match the same branch, **longer patterns win** (more specific patterns have higher priority than shorter ones).

### Example

```toml
[env._.git-branch-env.default]
LOG_LEVEL    = "info"
FEATURE_FLAG = "false"

[env._.git-branch-env.patterns."feature/"]
LOG_LEVEL    = "debug"
FEATURE_FLAG = "true"

[env._.git-branch-env.branches."feature/experimental"]
LOG_LEVEL = "trace"
```

On branch `feature/experimental`:
- `LOG_LEVEL = "trace"` — from exact branch match (highest priority)
- `FEATURE_FLAG = "true"` — from pattern match (not overridden by the branch block)

---

## Secrets with `pass`

The plugin integrates with the [`pass`](https://www.passwordstore.org/) password manager. Instead of a plain string, use a table with a `pass` key:

```toml
[env._.git-branch-env.branches.main]
DATABASE_URL      = "postgresql://prod-db:5432/myapp"
DATABASE_PASSWORD = { pass = "myapp/prod/db-password" }
API_KEY           = { pass = "myapp/prod/api-key" }
```

At runtime the plugin runs `pass show myapp/prod/db-password` and injects the result as the environment variable. If `pass` is not installed or the secret is missing, the variable is **silently skipped** (use `MISE_DEBUG=1 mise env` to diagnose).

This is the only subprocess the plugin still spawns. Since v2, it's bounded by a hard 5s timeout (a stuck `gpg-agent`/pinentry can no longer hang the shell indefinitely) and backed by a 5s TTL file cache, so a repeated secret lookup isn't re-invoked on every single prompt.

---

## Automatic Reload on Branch Switch

No `.mise.toml` configuration required, and never has been since v2: mise
re-evaluates this hook on every prompt/`mise env` call, and branch
detection is cheap (no `git` subprocess), so `git checkout` / `git switch`
is reflected on the very next evaluation — including inside a worktree or
submodule, since branch detection already resolves the correct per-
worktree/per-submodule HEAD file.

v2.1 additionally declares that resolved HEAD file as `watch_files` with
`cacheable = true` (see the v2.1 note above), so that a mise build which
implements hook-result caching can skip re-running this hook entirely
until the branch actually changes. `{ pass = "..." }` secrets are
unaffected either way — they keep following the 5s TTL cache described
above, regardless of branch switches.

Edits to `.mise.toml` itself (adding/changing a `branches`/`patterns`/
`default` block) are picked up by mise's own config-file watching,
independent of all of the above.

---

## Running a Command on Branch Change

`MiseEnv` only returns environment variables — it cannot execute arbitrary
commands. That's enough as long as the consumer reads an env var, but some
tools read *persisted* state instead: e.g. the Pulumi CLI's "currently
selected stack" lives in local workspace state, and a prompt plugin like
oh-my-posh's Pulumi segment reads that state, not `$PULUMI_STACK`. For
those, you need an actual command to run on branch change, not just a
variable.

A `.mise.toml` `[[watch_files]]` block with a `run` script looks like the
natural fit, and earlier revisions of this documentation suggested exactly
that — **it does not work**. Verified directly: a scratch repo, a properly
activated shell (`eval "$(mise activate bash)"`), a real `git checkout`
between two branches, checked with and without an intervening `mise env`/
`mise hook-env` call — the `run` script never fired. `watch_files`/
`sources` only take effect inside `mise watch <task>`, which runs the task
under `watchexec` and requires that process to keep running in a terminal.

The mechanism that does work, with zero background process and zero
polling, is a plain git `post-checkout` hook — fired directly by git on
every real branch checkout. Point it at this plugin's own resolved value
via `mise env --json`, so the branch→value mapping is defined once (in
`.mise.toml`) and reused, not duplicated in a shell script:

```bash
# .git/hooks/post-checkout (chmod +x)
#!/usr/bin/env bash
# $3 is 1 only for a branch checkout, 0 for a single-file checkout
[ "$3" = "1" ] || exit 0

stack="$(mise env --json 2>/dev/null | jq -r '.PULUMI_STACK // empty')"
[ -n "$stack" ] && pulumi stack select "$stack" 2>/dev/null
exit 0
```

```toml
[env._.git-branch-env.branches.main]
PULUMI_STACK = "production"

[env._.git-branch-env.branches.develop]
PULUMI_STACK = "dev"

[env._.git-branch-env.patterns."feature/"]
PULUMI_STACK = "dev"
```

Caveats:
- `.git/hooks/` is local and untracked. For a team-shared hook, set
  `core.hooksPath` to a committed directory, or use a hook manager
  (lefthook, pre-commit, husky, ...).
- `mise watch <task>` (with `sources = [".git/HEAD"]`) is a valid
  alternative if you're fine with a dedicated terminal/pane staying open
  for an inotify-driven watcher — it's not zero-process like a git hook,
  but it does work.
- Not Pulumi-specific: the same `git hook + mise env --json + jq` pattern
  applies to any tool needing an imperative action instead of an env var.

---

## Installation

```bash
# 1. Create plugin directories
mkdir -p ~/.local/share/mise/plugins/git-branch-env/hooks

# 2. Copy plugin files (metadata.lua, hooks/mise_env.lua, hooks/mise_path.lua)

# 3. Link the plugin to mise
mise plugin link git-branch-env ~/.local/share/mise/plugins/git-branch-env

# 4. Verify
mise plugin ls | grep git-branch-env
```

Requires `experimental = true` in `[settings]` because the plugin uses mise's Lua hook API:

```toml
[settings]
experimental = true
```

---

## Debugging

```bash
# Dump all environment variables mise would set
mise env

# Enable verbose debug output (shows plugin execution, pass calls, etc.)
MISE_DEBUG=1 mise env

# Confirm the plugin is loaded
mise plugin ls

# Confirm git branch detection
git branch --show-current

# Prove branch detection needs zero `git` forks (sanity check after any change)
env PATH=/nonexistent mise env

# Confirm the hook is actually being cached/skipped between prompts
# (look for the plugin's hook execution log line; it should NOT appear on
# a second `mise env` run with the branch unchanged)
MISE_DEBUG=1 mise env 2>&1 | grep -i git-branch-env
```

---

## Non-git Directories

Outside a git repository, the plugin still applies `[env._.git-branch-env.default]` values. `GIT_BRANCH` and `GIT_BRANCH_SAFE` are **not** exported in that case.
