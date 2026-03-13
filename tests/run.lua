package.path = table.concat({
    './plugin/?.lua',
    './plugin/?/init.lua',
    './plugin/components/?.lua',
    package.path,
}, ';')

package.preload['wezterm'] = function()
    return require('tests.stub_wezterm')
end

local t = require('tests.harness')
local runner = t.new_runner()

runner:test('config.set merges defaults and validates', function()
    local config = require('config')
    local wezterm = require('wezterm')

    config.set({
        update_interval = 50,
        cooldown_ms = -1,
        max_lines = 5,
        icons = { style = 'nope' },
        tab_title = { position = 'middle' },
    })

    local cfg = config.get()

    t.eq(cfg.update_interval, 5000)
    t.eq(cfg.cooldown_ms, 2000)
    t.eq(cfg.max_lines, 100)
    t.eq(cfg.icons.style, 'unicode')
    t.eq(cfg.tab_title.position, 'left')

    t.truthy(#wezterm._logs.warn > 0, 'expected warnings logged')
end)

runner:test('detector.detect_agent matches executable, argv, and children', function()
    local detector = require('detector')

    local pane = {
        pane_id = function()
            return 1
        end,
        get_foreground_process_info = function()
            return {
                executable = '/usr/bin/node',
                argv = { 'node', 'cli.js', 'opencode' },
                children = {
                    { executable = '/opt/bin/claude-code', argv = { 'claude-code' } },
                },
            }
        end,
        get_foreground_process_name = function()
            return '/usr/bin/node'
        end,
    }

    local cfg = {
        agents = {
            opencode = { patterns = { 'opencode' } },
            claude = { patterns = { 'claude', 'claude%-code' } },
        },
    }

    t.eq(detector.detect_agent(pane, cfg), 'opencode')

    detector.clear_cache(1)
    pane.get_foreground_process_info = function()
        return {
            executable = '/usr/bin/node',
            argv = { 'node', 'cli.js' },
            children = {
                { executable = '/opt/bin/claude-code', argv = { 'claude-code' } },
            },
        }
    end
    t.eq(detector.detect_agent(pane, cfg), 'claude')
end)

runner:test('detector.detect_agent uses executable_patterns for specific matching', function()
    local detector = require('detector')

    local pane = {
        pane_id = function()
            return 3
        end,
        get_foreground_process_info = function()
            return {
                executable = '/Users/test/.bun/install/global/node_modules/opencode-darwin-arm64/bin/opencode',
                argv = { 'opencode' },
                children = {},
            }
        end,
        get_foreground_process_name = function()
            return 'opencode'
        end,
    }

    local cfg = {
        agents = {
            opencode = {
                patterns = { 'opencode' },
                executable_patterns = { 'opencode%-darwin', 'opencode%-linux' },
            },
        },
    }

    t.eq(detector.detect_agent(pane, cfg), 'opencode')
end)

runner:test('detector.detect_agent respects enabled_agents whitelist', function()
    local detector = require('detector')

    local pane = {
        pane_id = function()
            return 4
        end,
        get_foreground_process_info = function()
            return {
                executable = '/usr/bin/gemini',
                argv = { 'gemini' },
                children = {},
            }
        end,
        get_foreground_process_name = function()
            return 'gemini'
        end,
    }

    local cfg = {
        enabled_agents = { 'opencode', 'claude' },
        agents = {
            opencode = { patterns = { 'opencode' } },
            claude = { patterns = { 'claude' } },
            gemini = { patterns = { 'gemini' } },
        },
    }

    t.eq(detector.detect_agent(pane, cfg), nil)

    detector.clear_cache(4)
    cfg.enabled_agents = nil
    t.eq(detector.detect_agent(pane, cfg), 'gemini')
end)

runner:test('detector.detect_agent uses title_patterns for fallback', function()
    local detector = require('detector')

    local pane = {
        pane_id = function()
            return 5
        end,
        get_foreground_process_info = function()
            return {
                executable = '/bin/zsh',
                argv = { 'zsh' },
                children = {},
            }
        end,
        get_foreground_process_name = function()
            return '/bin/zsh'
        end,
        get_title = function()
            return 'Claude Code v2.1.6'
        end,
    }

    local cfg = {
        agents = {
            claude = {
                patterns = { 'claude' },
                title_patterns = { 'claude%s+code%s+v' },
            },
        },
    }

    t.eq(detector.detect_agent(pane, cfg), 'claude')
end)

runner:test('detector.detect_agent matches bare claude executable with trailing spaces', function()
    local detector = require('detector')

    local pane = {
        pane_id = function()
            return 6
        end,
        get_foreground_process_info = function()
            return {
                executable = 'claude  ',
                argv = { 'claude' },
                children = {},
            }
        end,
        get_foreground_process_name = function()
            return 'claude  '
        end,
    }

    local cfg = {
        agents = {
            claude = {
                patterns = { 'claude' },
                executable_patterns = { '^claude%s*$' },
            },
        },
    }

    t.eq(detector.detect_agent(pane, cfg), 'claude')
end)

runner:test('detector.detect_agent uses process name field when executable is node', function()
    local detector = require('detector')

    local pane = {
        pane_id = function()
            return 7
        end,
        get_foreground_process_info = function()
            return {
                executable = '/usr/local/bin/node',
                name = 'claude',
                argv = { 'node', '/path/to/cli.js' },
                children = {},
            }
        end,
        get_foreground_process_name = function()
            return '/usr/local/bin/node'
        end,
    }

    local cfg = {
        agents = {
            claude = {
                patterns = { 'claude' },
                executable_patterns = { '^claude%s*$' },
            },
        },
    }

    t.eq(detector.detect_agent(pane, cfg), 'claude')
end)

runner:test('detector.detect_agent falls back to pane title for Claude Code', function()
    local detector = require('detector')

    local pane = {
        pane_id = function()
            return 2
        end,
        get_foreground_process_info = function()
            return {
                executable = '/bin/zsh',
                argv = { 'zsh' },
                children = {},
            }
        end,
        get_foreground_process_name = function()
            return '/bin/zsh'
        end,
        get_title = function()
            return 'Claude Code v2.1.6'
        end,
    }

    local cfg = {
        agents = {
            opencode = { patterns = { 'opencode' } },
            claude = { patterns = { 'claude', 'claude%-code' } },
        },
    }

    t.eq(detector.detect_agent(pane, cfg), 'claude')
end)

runner:test('status.detect_status prefers idle prompt over stale working', function()
    local status = require('status')

    local pane = {
        get_lines_as_text = function()
            return table.concat({
                'some output',
                'Esc to interrupt',
                'done',
                '> ',
            }, '\n')
        end,
        get_logical_lines_as_text = function()
            return ''
        end,
    }

    local cfg = { max_lines = 100, agents = { opencode = {} } }

    t.eq(status.detect_status(pane, 'opencode', cfg), 'idle')
end)

runner:test('status.detect_status treats opencode new session as idle', function()
    local status = require('status')

    local pane = {
        get_lines_as_text = function()
            return table.concat({
                '█',
                'opencode',
                'Ask anything... "Fix broken tests"',
            }, '\n')
        end,
        get_logical_lines_as_text = function()
            return ''
        end,
    }

    local cfg = { max_lines = 100, agents = { opencode = {} } }

    t.eq(status.detect_status(pane, 'opencode', cfg), 'idle')
end)

runner:test('status.detect_status does not treat opencode logo blocks as working', function()
    local status = require('status')

    local pane = {
        get_lines_as_text = function()
            return table.concat({
                '██████',
                'opencode',
            }, '\n')
        end,
        get_logical_lines_as_text = function()
            return ''
        end,
    }

    local cfg = { max_lines = 100, agents = { opencode = {} } }

    t.eq(status.detect_status(pane, 'opencode', cfg), 'idle')
end)

runner:test('status.detect_status finds waiting in recent output', function()
    local status = require('status')

    local pane = {
        get_lines_as_text = function()
            return table.concat({
                'do you trust this command?',
                '(Y/n)',
            }, '\n')
        end,
        get_logical_lines_as_text = function()
            return ''
        end,
    }

    local cfg = { max_lines = 100, agents = { opencode = {} } }

    t.eq(status.detect_status(pane, 'opencode', cfg), 'waiting')
end)

runner:test('status.detect_status detects plan mode ask tool as waiting', function()
    local status = require('status')

    local pane = {
        get_lines_as_text = function()
            return table.concat({
                'Filter Type  Standalone  Confirm',
                'The existing filters are all string arrays. For hasAttachments, what behavior should it have?',
                '1. Boolean filter (Recommended)',
                '2. Tri-state filter',
                '3. Type your own answer',
                '⇥ tab  ↕ select  enter confirm  esc dismiss',
            }, '\n')
        end,
        get_logical_lines_as_text = function()
            return ''
        end,
    }

    local cfg = { max_lines = 100, agents = { opencode = {} } }

    t.eq(status.detect_status(pane, 'opencode', cfg), 'waiting')
end)

runner:test('components render placeholders and badge counts', function()
    local config = require('config')
    local components = require('components')

    config.set({
        colors = {
            working = '#00ff00',
            waiting = '#ffff00',
            idle = '#0000ff',
            inactive = '#888888',
        },
        icons = {
            style = 'unicode',
            unicode = {
                working = 'W',
                waiting = 'A',
                idle = 'I',
                inactive = 'N',
            },
        },
    })

    local cfg = config.get()

    local label_items = components.render('label', {
        status = 'working',
        agent_type = 'opencode',
        config = cfg,
    }, {
        type = 'label',
        format = '{agent_type}:{status}',
    })

    local label_text = nil
    for _, item in ipairs(label_items) do
        if item.Text then
            label_text = item.Text
        end
    end
    t.eq(label_text, 'opencode:working')

    local badge_items = components.render('badge', {
        counts = { working = 2, waiting = 1, idle = 0, inactive = 0 },
        config = cfg,
    }, {
        type = 'badge',
        filter = 'waiting',
        label = 'waiting',
    })

    local badge_text = nil
    for _, item in ipairs(badge_items) do
        if item.Text then
            badge_text = item.Text
        end
    end
    t.eq(badge_text, '1 waiting')
end)

runner:test('status.detect_status ignores stale waiting prompt after tool output', function()
    local status = require('status')

    -- Simulate: Claude asked a permission question, user approved, and now
    -- there's tool output below the answered prompt. The old "yes, allow once"
    -- text is still in scrollback but should be treated as stale.
    local pane = {
        get_lines_as_text = function()
            return table.concat({
                'I need to run this command:',
                '  rm -rf /tmp/test',
                'Do you trust this command?',
                '  Yes, allow once',
                '  Yes, allow always',
                '  No, and tell Claude why',
                '',
                '  ── Tool Result ──',
                '  Command executed successfully.',
                '  Removed 3 files.',
                '',
                '  Now let me check the results...',
                '  Reading file /tmp/output.txt',
                '  The output looks correct.',
                '  Processing complete.',
                '  All tests passed.',
                '  Summary: 10 files updated.',
                '  Done.',
            }, '\n')
        end,
        get_logical_lines_as_text = function()
            return ''
        end,
    }

    local cfg = { max_lines = 100, agents = { claude = {} } }

    -- Should NOT be 'waiting' because the prompt was already answered
    -- (many content lines after the last waiting pattern)
    t.eq(status.detect_status(pane, 'claude', cfg), 'idle')
end)

runner:test('status.detect_status detects active waiting prompt near bottom', function()
    local status = require('status')

    -- Simulate: Claude just asked a permission question, it's at the bottom
    -- of the screen with no tool output after it yet.
    local pane = {
        get_lines_as_text = function()
            return table.concat({
                'Some previous output from earlier tasks...',
                'More output lines...',
                'Even more output...',
                '',
                'I need to edit this file:',
                '  src/main.ts',
                '',
                'Do you trust this command?',
                '  Yes, allow once',
                '  Yes, allow always',
                '  No, and tell Claude why',
            }, '\n')
        end,
        get_logical_lines_as_text = function()
            return ''
        end,
    }

    local cfg = { max_lines = 100, agents = { claude = {} } }

    -- Should be 'waiting' because the prompt is active (near bottom)
    t.eq(status.detect_status(pane, 'claude', cfg), 'waiting')
end)

runner:test('status.detect_status detects OpenCode ask dialog as waiting', function()
    local status = require('status')

    -- Simulate OpenCode's bubbletea TUI ask dialog with borders
    local pane = {
        get_lines_as_text = function()
            return table.concat({
                '  opencode',
                '  Model: claude-sonnet-4-20250514',
                '',
                '  Working on your request...',
                '',
                '  Filter Type  Standalone  Confirm',
                '  ┌─────────────────────────────────────┐',
                '  │ The agent wants to run:              │',
                '  │   npm install express                │',
                '  │                                      │',
                '  │ 1. Yes, allow once                   │',
                '  │ 2. Yes, allow always                 │',
                '  │ 3. No                                │',
                '  │ 4. Type your own answer              │',
                '  └─────────────────────────────────────┘',
                '  ⇥ tab  ↕ select  enter confirm  esc dismiss',
            }, '\n')
        end,
        get_logical_lines_as_text = function()
            return ''
        end,
    }

    local cfg = { max_lines = 100, agents = { opencode = {} } }

    t.eq(status.detect_status(pane, 'opencode', cfg), 'waiting')
end)

runner:test('status.detect_status returns working when agent is processing', function()
    local status = require('status')

    -- No idle prompt, no waiting prompt, but working indicator present
    local pane = {
        get_lines_as_text = function()
            return table.concat({
                'some previous output',
                'more output',
                '',
                'Thinking...',
                '',
            }, '\n')
        end,
        get_logical_lines_as_text = function()
            return ''
        end,
    }

    local cfg = { max_lines = 100, agents = { claude = {} } }

    t.eq(status.detect_status(pane, 'claude', cfg), 'working')
end)

runner:test('status.detect_status returns working for esc to interrupt', function()
    local status = require('status')

    local pane = {
        get_lines_as_text = function()
            return table.concat({
                'some output',
                '',
                '  Esc to interrupt',
                '',
            }, '\n')
        end,
        get_logical_lines_as_text = function()
            return ''
        end,
    }

    local cfg = { max_lines = 100, agents = { claude = {} } }

    t.eq(status.detect_status(pane, 'claude', cfg), 'working')
end)

runner:test('status.detect_status working with stale waiting in scrollback', function()
    local status = require('status')

    -- Agent answered a permission prompt, now actively working on something else.
    -- The old "yes, allow once" is stale (many lines after it), and
    -- "esc to interrupt" is near the bottom showing active work.
    local pane = {
        get_lines_as_text = function()
            return table.concat({
                '  Do you trust this command?',
                '  Yes, allow once',
                '  Yes, allow always',
                '  No, and tell Claude why',
                '',
                '  ── Tool Result ──',
                '  Command executed successfully.',
                '',
                '  Now working on the next step...',
                '  Reading file src/main.ts',
                '  Analyzing the codebase structure',
                '  Found 5 relevant files',
                '  Checking dependencies',
                '  Preparing changes',
                '',
                '  Esc to interrupt',
                '',
            }, '\n')
        end,
        get_logical_lines_as_text = function()
            return ''
        end,
    }

    local cfg = { max_lines = 100, agents = { claude = {} } }

    -- Should be 'working' — stale waiting prompt is ignored, esc to interrupt is active
    t.eq(status.detect_status(pane, 'claude', cfg), 'working')
end)

runner:test('status.detect_status does not false-positive on output words', function()
    local status = require('status')

    -- Agent is idle, output contains words like "reading" and "processing"
    -- that used to be working patterns but are actually just prose in output
    local pane = {
        get_lines_as_text = function()
            return table.concat({
                '  I finished processing the files.',
                '  After reading the configuration,',
                '  I made the following changes:',
                '  - Updated the writing module',
                '  - Fixed the searching logic',
                '  Done.',
            }, '\n')
        end,
        get_logical_lines_as_text = function()
            return ''
        end,
    }

    local cfg = { max_lines = 100, agents = { claude = {} } }

    -- Should NOT be 'working' — these are output words, not status indicators
    t.eq(status.detect_status(pane, 'claude', cfg), 'idle')
end)

runner:test('status.detect_status idle beats stale waiting in scrollback', function()
    local status = require('status')

    -- Agent finished a task, idle prompt visible, but old waiting text
    -- from a PREVIOUS interaction is still in scrollback
    local pane = {
        get_lines_as_text = function()
            return table.concat({
                '  Do you trust this command?',
                '  Yes, allow once',
                '  Yes, allow always',
                '  No, and tell Claude why',
                '',
                '  ── Tool Result ──',
                '  Command executed successfully.',
                '',
                '  I have completed the task.',
                '  Worked for 2m 15s',
                '',
                '> ',
            }, '\n')
        end,
        get_logical_lines_as_text = function()
            return ''
        end,
    }

    local cfg = { max_lines = 100, agents = { claude = {} } }

    -- Idle prompt at bottom should win over stale waiting text above
    t.eq(status.detect_status(pane, 'claude', cfg), 'idle')
end)

runner:test('status.detect_status working beats fresh waiting (busy-is-authoritative)', function()
    local status = require('status')

    -- Critical scenario: agent just answered a permission prompt and is now
    -- actively working. The old prompt text is still VERY close to the bottom
    -- (within the 6-line freshness threshold), but a working indicator is
    -- also present. Working must win because busy indicators are authoritative.
    local pane = {
        get_lines_as_text = function()
            return table.concat({
                '  Do you trust this command?',
                '  Yes, allow once',
                '  Yes, allow always',
                '  No, and tell Claude why',
                '',
                '  Esc to interrupt',
            }, '\n')
        end,
        get_logical_lines_as_text = function()
            return ''
        end,
    }

    local cfg = { max_lines = 100, agents = { claude = {} } }

    -- With the old priority (waiting > working), this would incorrectly
    -- return 'waiting' because the prompt is within 6 lines of the bottom.
    -- With busy-is-authoritative, working wins.
    t.eq(status.detect_status(pane, 'claude', cfg), 'working')
end)

runner:test('status.detect_status ctrl+c to interrupt means working', function()
    local status = require('status')

    -- Claude Code 2024+ uses "ctrl+c to interrupt" instead of "esc to interrupt"
    local pane = {
        get_lines_as_text = function()
            return table.concat({
                'some previous output',
                '',
                '  Ctrl+C to interrupt',
                '',
            }, '\n')
        end,
        get_logical_lines_as_text = function()
            return ''
        end,
    }

    local cfg = { max_lines = 100, agents = { claude = {} } }

    t.eq(status.detect_status(pane, 'claude', cfg), 'working')
end)

runner:test('status.detect_status detects unicode ❯ prompt as idle', function()
    local status = require('status')

    -- Claude Code uses ❯ (U+276F) not ASCII > for its prompt.
    -- Without this fix, idle check misses the prompt and stale
    -- "ctrl+c to interrupt" in scrollback causes false "working".
    local pane = {
        get_lines_as_text = function()
            return table.concat({
                'some previous output',
                'ctrl+c to interrupt',
                '✻ Worked for 2m 15s',
                '',
                '❯ ',
            }, '\n')
        end,
        get_logical_lines_as_text = function()
            return ''
        end,
    }

    local cfg = { max_lines = 100, agents = { claude = {} } }

    -- Must detect ❯ as idle, NOT match stale "ctrl+c to interrupt" as working
    t.eq(status.detect_status(pane, 'claude', cfg), 'idle')
end)

runner:test('status.detect_status detects bare ❯ prompt as idle', function()
    local status = require('status')

    local pane = {
        get_lines_as_text = function()
            return table.concat({
                'some output',
                '',
                '❯',
            }, '\n')
        end,
        get_logical_lines_as_text = function()
            return ''
        end,
    }

    local cfg = { max_lines = 100, agents = { claude = {} } }

    t.eq(status.detect_status(pane, 'claude', cfg), 'idle')
end)

runner:test('status.detect_status opencode generating means working', function()
    local status = require('status')

    -- OpenCode shows "Generating..." while producing output
    local pane = {
        get_lines_as_text = function()
            return table.concat({
                '  opencode',
                '  Model: claude-sonnet-4-20250514',
                '',
                '  Generating...',
                '',
            }, '\n')
        end,
        get_logical_lines_as_text = function()
            return ''
        end,
    }

    local cfg = { max_lines = 100, agents = { opencode = {} } }

    t.eq(status.detect_status(pane, 'opencode', cfg), 'working')
end)

runner:run()
