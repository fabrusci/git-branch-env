#!/usr/bin/env bash
# test/setup.sh - scaffolds a scratch fixture exercising every git-branch-env
# option (default/branches/patterns, pattern priority, exact-over-pattern,
# detached HEAD, a worktree, a non-git directory, and an optional `pass`
# secrets branch), then links this checkout of the plugin into it.
#
# Usage:
#   test/setup.sh [output-dir]
#
# output-dir defaults to a fresh mktemp directory. If you pass one
# explicitly, it must not already exist (this script never deletes
# pre-existing content).
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_NAME="$(basename "$PLUGIN_DIR")"

if [ -n "${1:-}" ]; then
    OUT_DIR="$1"
    if [ -e "$OUT_DIR" ]; then
        echo "error: '$OUT_DIR' already exists - pick a different path or remove it first" >&2
        exit 1
    fi
    mkdir -p "$OUT_DIR"
else
    OUT_DIR="$(mktemp -d -t git-branch-env-test-XXXXXX)"
fi
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

DEMO="$OUT_DIR/demo"
WT="$OUT_DIR/demo-worktree"
OUTSIDE="$OUT_DIR/demo-outside-git"

echo "==> Scaffolding in $OUT_DIR"

mkdir -p "$DEMO"
cd "$DEMO"
git init -q
git config user.email "demo@example.com"
git config user.name "git-branch-env test"

echo "# git-branch-env demo" > README.md
git add README.md
git commit -q -m "init"

cat > .mise.toml <<'EOF'
[settings]
experimental = true

[env._.git-branch-env]

# Lowest priority: applied on every branch, and even outside a git repo.
[env._.git-branch-env.default]
APP_ENV = "development"
LOG_LEVEL = "info"
PATTERN_SOURCE = "none"

# Exact branch matches (highest priority).
[env._.git-branch-env.branches.main]
APP_ENV = "production"
LOG_LEVEL = "warn"
DATABASE_URL = "postgresql://localhost/prod"

[env._.git-branch-env.branches.develop]
APP_ENV = "development"
LOG_LEVEL = "debug"
DATABASE_URL = "postgresql://localhost/dev"

[env._.git-branch-env.branches.staging]
APP_ENV = "staging"
LOG_LEVEL = "info"
DATABASE_URL = "postgresql://localhost/staging"

# Exact match beats the "feature/" pattern below - but ONLY on this branch.
[env._.git-branch-env.branches."feature/experimental"]
APP_ENV = "trace-feature"
LOG_LEVEL = "trace"

# Pattern matches (prefix: branch must literally start with this string).
[env._.git-branch-env.patterns."feature/"]
APP_ENV = "feature"
LOG_LEVEL = "debug"
FEATURE_FLAG = "true"
PATTERN_SOURCE = "feature-prefix"

[env._.git-branch-env.patterns."bugfix/"]
APP_ENV = "bugfix"
LOG_LEVEL = "debug"
PATTERN_SOURCE = "bugfix-prefix"

[env._.git-branch-env.patterns."hotfix/"]
APP_ENV = "hotfix"
LOG_LEVEL = "warn"
PATTERN_SOURCE = "hotfix-prefix"

# Glob pattern (trailing *): matches anything starting with "feat", so it
# overlaps with "feature/" above on branches like feature/new-ui-v2.
# "feature/" (8 chars) is longer/more specific than "feat*" (5 chars), so on
# an overlap "feature/"'s values win - that's the "longer pattern wins" rule.
[env._.git-branch-env.patterns."feat*"]
PATTERN_SOURCE = "feat-glob"

# --- pass secret integration (optional, disabled by default) ---
# Uncomment and point at a real entry from your own `pass ls` (or create a
# disposable one with `pass insert test/git-branch-env-demo/secret`), then
# checkout the "secrets-demo" branch to test {pass=...} resolution, the 5s
# TTL cache, and the 700/600 permission hardening on the on-disk cache file.
# See TEST.md section 10.
# [env._.git-branch-env.branches.secrets-demo]
# DEMO_SECRET = { pass = "your/own/pass/entry" }
EOF

git add .mise.toml
git commit -q -m "add mise.toml"

# Branches
git branch develop
git branch staging
git checkout -q -b feature/experimental
git checkout -q -b feature/new-ui-v2 main
git checkout -q -b feat-quick main
git checkout -q -b bugfix/login-fix main
git checkout -q -b hotfix/urgent-payment main
git checkout -q -b chore/cleanup-temp main
git checkout -q -b secrets-demo main
git checkout -q -b worktree-demo main
git checkout -q main

git worktree add -q "$WT" worktree-demo
cp .mise.toml "$WT/.mise.toml"

mkdir -p "$OUTSIDE"
cat > "$OUTSIDE/.mise.toml" <<'EOF'
[settings]
experimental = true

[env._.git-branch-env]

[env._.git-branch-env.default]
APP_ENV = "development"
LOG_LEVEL = "info"
PATTERN_SOURCE = "none"
EOF

cp "$PLUGIN_DIR/test/TEST.md" "$DEMO/TEST.md" 2>/dev/null || true

echo "==> Trusting generated configs"
mise trust "$DEMO/.mise.toml"
mise trust "$WT/.mise.toml"
mise trust "$OUTSIDE/.mise.toml"

echo "==> Checking plugin '$PLUGIN_NAME' is registered"
if ! mise plugin ls 2>/dev/null | grep -qx "$PLUGIN_NAME"; then
    # Only link if it isn't already registered. Never pass --force here:
    # PLUGIN_DIR already *is* mise's conventional plugin path
    # (~/.local/share/mise/plugins/<name>), so a forced re-link can delete
    # and recreate that exact path as a symlink pointing at itself.
    mise plugin link "$PLUGIN_NAME" "$PLUGIN_DIR"
else
    echo "    already registered, pointing at: (see 'mise plugin ls' for details)"
fi

cat <<EOF

==> Done.

  Demo repo:        $DEMO
  Worktree:         $WT  (branch: worktree-demo)
  Outside git repo: $OUTSIDE

Next: cd "$DEMO" and follow test/TEST.md (copied alongside as TEST.md) for
the full walkthrough, or test/cleanup.sh "$OUT_DIR" when you're done.
EOF
