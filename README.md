# Mise Git Branch Environment Plugin

A mise environment plugin that automatically sets environment variables based on your current git branch.

## Features

- 🔄 Automatically detects current git branch
- 🎯 Set different environment variables per branch
- 🔍 Pattern matching for branch prefixes (e.g., `feature/*`, `bugfix/*`)
- 📝 Exports `GIT_BRANCH` and `GIT_BRANCH_SAFE` variables
- ⚙️ Configurable defaults with branch-specific overrides

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

To make mise automatically reload environment variables when you switch git branches, use mise's `watch_files` configuration.

### Setup: Add Watch Configuration

Add this to your `.mise.toml`:

```toml
# Watch the git HEAD file for branch changes
[[watch_files]]
patterns = [".git/HEAD"]
run = """
#!/usr/bin/env bash
echo '⏳ Updating git branch environment...'
echo '☑️ Done!'
"""

[env._.git-branch-env.branches.main]
DATABASE_URL = "postgresql://localhost/prod"
API_ENV = "production"

[env._.git-branch-env.branches.develop]
DATABASE_URL = "postgresql://localhost/dev"
API_ENV = "development"
```

The `[[watch_files]]` section tells mise to:
- Monitor `.git/HEAD` for changes (which happens when you switch branches)
- Run the specified script when changes are detected
- Automatically reload the environment

### How it works

1. You run `git checkout develop` or `git switch feature/new-ui`
2. Git updates `.git/HEAD` to point to the new branch
3. Mise detects the file change
4. Mise runs the watch script (optional feedback)
5. Mise automatically reloads environment variables from the plugin

### Testing the automatic reload

```bash
# Initial branch
git checkout main
echo $API_ENV  # Shows: production

# Switch branch - environment reloads automatically!
git checkout develop
# Output: ⏳ Updating git branch environment...
#         ☑️ Done!
echo $API_ENV  # Shows: development (automatically updated!)
```

### Optional: Watch Multiple Files

You can watch additional files that might affect your environment:

```toml
[[watch_files]]
patterns = [".git/HEAD", ".env.local", "config/*.yml"]
run = """
#!/usr/bin/env bash
echo '⏳ Environment updated!'
"""
```

### Alternative Methods

If you prefer not to use watch_files:

**Option 1: Git Post-Checkout Hook**

Create `.git/hooks/post-checkout`:
```bash
#!/bin/bash
if command -v mise &> /dev/null; then
    touch .mise.toml
fi
```

**Option 2: Shell Function**

Add to `~/.zshrc`:
```bash
git() {
    command git "$@"
    local git_result=$?
    if [[ $git_result -eq 0 ]] && [[ "$1" =~ ^(checkout|switch)$ ]]; then
        [[ -f ".mise.toml" ]] && touch .mise.toml
    fi
    return $git_result
}
```

**Option 3: Manual Reload**
```bash
cd .  # Trigger mise hook
```

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