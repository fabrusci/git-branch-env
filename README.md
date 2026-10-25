# Mise Git Branch Environment Plugin

A mise environment plugin that automatically sets environment variables based on your current git branch.

## Features

- 🔄 Automatically detects current git branch
- 🎯 Set different environment variables per branch
- 🔍 Pattern matching for branch prefixes (e.g., `feature/*`, `bugfix/*`)
- 📝 Exports `GIT_BRANCH` and `GIT_BRANCH_SAFE` variables
- ⚙️ Configurable defaults with branch-specific overrides
- 🔐 Integration with `pass` password manager for secure secrets

## v2: performance & safety fix

v1 shelled out to `git` up to 3 times per `MiseEnv` call (`git rev-parse
--git-dir`, `git branch --show-current`, and a fallback `git rev-parse
--abbrev-ref HEAD`), and mise re-evaluates env on every shell prompt while
inside the project. On a host already under process/thread pressure this
turned into a self-feeding fork storm (hundreds of stuck `git` processes,
whole shell frozen).

v2 detects the branch by reading `.git/HEAD` directly (walking up to the repo
root and following `gitdir:` redirection for worktrees/submodules, same as
git itself) - **zero subprocess forks** for branch detection, verified by
running with `git` absent from `PATH` entirely. The only remaining
subprocess is the optional `pass` secret lookup, which now has a hard 5s
timeout (`cmd.exec(..., {timeout = 5})`) so a stuck `gpg-agent`/pinentry can
no longer hang the shell indefinitely, plus a short TTL cache so it isn't
re-invoked on every single prompt.

Behavior (default/patterns/branches priority, wildcard patterns, `GIT_BRANCH`
/`GIT_BRANCH_SAFE`, `pass` secrets) is unchanged - this is a drop-in upgrade.

## v2.1: branch-change detection, without the manual plumbing

Turns out the old "Automatic Branch Switching" section below (documented
since v1) was solving a problem v2 had already fixed: since v2's branch
detection is a couple of file reads instead of 2-3 `git` forks, mise
re-running the hook on every single shell prompt was already cheap enough
that branch switches were picked up automatically, with no `watch_files`
block, git hook, or shell wrapper needed - the README just never said so,
and kept pointing people at a workaround for a problem that no longer
existed. Verified by hand: `git checkout`-ing between two branches with
different `[env._.git-branch-env.branches.*]` blocks updates `$API_ENV`
etc. on the very next `mise env`/prompt, no extra config.

On top of that, `MiseEnv` now also returns `watch_files = { head_path }`
(the actual resolved HEAD file - `.git/HEAD`, or the per-worktree/
per-submodule one under `.git/worktrees/<name>/HEAD` /
`.git/modules/<name>/HEAD`) and `cacheable = true`. This is the shape mise's
docs describe for letting a plugin opt its env hook into mise's own
caching, so a future (or different) mise build can skip re-running this
hook when the branch hasn't changed, instead of always re-running it as
today. On the mise version this was developed against (2026.10.18), that
skip wasn't observable - `MISE_DEBUG=1 mise env` still shows the hook
running on every call - but declaring it correctly costs nothing, is
forward-compatible, and is strictly more correct than the hardcoded
`.git/HEAD` the old watch_files example used (which is the wrong file
inside a worktree or submodule).

## Installation

### 1. Create Plugin Directory

```bash
mkdir -p ~/.local/share/mise/plugins/git-branch-env/hooks
```

### 2. Create Plugin Files

Save the metadata file:
```bash
# Create metadata.lua
cat > ~/.local/share/mise/plugins/git-branch-env/metadata.lua << 'EOF'
PLUGIN = {
    name = "git-branch-env",
    version = "1.0.0",
    description = "Sets environment variables based on the current git branch",
    author = "Your Name"
}
EOF
```

Save the hook file (copy the content from `hooks/mise_env.lua` artifact):
```bash
# Create hooks/mise_env.lua
nano ~/.local/share/mise/plugins/git-branch-env/hooks/mise_env.lua
# Paste the content from the mise_env.lua artifact
```

