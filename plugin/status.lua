-- Status detection module for WezTerm Agent Deck
-- Detects agent status from terminal pane text content via pattern matching
local wezterm = require('wezterm')

local M = {}

-- Default status patterns (used if agent doesn't override)
local default_patterns = {
    -- Working patterns - agent is actively processing.
    -- These are AUTHORITATIVE: if a working indicator is present, the agent
    -- is busy regardless of any stale prompts visible in scrollback.
    -- Only include reliable UI indicators, not generic words that could
    -- appear in tool output (e.g., avoid bare 'reading', 'writing').
    working = {
        'esc to interrupt',
        'esc interrupt',
        'ctrl%+c to interrupt',
        'thinking%.%.%.',
        'pondering%.%.%.',
        'generating%.%.%.',
        'delegating work',
        'planning next steps',
        'gathering context',
        'searching the codebase',
        'searching the web',
        'making edits',
        'running commands',
        'gathering thoughts',
        'considering next steps',
        'building tool call',
    },

    -- Waiting patterns - agent needs user input.
    -- Only checked AFTER working patterns — a busy indicator always wins
    -- over a stale permission prompt left in scrollback.
    waiting = {
        'esc to cancel',
        'yes, allow once',
        'yes, allow always',
        'allow once',
        'allow always',
        'deny',
        'no, and tell',
        'do you trust',
        'run this command',
        'execute this',
        'continue%?',
        'proceed%?',
        '%(y/n%)',
        '%(Y/n%)',
        '%[y/n%]',
        '%[Y/n%]',
        '%(y/N%)',
        '%(Y/N%)',
        '%[y/N%]',
        '%[Y/N%]',
        'approve this plan',
        'do you want to proceed',
        'press enter to continue',
        -- Menu selection indicators
        '' .. ' Yes', -- Nerd font arrow
        '' .. ' No',
        -- Plan mode ask tool patterns (OpenCode v1.1.18+)
        'enter confirm',
        'esc dismiss',
        'type your own answer',
    },

    -- Idle patterns - agent is ready for input
    -- Claude Code uses ❯ (U+276F), not ASCII >
    idle = {
        '^>%s*$', -- Empty > prompt
        '^> $', -- > prompt with space
        '^>$', -- Just > at end of line
        '^❯%s*$', -- Unicode ❯ prompt
        '^❯ $',
        '^❯$',
    },
}

-- ANSI escape code pattern
local ANSI_PATTERN = '\27%[%d*;?%d*;?%d*[A-Za-z]'
local OSC_PATTERN = '\27%].-\007' -- OSC sequences ending in BEL
local OSC_ST_PATTERN = '\27%].-\27\\' -- OSC sequences ending in ST

--- Strip ANSI escape codes from text
---@param text string Text with potential ANSI codes
---@return string Cleaned text
local function strip_ansi(text)
    if not text then
        return ''
    end

    -- Remove various escape sequences
    local result = text
    result = result:gsub(ANSI_PATTERN, '')
    result = result:gsub(OSC_PATTERN, '')
    result = result:gsub(OSC_ST_PATTERN, '')
    result = result:gsub('\27%[%?%d+[hl]', '') -- Mode setting sequences
    result = result:gsub('\27%[%d*[ABCDEFGJKST]', '') -- Cursor movement
    result = result:gsub('\27%[%d*;%d*[Hf]', '') -- Cursor positioning
    result = result:gsub('\27%[%d*m', '') -- SGR sequences
    result = result:gsub('\27%[[0-9;]*m', '') -- Extended SGR
    result = result:gsub('\r', '') -- Carriage return

    return result
end

--- Check if text matches any pattern in a list
---@param text string Text to check
---@param patterns table List of patterns
---@return boolean True if any pattern matches
local function matches_any(text, patterns)
    if not text or not patterns then
        return false
    end

    local text_lower = text:lower()

    for _, pattern in ipairs(patterns) do
        -- Try pattern match first
        local success, result = pcall(function()
            return text_lower:find(pattern:lower())
        end)

        if success and result then
            return true
        end

        -- Fallback to plain text search if pattern fails
        if not success then
            if text_lower:find(pattern:lower(), 1, true) then
                return true
            end
        end
    end

    return false
end

--- Get the last N lines from text
---@param text string Full text
---@param n number Number of lines to get
---@return string Last N lines
local function get_last_lines(text, n)
    if not text then
        return ''
    end

    local lines = {}
    for line in text:gmatch('[^\n]+') do
        table.insert(lines, line)
    end

    local start = math.max(1, #lines - n + 1)
    local result = {}

    for i = start, #lines do
        table.insert(result, lines[i])
    end

    return table.concat(result, '\n')
end

--- Get patterns for an agent (custom or default)
---@param agent_type string Agent type name
---@param config table Plugin configuration
---@return table Patterns table with working, waiting, idle keys
local function get_patterns_for_agent(agent_type, config)
    local agent_config = config.agents[agent_type]

    if agent_config and agent_config.status_patterns then
        -- Merge custom patterns with defaults
        return {
            working = agent_config.status_patterns.working or default_patterns.working,
            waiting = agent_config.status_patterns.waiting or default_patterns.waiting,
            idle = agent_config.status_patterns.idle or default_patterns.idle,
        }
    end

    return default_patterns
end

--- Detect agent status from pane content
---@param pane userdata WezTerm pane object
---@param agent_type string Agent type name
---@param config table Plugin configuration
---@return string Status: 'working', 'waiting', 'idle', or 'inactive'
function M.detect_status(pane, agent_type, config)
    if not agent_type then
        return 'inactive'
    end

    -- Get pane text content
    local success, text = pcall(function()
        return pane:get_lines_as_text(config.max_lines or 100)
    end)

    if not success or not text then
        -- Fallback: try logical lines
        success, text = pcall(function()
            return pane:get_logical_lines_as_text(config.max_lines or 100)
        end)
    end

    if not success or not text or text == '' then
        return 'inactive'
    end

    -- Strip ANSI codes
    local clean_text = strip_ansi(text)

    -- Get patterns for this agent
    local patterns = get_patterns_for_agent(agent_type, config)

    -- Detection priority: idle > working > waiting
    --
    -- Key insight (from asheshgoplani/agent-deck): busy indicators are
    -- AUTHORITATIVE. If a spinner or "esc to interrupt" is present, the
    -- agent is actively working regardless of any stale permission prompts
    -- left in scrollback. This is the primary defense against false
    -- "waiting" from old, already-answered prompts.

    -- 1. Idle check: scan last 5 lines for the > prompt.
    --    When the agent shows ">", it's definitively idle — the TUI
    --    replaces it with spinner/progress when working starts.
    local last_lines = get_last_lines(clean_text, 5)

    for line in last_lines:gmatch('[^\n]+') do
        local trimmed = line:match('^%s*(.-)%s*$') or ''

        -- Check for ">" or "❯" prompt (Claude Code uses ❯ U+276F, not ASCII >)
        -- Matches: ">", "❯", "> ", "❯ ", "> Try something...", etc.
        if
            trimmed == '>'
            or trimmed == '❯'
            or trimmed:match('^>%s')
            or trimmed:match('^❯%s')
        then
            return 'idle'
        end

        -- Check custom idle patterns
        if matches_any(trimmed, patterns.idle) then
            return 'idle'
        end
    end

    -- 2. Working check (last 10 lines) — working indicators are
    --    authoritative and override any waiting patterns. If both a
    --    stale prompt and a fresh spinner are visible, the agent is working.
    local very_recent = get_last_lines(clean_text, 10)
    if matches_any(very_recent, patterns.working) then
        return 'working'
    end

    -- 3. Waiting check — only reached when no working indicator was found.
    --    Scan last 30 lines for permission prompts, but require the prompt
    --    to be "fresh" (near the bottom). After a prompt is answered, tool
    --    output pushes it away from the bottom. We find the last waiting
    --    match position and check that no more than 6 content lines follow
    --    it — if there are more, the prompt was already answered (stale).
    local recent_text = get_last_lines(clean_text, 30)
    local recent_lower = recent_text:lower()
    local last_match_end = nil
    for _, pattern in ipairs(patterns.waiting) do
        local s, e = pcall(function()
            local pos, end_pos = 0, 0
            local search_start = 1
            while true do
                local s2, e2 = recent_lower:find(pattern:lower(), search_start)
                if not s2 then
                    break
                end
                pos, end_pos = s2, e2
                search_start = e2 + 1
            end
            if pos > 0 then
                return end_pos
            end
            return nil
        end)
        if s and e then
            if not last_match_end or e > last_match_end then
                last_match_end = e
            end
        end
    end
    if last_match_end then
        local after_text = recent_text:sub(last_match_end + 1)
        local lines_after = 0
        for line in after_text:gmatch('[^\n]+') do
            if line:match('%S') then
                lines_after = lines_after + 1
            end
        end
        if lines_after <= 6 then
            return 'waiting'
        end
    end

    -- Default to idle
    return 'idle'
end

--- Get default patterns (for reference/debugging)
---@return table Default patterns
function M.get_default_patterns()
    return default_patterns
end

--- Strip ANSI codes (exported for use by other modules)
M.strip_ansi = strip_ansi

return M
