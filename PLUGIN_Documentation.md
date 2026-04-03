# `git-branch-env` — mise Plugin Documentation

**Author:** Francesco Abrusci | **Version:** 1.0.0

A mise environment plugin that automatically sets environment variables based on the current git branch, enabling branch-aware configurations without any manual switching.

---

## How It Works

When mise loads the environment (on `cd`, shell startup, or branch switch), the plugin:

1. Detects the current git branch via `git branch --show-current` (falls back to `git rev-parse --abbrev-ref HEAD` for detached HEAD state)
2. Collects all matching configuration blocks (default, patterns, exact branches)
3. Merges them in priority order — higher priority values overwrite lower ones
4. Exports the resulting variables into the shell environment

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

---

## Automatic Reload on Branch Switch

Add a `watch_files` block to trigger a mise reload whenever `.git/HEAD` changes (i.e., on every `git checkout` / `git switch`):

```toml
[[watch_files]]
patterns = [".git/HEAD"]
run = """
#!/usr/bin/env bash
echo '⏳ Updating environment for branch: '$(git branch --show-current)
"""
```

mise detects the file change, re-evaluates the plugin, and updates all variables automatically.

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
```

---

## Non-git Directories

Outside a git repository, the plugin still applies `[env._.git-branch-env.default]` values. `GIT_BRANCH` and `GIT_BRANCH_SAFE` are **not** exported in that case.