Create the required `mise_path.lua` file (copy the content from `hooks/mise_path.lua` artifact):
```bash
# Create hooks/mise_path.lua
nano ~/.local/share/mise/plugins/git-branch-env/hooks/mise_path.lua
# Paste the content from the mise_path.lua artifact
```

### 3. Link the Plugin

```bash
mise plugin link git-branch-env ~/.local/share/mise/plugins/git-branch-env
```

### 4. Verify Installation

```bash
mise plugin ls
# Should show: git-branch-env
```

## Configuration

Add configuration to your project's `.mise.toml` or `mise.toml`:

```toml
[env._.git-branch-env]

# Default values (lowest priority)
[env._.git-branch-env.default]
API_ENV = "development"
DEBUG = "true"

# Exact branch matches
[env._.git-branch-env.branches.main]
DATABASE_URL = "postgresql://localhost/prod"
API_ENV = "production"
DEBUG = "false"

[env._.git-branch-env.branches.develop]
DATABASE_URL = "postgresql://localhost/dev"
API_ENV = "development"
DEBUG = "true"

[env._.git-branch-env.branches.staging]
DATABASE_URL = "postgresql://localhost/staging"
API_ENV = "staging"
DEBUG = "false"

# Pattern matching (prefix-based)
[env._.git-branch-env.patterns."feature/"]
DATABASE_URL = "postgresql://localhost/feature"
API_ENV = "feature"
DEBUG = "true"

[env._.git-branch-env.patterns."bugfix/"]
DATABASE_URL = "postgresql://localhost/bugfix"
API_ENV = "bugfix"
DEBUG = "true"

[env._.git-branch-env.patterns."hotfix/"]
DATABASE_URL = "postgresql://localhost/hotfix"
API_ENV = "hotfix"
DEBUG = "false"
```

## Automatic Branch Switching

No setup needed. mise re-evaluates the environment on every shell prompt
(or every `mise env`), and this plugin's branch detection is cheap enough
(no `git` subprocess) to just run every time, so a branch switch shows up
immediately with zero extra configuration:

```bash
git checkout main
echo $API_ENV  # production

git checkout develop
echo $API_ENV  # development - picked up on the very next prompt
```

`{ pass = "..." }` secrets keep following the TTL rule described above
(cached for up to 5s, independent of branch switching): if you rotate a
secret in `pass`, the new value shows up within 5 seconds either way.

**Compatibility note:** `MiseEnv` also returns `watch_files`/`cacheable`
hints pointing at the real resolved HEAD file (correct for worktrees and
submodules, unlike a hardcoded `.git/HEAD`), for mise builds that use them
to skip re-running this hook when the branch hasn't changed - this is the
return shape mise's own plugin docs describe, verified not to break
anything on mise 2026.10.18 (env vars are set correctly; no observable
skip-on-unchanged behavior either). If you're on a very different mise
version, confirm env vars are still set after upgrading this plugin
(`mise env`) before relying on it.

## Running a command on branch change (not just reading an env var)

