-- hooks/mise_env.lua
-- Main hook function that sets environment variables based on git branch

function PLUGIN:MiseEnv(ctx)
    local cmd = require("cmd")
    local strings = require("strings")
    
    -- Get current git branch
    local function get_git_branch()
        -- First, check if we're in a git repository
        local git_check = cmd.exec("git rev-parse --git-dir 2>/dev/null")
        if not git_check then
            return nil
        end
        
        -- Try to get current branch
        local branch_result = cmd.exec("git branch --show-current 2>/dev/null")
        
        -- If empty or nil, try alternative method (for detached HEAD)
        if not branch_result then
            branch_result = cmd.exec("git rev-parse --abbrev-ref HEAD 2>/dev/null")
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
    
    -- Function to convert glob pattern to Lua pattern
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
        if pattern:find("*", 1, true) then
            -- It's a wildcard pattern - use glob matching
            local lua_pattern = glob_to_pattern(pattern)
            return branch:match(lua_pattern) ~= nil
        else
            -- Exact match
            return branch == pattern
        end
    end
    
    -- Function to count non-wildcard characters (for specificity)
    local function pattern_specificity(pattern)
        local non_wildcard = pattern:gsub("%*", "")
        return #non_wildcard
    end
    
    -- Function to add environment variables from a table
    local function add_env_vars(env_table)
        for key, value in pairs(env_table) do
            table.insert(env_vars, {
                key = key,
                value = tostring(value)
            })
        end
    end
    
    -- First, apply default environment variables
    add_env_vars(default_env)
    
    -- Collect all matching patterns with their specificity
    local matching_patterns = {}
    
    for pattern, pattern_env in pairs(patterns) do
        if matches_pattern(current_branch, pattern) then
            table.insert(matching_patterns, {
                pattern = pattern,
                env = pattern_env,
                specificity = pattern_specificity(pattern),
                has_wildcard = pattern:find("*", 1, true) ~= nil
            })
        end
    end
    
    -- Sort patterns by specificity (more specific = higher priority)
    -- Patterns with more non-wildcard characters are more specific
    table.sort(matching_patterns, function(a, b)
        -- First compare by specificity
        if a.specificity ~= b.specificity then
            return a.specificity < b.specificity
        end
        -- If same specificity, exact matches (no wildcard) come after wildcards
        if a.has_wildcard ~= b.has_wildcard then
            return a.has_wildcard
        end
        return false
    end)
    
    -- Apply matching patterns in order of increasing specificity
    for _, item in ipairs(matching_patterns) do
        add_env_vars(item.env)
    end
    
    -- Check for exact branch match (highest priority - overrides everything)
    if branches[current_branch] then
        add_env_vars(branches[current_branch])
    end
    
    return env_vars
end