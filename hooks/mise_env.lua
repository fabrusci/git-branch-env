-- hooks/mise_env.lua
-- Main hook function that sets environment variables based on git branch

function PLUGIN:MiseEnv(ctx)
    local cmd = require("cmd")
    local strings = require("strings")
    
    -- Get current git branch
    local function get_git_branch()
        -- First, check if we're in a git repository
        local ok, git_check = pcall(cmd.exec, "git rev-parse --git-dir 2>/dev/null")
        if not ok or not git_check or git_check:match("^%s*$") then
            return nil
        end
        
        -- Try to get current branch
        local ok2, branch_result = pcall(cmd.exec, "git branch --show-current 2>/dev/null")
        
        -- If empty or nil, try alternative method (for detached HEAD)
        if not ok2 or not branch_result then
            local ok3, alt_result = pcall(cmd.exec, "git rev-parse --abbrev-ref HEAD 2>/dev/null")
            if not ok3 then
                return nil
            end
            branch_result = alt_result
        end
        
        -- Final check - return nil if still no result
        if not branch_result then
            return nil
        end
        
        -- Manual trim instead of using strings.trim to avoid nil issues
        local trimmed = branch_result:match("^%s*(.-)%s*$")
        
        -- Return nil if empty after trimming
        if not trimmed or trimmed == "" then
            return nil
        end
        
        return trimmed
    end
    
    -- Sanitize branch name for use in variable names
    local function sanitize_branch_name(branch)
        if not branch then return "UNKNOWN" end
        
        local sanitized = branch
        sanitized = sanitized:gsub("/", "_")
        sanitized = sanitized:gsub("-", "_")
        sanitized = sanitized:upper()
        
        return sanitized
    end
    
    -- Get the current branch
    local current_branch = get_git_branch()
    
    -- If not in a git repository, return empty
    if not current_branch then
        return {}
    end
    
    local env_vars = {}
    
    -- Always set GIT_BRANCH and GIT_BRANCH_SAFE
    table.insert(env_vars, {
        key = "GIT_BRANCH",
        value = current_branch
    })
    
    table.insert(env_vars, {
        key = "GIT_BRANCH_SAFE",
        value = sanitize_branch_name(current_branch)
    })
    
    -- Get configuration from context options
    local config = ctx.options or {}
    local branches = config.branches or {}
    local patterns = config.patterns or {}
    local default_env = config.default or {}
    
    -- Function to convert a simple glob pattern to a Lua pattern
    local function glob_to_pattern(glob)
        -- Escape special Lua pattern characters except *
        local pattern = glob:gsub("([%^%$%(%)%%%.%[%]%+%-%?])", "%%%1")
        -- Replace * with .*
        pattern = pattern:gsub("%*", ".*")
        -- Anchor the pattern to match the whole string
        return "^" .. pattern .. "$"
    end
    
    -- Function to check if a branch matches a pattern
    local function matches_pattern(branch, pattern)
        if pattern:sub(-1) == "*" then
            -- It's a glob pattern (e.g., "feature/*")
            local lua_pattern = glob_to_pattern(pattern)
            return branch:match(lua_pattern) ~= nil
        else
            -- It's a prefix pattern (e.g., "feature/")
            return branch:sub(1, #pattern) == pattern
        end
    end
    
    -- Collect all applicable environment configurations in order of priority
    -- The list will be sorted later, so we add them in any order.
    -- Priority 0=default, 1=pattern, 2=exact branch
    local applicable_configs = {}
    
    -- 1. Add default config (lowest priority)
    table.insert(applicable_configs, { env = default_env, priority = 0, specificity = 0 })

    -- 2. Collect all matching patterns
    for pattern, pattern_env in pairs(patterns) do
        if matches_pattern(current_branch, pattern) then
            table.insert(applicable_configs, {
                env = pattern_env,
                priority = 1,
                -- Specificity is the length of the pattern string itself.
                -- "feature/ui/" is longer and thus more specific than "feature/".
                specificity = #pattern
            })
        end
    end
    
    -- 3. Add exact branch match (highest priority)
    if branches[current_branch] then
        table.insert(applicable_configs, { env = branches[current_branch], priority = 2, specificity = #current_branch })
    end
    
    -- Sort configurations: first by priority level, then by specificity (length)
    table.sort(applicable_configs, function(a, b)
        if a.priority ~= b.priority then
            return a.priority < b.priority
        end
        return a.specificity < b.specificity
    end)
    
    -- Apply all configurations in the final sorted order.
    -- Later items will overwrite keys from earlier ones.
    for _, config_item in ipairs(applicable_configs) do
      for key, value in pairs(config_item.env) do
          local final_value
          if type(value) == "table" and value.pass then
              -- Value is a table with a 'pass' key, fetch from pass
              local pass_path = value.pass
              local ok, pass_result = pcall(cmd.exec, "pass show " .. pass_path)

              if ok and pass_result then
                  -- pass returns the secret with a trailing newline, so we trim it.
                  final_value = pass_result:match("^%s*(.-)%s*$")
              else
                  -- Silently fail, but a user can debug with MISE_DEBUG=1
                  -- This prevents breaking the env if 'pass' is not installed or the secret is missing.
                  final_value = nil
              end
          else
              -- It's a regular string value
              final_value = tostring(value)
          end

          if final_value ~= nil then
              table.insert(env_vars, { key = key, value = final_value })
          end
      end
    end

    return env_vars
end