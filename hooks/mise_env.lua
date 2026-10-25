-- hooks/mise_env.lua
-- Sets environment variables based on the current git branch.
--
-- v2: branch detection reads .git/HEAD directly instead of shelling out to
-- `git` (v1 forked up to 3 `git` processes per invocation, repeated on every
-- shell prompt -> under process/thread pressure this caused a runaway fork
-- storm and froze the whole shell). The optional `pass` secret lookup is the
-- only remaining subprocess call: it now has a hard timeout (a stuck
-- gpg-agent/pinentry can no longer hang the shell forever) and a short TTL
-- cache so it isn't re-invoked on every single prompt.
--
-- v2.1: MiseEnv now returns { env, cacheable = true, watch_files = {head} },
-- mise's own hook-caching mechanism. mise re-runs this whole hook (branch
-- detection, pattern/priority merge, `pass` lookups) only when the resolved
-- HEAD file actually changes, instead of on every single shell prompt -
-- making the README's old workarounds (manual [[watch_files]] block, a
-- git post-checkout hook, a wrapping `git` shell function) unnecessary:
-- mise now watches the right file on its own, including for worktrees and
-- submodules where it is not literally ".git/HEAD".
--
-- v2.2: a block (default/pattern/branch) may set a reserved `_run` key -
-- a shell command executed once per *actual* branch change (tracked in a
-- small state file, same idea as the `pass` cache but without a TTL), with
-- every resolved env var for that branch available to it via $VAR. This is
-- arbitrary command execution driven by .mise.toml: see the README section
-- "Running a command on branch change" for the threat model before using
-- it on a repo whose config you don't fully trust.

local file = require("file")
local cmd = require("cmd")

local PASS_TIMEOUT_SECONDS = 5
local PASS_CACHE_TTL_SECONDS = 5
local PASS_CACHE_DIR = (os.getenv("TMPDIR") or "/tmp") .. "/mise-git-branch-env-pass-cache"

local RUN_TIMEOUT_SECONDS = 15
local RUN_STATE_DIR = (os.getenv("TMPDIR") or "/tmp") .. "/mise-git-branch-env-run-state"

-- POSIX single-quote escaping: wraps `s` so it is passed to /bin/sh as one
-- literal argument, regardless of its content (spaces, `"`, `$`, backticks,
-- `;`, etc). Needed because PASS_CACHE_DIR is derived from the TMPDIR env
-- var and secret_path comes from user config - both untrusted input that
-- would otherwise be interpolated straight into a shell command string.
local function shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function read_file(path)
    local ok, content = pcall(file.read, path)
    if ok then return content end
    return nil
end

-- Walk up from start_dir looking for .git, same resolution order git itself
-- uses. Handles both a normal repo (.git is a directory) and a worktree or
-- submodule (.git is a file containing "gitdir: <path>"). No subprocess.
local function find_git_dir(start_dir)
    local dir = start_dir
    for _ = 1, 64 do -- sane upper bound, guards against a broken/looping fs
        local git_path = file.join_path(dir, ".git")
        if file.exists(git_path) then
            local stat = file.stat(git_path)
            if stat and stat.is_dir then
                return git_path
            end
            local content = read_file(git_path)
            local gitdir = content and content:match("gitdir:%s*(.-)%s*$")
            if gitdir then
                if not gitdir:match("^/") and not gitdir:match("^%a:[\\/]") then
                    gitdir = file.join_path(dir, gitdir)
                end
                return gitdir
            end
            return nil
        end
        local parent = dir:match("^(.*)[/\\][^/\\]+$")
        if not parent or parent == dir then break end
        dir = parent
    end
    return nil
end

