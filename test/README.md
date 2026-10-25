# Test fixture for git-branch-env

Scaffolds a scratch git repo (plus a worktree and a non-git directory)
exercising every configuration option the plugin supports - `default`,
exact `branches`, prefix/glob `patterns`, priority rules, detached HEAD,
worktree HEAD resolution, and (optionally) `pass` secrets - and links this
checkout of the plugin into it so you can try it end to end.

## Quickstart

```bash
test/setup.sh                 # creates a fresh fixture in a mktemp dir
# or: test/setup.sh /path/you/choose   (must not already exist)
```

The script prints the paths it created. Follow `TEST.md` (also copied as
`TEST.md` inside the generated demo repo) for the full walkthrough of every
scenario, with expected output for each.

```bash
test/cleanup.sh <output-dir>  # tears the fixture down when you're done
```

Nothing here touches your real `pass` password store or any other project -
everything lives under the directory `setup.sh` created (or the one you
passed it).

**Note on `mise plugin link`:** `setup.sh` only calls it if the plugin isn't
already registered, and never with `--force`. This plugin's own directory
already sits at mise's conventional plugin path
(`~/.local/share/mise/plugins/git-branch-env`), so a forced re-link there
has previously deleted that directory and replaced it with a symlink
pointing at itself (an unrecoverable `ELOOP`, fixed at the time by
re-cloning from `origin`). Don't pass `--force` to `mise plugin link`
against this path.
