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
    
    -- Separate exact patterns from wildcard patterns
    local exact_patterns = {}
    local wildcard_patterns = {}
    
    for pattern, pattern_env in pairs(patterns) do
        if pattern:find("*", 1, true) then
            table.insert(wildcard_patterns, {pattern = pattern, env = pattern_env})
        else
            exact_patterns[pattern] = pattern_env
        end
    end
    
    -- Apply wildcard patterns first (lower priority)
    for _, item in ipairs(wildcard_patterns) do
        local pattern = item.pattern
        local pattern_env = item.env
        
        -- Check if pattern ends with wildcard
        if pattern:sub(-1) == "*" then
            -- Remove the * and check if branch starts with the prefix
            local prefix = pattern:sub(1, -2)
            if current_branch:sub(1, #prefix) == prefix then
                add_env_vars(pattern_env)
            end
        elseif pattern:sub(1, 1) == "*" then
            -- Suffix matching: *-staging, *-prod
            local suffix = pattern:sub(2)
            if current_branch:sub(-#suffix) == suffix then
                add_env_vars(pattern_env)
            end
        else
            -- Middle wildcard: release-*-final
            local before, after = pattern:match("^(.*)%*(.*)$")
            if before and after then
                if current_branch:sub(1, #before) == before and 
                   current_branch:sub(-#after) == after then
                    add_env_vars(pattern_env)
                end
            end
        end
    end
    
    -- Apply exact pattern matches (higher priority than wildcards)
    for pattern, pattern_env in pairs(exact_patterns) do
        -- Exact match on the full branch name
        if current_branch == pattern then
            add_env_vars(pattern_env)
        end
    end
    
    -- Check for exact branch match (highest priority - overrides everything)
    if branches[current_branch] then
        add_env_vars(branches[current_branch])
    end
    
    return env_vars
end