-- Returns (branch, head_path). head_path is the actual HEAD file that was
-- read - under .git/worktrees/<name>/ for a worktree, .git/modules/<name>/
-- for a submodule, following find_git_dir's gitdir: resolution - so the
-- caller can watch the file that genuinely changes on checkout, not a
-- hardcoded ".git/HEAD" that doesn't exist for those cases.
local function get_current_branch(start_dir)
    local git_dir = find_git_dir(start_dir or ".")
    if not git_dir then return nil, nil end

    local head_path = file.join_path(git_dir, "HEAD")
    local head = read_file(head_path)
    if not head then return nil, nil end

    local branch = head:match("^ref:%s*refs/heads/(.-)%s*$")
    if branch then return branch, head_path end

    -- Detached HEAD: mirror v1's behaviour (`git rev-parse --abbrev-ref HEAD`
    -- prints the literal string "HEAD" in this case).
    return "HEAD", head_path
end

local function sanitize_branch_name(branch)
    if not branch then return "UNKNOWN" end
    return (branch:gsub("/", "_"):gsub("%-", "_"):upper())
end

local function glob_to_pattern(glob)
    local pattern = glob:gsub("([%^%$%(%)%%%.%[%]%+%-%?])", "%%%1")
    pattern = pattern:gsub("%*", ".*")
    return "^" .. pattern .. "$"
end