Sometimes an env var isn't enough - you need an actual side effect, e.g.
selecting a Pulumi stack so a prompt plugin like oh-my-posh (which reads
Pulumi's locally *persisted* selected-stack state, not env vars) shows the
right one.

### `_run`: a command per branch, executed by the plugin itself

Any `default`/`branches.*`/`patterns.*` block can set a reserved `_run`
key - a shell command run once per *actual* branch change (tracked in a
small on-disk marker, no TTL), with every resolved env var for that branch
available to it:

```toml
[env._.git-branch-env.branches.main]
PULUMI_STACK = "production"
_run = "pulumi stack select $PULUMI_STACK"

[env._.git-branch-env.branches.develop]
PULUMI_STACK = "dev"
_run = "pulumi stack select $PULUMI_STACK"
```

- `_run` is never exported as an env var itself; it just reads whatever
  else the same block (and lower-priority ones) set, same priority rules
  as everything else (`default` -> `patterns` -> `branches`).
- Runs through a real shell (`sh -c`), so `&&`, pipes, `$VAR` expansion all
  work - unlike `{ pass = "..." }`, which only runs one fixed command.
- Hard 15s timeout; a failing or hanging command is skipped silently
  (same philosophy as `pass` - diagnose with `MISE_DEBUG=1`) and never
  retried on the same branch, so a broken command can't turn into "hangs
  every prompt" the way v1's `git` forking did.
- Only takes effect inside a git repo (there's no branch to key the
  "did it change" check on otherwise).

**Read this before using it:** `_run` is arbitrary command execution
triggered by `.mise.toml`, which is typically committed to the repo. If
you push this file to a shared or public repository, anyone who clones it
and has mise shell integration active runs whatever `_run` says the moment
they `cd` in, with no prompt. Treat a `_run`-bearing `.mise.toml` the same
way you'd treat a `post-checkout` hook with write access to your machine -
fine for a personal/private repo you fully control, risky for anything you
share.

### Alternative: a git `post-checkout` hook

If you don't want an executable command living in a (possibly shared)
`.mise.toml`, the same result without touching this plugin's config is a
plain git hook - it still reuses this plugin's resolved value via
`mise env --json`, so the branch-to-value mapping stays defined once:

```bash
# .git/hooks/post-checkout (chmod +x)
#!/usr/bin/env bash
# $3 = 1 only for a branch checkout (0 for a single-file checkout)
[ "$3" = "1" ] || exit 0

stack="$(mise env --json 2>/dev/null | jq -r '.PULUMI_STACK // empty')"
[ -n "$stack" ] && pulumi stack select "$stack" 2>/dev/null
exit 0
```

Notes:
- `.git/hooks/` isn't version-controlled either way - that's the point
  here: nothing executable ends up in a file someone else might clone. To
  share it deliberately with a team, point `core.hooksPath` at a tracked
  directory (e.g. `.githooks/`) instead, or use a hook manager (`lefthook`,
  `pre-commit`, husky, ...).
- A `.mise.toml` `[[watch_files]]` block with a `run` script looks like it
  should also work for this, and older docs (including an earlier version
  of this one) suggested it - **it doesn't**: verified by hand against
  mise 2026.10.18, under a properly activated shell, with a real `git
  checkout` in between - the `run` script never fired, with or without an
  intervening `mise env`/prompt. `watch_files`/`sources` only do something
  inside `mise watch <task>`, which needs a long-running
  `watchexec`-backed process in a dedicated terminal - a valid option too
  if you're fine with that tradeoff.
- Neither mechanism is Pulumi-specific - both apply to any tool that needs
  an imperative switch instead of an env var read.

## Usage

### Automatic Environment Loading

If you have mise shell integration enabled, environment variables are automatically set when you `cd` into the directory:

```bash
cd /path/to/your/project
echo $GIT_BRANCH        # outputs: main
echo $DATABASE_URL      # outputs: postgresql://localhost/prod
echo $API_ENV           # outputs: production
```

### Manual Environment Loading

```bash
# View environment variables
mise env

# Execute a command with the environment
mise exec -- printenv | grep -E 'GIT_BRANCH|DATABASE_URL|API_ENV'

# Run a task with the environment
mise run test
```

## Environment Variables

The plugin always exports these variables:

- **`GIT_BRANCH`**: The current git branch name (e.g., `feature/new-ui`)
- **`GIT_BRANCH_SAFE`**: Sanitized branch name safe for use in variable names (e.g., `FEATURE_NEW_UI`)

Plus any custom variables you configure based on branches, patterns, or defaults.

## Configuration Priority

Environment variables are applied in this order (later overrides earlier):

1. **Default** - Applied to all branches
2. **Patterns** - Applied if branch matches a pattern
3. **Branches** - Applied for exact branch matches (highest priority)

### Example:

```toml
[env._.git-branch-env.default]
LOG_LEVEL = "info"

[env._.git-branch-env.patterns."feature/"]
LOG_LEVEL = "debug"
FEATURE_FLAG = "true"

[env._.git-branch-env.branches."feature/experimental"]
LOG_LEVEL = "trace"
```

On branch `feature/experimental`:
- `LOG_LEVEL = "trace"` (from exact branch match)
- `FEATURE_FLAG = "true"` (from pattern match)

## Debugging

Enable debug logging:

```bash
MISE_DEBUG=1 mise env
```

Check if plugin is loaded:

```bash
mise plugin ls | grep git-branch-env
```

Test git branch detection:

```bash
git branch --show-current
```

## Global Configuration

You can also configure the plugin globally in `~/.config/mise/config.toml`:

```toml
[env._.git-branch-env.branches.main]
API_ENV = "production"
```

Project-specific configuration in `.mise.toml` will override global settings.

## Secrets Management with Pass

The plugin integrates with the [pass](https://www.passwordstore.org/) password manager to securely store and retrieve secrets.

### Prerequisites

Install and initialize `pass`:

```bash
# macOS
brew install pass

# Linux
apt-get install pass  # Debian/Ubuntu
yum install pass      # RHEL/CentOS

# Initialize with your GPG key
pass init your-gpg-key-id
```

### Storing Secrets

```bash
pass insert myapp/prod/database-password
pass insert myapp/prod/api-key
pass insert myapp/dev/database-password
```

### Using Secrets in Configuration

Use the `{ pass = "path/to/secret" }` syntax instead of plain strings:

```toml
[env._.git-branch-env.branches.main]
# Regular string values
DATABASE_URL = "postgresql://localhost/prod"
API_ENV = "production"
# Secrets from pass
DATABASE_PASSWORD = { pass = "myapp/prod/database-password" }
API_KEY = { pass = "myapp/prod/api-key" }
AWS_SECRET_ACCESS_KEY = { pass = "aws/production/secret-key" }

[env._.git-branch-env.branches.develop]
DATABASE_URL = "postgresql://localhost/dev"
DATABASE_PASSWORD = { pass = "myapp/dev/database-password" }
API_KEY = { pass = "myapp/dev/api-key" }

[env._.git-branch-env.patterns."feature/"]
# Feature branches can use dev secrets
DATABASE_PASSWORD = { pass = "myapp/dev/database-password" }
```

### How It Works

1. When the plugin encounters `{ pass = "path/to/secret" }`, it executes `pass show path/to/secret`
2. The secret value is retrieved and set as the environment variable
3. If `pass` fails (not installed or secret missing), the variable is silently skipped
4. Use `MISE_DEBUG=1 mise env` to debug secret retrieval issues

### Security Benefits

- Secrets are encrypted with GPG
- Secrets are not stored in plain text in configuration files
- Different secrets per branch (prod vs dev credentials)
- Secrets are only decrypted when needed

## Examples

### Simple Development/Production Split

```toml
[env._.git-branch-env.branches.main]
NODE_ENV = "production"

[env._.git-branch-env.branches.develop]
NODE_ENV = "development"
```

### Feature Branch Testing

```toml
[env._.git-branch-env.patterns."feature/"]
ENABLE_EXPERIMENTAL = "true"
TEST_MODE = "integration"
```

### Multiple Environments

```toml
[env._.git-branch-env.default]
APP_ENV = "development"
DATABASE_URL = "postgres://localhost:5432/app_dev"
REDIS_URL = "redis://localhost:6379"
LOG_LEVEL = "debug"

[env._.git-branch-env.branches.main]
APP_ENV = "production"
DATABASE_URL = "postgres://prod-db:5432/app"
REDIS_URL = "redis://prod-redis:6379"
LOG_LEVEL = "warn"

[env._.git-branch-env.branches.staging]
APP_ENV = "staging"
DATABASE_URL = "postgres://staging-db:5432/app"
REDIS_URL = "redis://staging-redis:6379"
LOG_LEVEL = "info"
```

## Troubleshooting

### Plugin Not Found

```bash
# Link the plugin again
mise plugin link git-branch-env ~/.local/share/mise/plugins/git-branch-env

# Verify
mise plugin ls
```

### Environment Variables Not Set

1. Make sure you're in a git repository: `git status`
2. Check your configuration syntax in `.mise.toml`
3. Enable debug mode: `MISE_DEBUG=1 mise env`
4. Verify shell integration is active: `which mise`

### Variables Not Updating After Branch Switch

Run:
```bash
# Reload mise environment
mise env
```

Or restart your shell if using shell integration.

## License

MIT

## Contributing

Contributions welcome! Please feel free to submit issues or pull requests.