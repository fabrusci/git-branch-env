#!/usr/bin/env bash
# test/cleanup.sh - tears down a fixture created by test/setup.sh.
#
# Usage:
#   test/cleanup.sh <output-dir>
#
# <output-dir> is the directory setup.sh printed/accepted (the one
# containing demo/, demo-worktree/, demo-outside-git/) - not the demo repo
# itself.
set -euo pipefail

OUT_DIR="${1:-}"
if [ -z "$OUT_DIR" ] || [ ! -d "$OUT_DIR" ]; then
    echo "usage: test/cleanup.sh <output-dir-from-setup.sh>" >&2
    exit 1
fi
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

DEMO="$OUT_DIR/demo"
WT="$OUT_DIR/demo-worktree"

if [ -d "$DEMO/.git" ] && [ -d "$WT" ]; then
    echo "==> Removing worktree $WT"
    git -C "$DEMO" worktree remove --force "$WT" 2>/dev/null || true
fi

echo "==> Removing $OUT_DIR"
rm -rf "$OUT_DIR"

echo "==> Done. Note: this does not unlink the plugin (mise plugin link is"
echo "    reusable across fixtures) and never touches your real 'pass' store."