local function matches_pattern(branch, pattern)
    if pattern:sub(-1) == "*" then
        return branch:match(glob_to_pattern(pattern)) ~= nil
    end
    return branch:sub(1, #pattern) == pattern
end

local function pass_cache_path(secret_path)
    local safe = secret_path:gsub("[^%w]", "_")
    return file.join_path(PASS_CACHE_DIR, safe)
end

local function read_pass_cache(secret_path)
    local f = io.open(pass_cache_path(secret_path), "r")
    if not f then return nil end
    local ts = f:read("*l")
    local value = f:read("*l")
    f:close()
    if not ts or not value then return nil end
    if (os.time() - tonumber(ts)) > PASS_CACHE_TTL_SECONDS then return nil end
    return value
end

local function write_pass_cache(secret_path, value)
    -- Secrets are cached in plaintext on disk, so the directory and the
    -- cache file must be owner-only (0700/0600): anything looser would let
    -- other local users read decrypted `pass` secrets out of TMPDIR.
    local quoted_dir = shell_quote(PASS_CACHE_DIR)
    os.execute('mkdir -p -m 700 ' .. quoted_dir .. ' 2>/dev/null && chmod 700 ' .. quoted_dir .. ' 2>/dev/null')

    local path = pass_cache_path(secret_path)
    local f = io.open(path, "w")
    if f then
        f:write(tostring(os.time()) .. "\n" .. value .. "\n")
        f:close()
        os.execute('chmod 600 ' .. shell_quote(path) .. ' 2>/dev/null')
    end
end

local function resolve_pass_secret(secret_path)
    local cached = read_pass_cache(secret_path)
    if cached then return cached end

    local ok, result = pcall(cmd.exec, "pass show " .. shell_quote(secret_path), { timeout = PASS_TIMEOUT_SECONDS })
    if not ok or not result then
        -- Silently skip, same as v1: a user can debug with MISE_DEBUG=1.
        return nil
    end

    local value = result:match("^%s*(.-)%s*$")
    write_pass_cache(secret_path, value)
    return value
end

-- Keyed by head_path (unique per repo/worktree) so each worktree tracks its
-- own "last branch seen" independently, same reasoning as watch_files.
local function run_state_path(head_path)
    local safe = head_path:gsub("[^%w]", "_")
    return file.join_path(RUN_STATE_DIR, safe)
end

local function read_last_branch(head_path)
    local f = io.open(run_state_path(head_path), "r")
    if not f then return nil end
    local branch = f:read("*l")
    f:close()
    return branch
end

local function write_last_branch(head_path, branch)
    local quoted_dir = shell_quote(RUN_STATE_DIR)
    os.execute('mkdir -p -m 700 ' .. quoted_dir .. ' 2>/dev/null && chmod 700 ' .. quoted_dir .. ' 2>/dev/null')

    local path = run_state_path(head_path)
    local f = io.open(path, "w")
    if f then
        f:write(tostring(branch) .. "\n")
        f:close()
        os.execute('chmod 600 ' .. shell_quote(path) .. ' 2>/dev/null')
    end
end

local function env_entries_to_table(entries)
    local t = {}
    for _, entry in ipairs(entries) do
        t[entry.key] = entry.value
    end
    return t
end

-- True if `_run` is set anywhere in the config (default, any pattern, any
-- branch) - not just on the currently-resolved block. Gates all the state
-- file I/O below, so a project that never uses `_run` pays nothing for it
-- on every single prompt.
local function any_run_defined(default_env, branches, patterns)
    if default_env["_run"] ~= nil then return true end
    for _, env in pairs(branches) do
        if env["_run"] ~= nil then return true end
    end
    for _, env in pairs(patterns) do
        if env["_run"] ~= nil then return true end
    end
    return false
end

-- Runs `command` through a real shell (so $VARS, &&, pipes etc. all work)
-- with every resolved env var for this branch available to it, but only
-- once per actual branch change - never on every prompt. The "last seen"
-- marker is tracked independently of whether the *current* branch defines
-- `_run`: otherwise bouncing through a branch with no `_run` (A -> B -> A,
-- B undefined) would never update the marker on B, making the return to A
-- look unchanged and silently skip a re-run that should happen. Best-
-- effort: a failing or timed-out command is silently skipped (same
-- philosophy as `pass`), and the marker is still updated so a broken
-- command doesn't get retried on every single prompt.
local function run_on_branch_change(head_path, current_branch, command, resolved_env, feature_in_use)
    if not feature_in_use then return end
    if read_last_branch(head_path) == current_branch then return end

    if command then
        pcall(cmd.exec, "sh -c " .. shell_quote(command), {
            env = env_entries_to_table(resolved_env),
            timeout = RUN_TIMEOUT_SECONDS,
        })
    end

    write_last_branch(head_path, current_branch)
end

function PLUGIN:MiseEnv(ctx)
    local config = ctx.options or {}
    local branches = config.branches or {}
    local patterns = config.patterns or {}
    local default_env = config.default or {}

    local current_branch, head_path = get_current_branch(ctx.config_root or ".")

    local env_vars = {}
    -- Priority 0=default, 1=pattern, 2=exact branch (same semantics as v1).
    local applicable_configs = { { env = default_env, priority = 0, specificity = 0 } }

    if current_branch then
        table.insert(env_vars, { key = "GIT_BRANCH", value = current_branch })
        table.insert(env_vars, { key = "GIT_BRANCH_SAFE", value = sanitize_branch_name(current_branch) })

        for pattern, pattern_env in pairs(patterns) do
            if matches_pattern(current_branch, pattern) then
                table.insert(applicable_configs, { env = pattern_env, priority = 1, specificity = #pattern })
            end
        end

        if branches[current_branch] then
            table.insert(applicable_configs, { env = branches[current_branch], priority = 2, specificity = #current_branch })
        end
    end

    table.sort(applicable_configs, function(a, b)
        if a.priority ~= b.priority then
            return a.priority < b.priority
        end
        return a.specificity < b.specificity
    end)

    -- `_run` is a reserved key, not an env var: the highest-priority block
    -- that sets it wins (same "later overwrites earlier" rule as any other
    -- key, since applicable_configs is sorted lowest-to-highest priority).
    local run_command = nil
    for _, config_item in ipairs(applicable_configs) do
        for key, value in pairs(config_item.env) do
            if key == "_run" then
                run_command = tostring(value)
            else
                local final_value
                if type(value) == "table" and value.pass then
                    final_value = resolve_pass_secret(value.pass)
                else
                    final_value = tostring(value)
                end
                if final_value ~= nil then
                    table.insert(env_vars, { key = key, value = final_value })
                end
            end
        end
    end

    -- head_path is only set when we're inside a git repo (see
    -- get_current_branch). Outside a git repo there is nothing branch-
    -- related to key `_run`'s change-detection or the watch_files hint on,
    -- so both are skipped (the hook keeps running every time as before -
    -- it's cheap: just the `default` config block, no git I/O).
    if head_path then
        run_on_branch_change(head_path, current_branch, run_command, env_vars, any_run_defined(default_env, branches, patterns))
        return { env = env_vars, cacheable = true, watch_files = { head_path } }
    end
    return { env = env_vars }
end
