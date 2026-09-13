local wezterm = require("wezterm")
local M = {}

-- ── Mode name constants ───────────────────────────────────────────────────────

local NORMAL  = "normal_mode"
local DELETE  = "delete_mode"
local YANK    = "yank_mode"
local MOTION  = "motion_mode"
local REPLACE = "replace_mode"
local KEYMAP  = "keymap_mode"
local COUNT   = "count_mode"
local JUMP    = "jump_mode"

-- ── Shared actions ────────────────────────────────────────────────────────────

local enter_normal = wezterm.action.ActivateKeyTable({ name = NORMAL, one_shot = false, replace_current = true })
local enter_insert = wezterm.action.ClearKeyTableStack
local noop         = wezterm.action.DisableDefaultAssignment

-- ── Shared mutable state ──────────────────────────────────────────────────────
-- Plain Lua tables (not WezTerm objects), closed over by action_callbacks across
-- mode files, so state can persist between keystrokes within a single config load.

-- Pending numeric prefix (e.g. the "3" in "3dw"). `n` is nil when no count is pending.
local count_state = { n = nil }

-- Last repeatable normal-mode change, replayed by `.`.
-- `run` is a function(window, pane) or nil when nothing has run yet.
local last_change = { run = nil }

--- Record a repeatable action and immediately run it once.
--- Call this instead of window:perform_action for anything `.` should be able to repeat.
--- @param window table     WezTerm Window object
--- @param pane   table     WezTerm Pane object
--- @param fn     function  function(window, pane) — performs the change
local function do_change(window, pane, fn)
	last_change.run = fn
	fn(window, pane)
end

--- Type or run a configured keymap's command in the pane.
--- Files on disk are sourced directly; otherwise the resolved command string
--- is typed, honoring `execute` (run vs. just type) and an optional
--- `<cursor>` placeholder that leaves the cursor mid-command.
---
--- Delivered via the action queue (SendString/SendKey), not pane:send_text,
--- and prefixed with a throwaway SPACE: typing ":x" fast enough can drop the
--- first byte of the injected input (races the triggering keystroke), and a
--- leading space is inert to the shell either way (` cmd` runs like `cmd`).
--- The type-only (`execute = false`) path uses a leading CTRL+B instead of a
--- space (a no-op at column 0), since that text stays on the line to be
--- edited and a stray leading space would stay visible.
--- @param window  table  WezTerm Window object
--- @param pane    table  WezTerm Pane object
--- @param binding table  Keymap entry: { action, execute? }
local function execute_command(window, pane, binding)
	local raw      = type(binding.action) == "function" and binding.action(pane) or (binding.action or "")
	local cmd      = raw:match("^%s*(.-)%s*$")
	local execute  = binding.execute ~= false
	local expanded = cmd:gsub("^~", os.getenv("HOME") or "~")

	-- Lead with the key-table pop so it and the typing land as one ordered unit.
	local actions = { enter_insert }
	local ctrl_b  = wezterm.action.SendKey({ key = "b", mods = "CTRL" })

	local f = io.open(expanded, "r")
	if f then
		f:close()
		table.insert(actions, wezterm.action.SendString(" " .. expanded .. "\n"))
	elseif not execute then
		local before = cmd:match("^(.-)%<cursor%>") or cmd
		local after  = cmd:match("%<cursor%>(.*)$") or ""
		-- Leading CTRL+B soaks up the dropped byte without adding a visible char.
		table.insert(actions, ctrl_b)
		table.insert(actions, wezterm.action.SendString(before .. after))
		-- One CTRL+B per trailing char, walking the cursor back to <cursor>.
		for _ = 1, #after do table.insert(actions, ctrl_b) end
	else
		table.insert(actions, wezterm.action.SendString(" " .. cmd .. "\n"))
	end

	window:perform_action(wezterm.action.Multiple(actions), pane)
end

-- ── Plugin directory (for loading sibling files) ──────────────────────────────

local plugin_dir = (function()
	local ok, list = pcall(function() return wezterm.plugin.list() end)
	if ok and list then
		for _, entry in ipairs(list) do
			if (entry.url or ""):find("wezterm-modes", 1, true) and (entry.plugin_dir or "") ~= "" then
				return entry.plugin_dir
			end
		end
	end
	return wezterm.home_dir .. "/projects/wezterm-modes"
end)()

--- Load and return a plugin-relative file via dofile.
--- @param path string  Relative path under plugin/
--- @return any         Whatever the file returns
local function load(path)
	return dofile(plugin_dir .. "/plugin/" .. path)
end

-- ── Default shell detection ───────────────────────────────────────────────────

--- Return true when the pane's foreground process is a known shell.
--- Used as the default should_run predicate.
--- @param pane table  WezTerm Pane object
--- @return boolean
local function pane_is_shell(pane)
	if pane:is_alt_screen_active() then return false end
	local proc = (pane:get_foreground_process_name() or ""):lower()
	for _, shell in ipairs({ "bash", "zsh", "sh", "fish" }) do
		if proc:find(shell, 1, true) then return true end
	end
	return false
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Wire all vim-mode key tables and events into a WezTerm config.
---
--- @param config table  WezTerm config_builder object
--- @param opts   table  Optional settings:
---   - should_run        function(pane, pane_is_shell) → boolean
---                       Called on every focus/status tick; plugin is a no-op when false.
---                       Receives the built-in pane_is_shell so callers can delegate.
---   - key_table_timeout number   Timeout ms for multi-key sequences like gg/dd (default: 2000)
---   - icon               string  Icon shown in left status when plugin is inactive (e.g. "🔥")
---   - left_status_prefix function(pane) → string?
---                       Called on every status tick; its return value (already
---                       wezterm.format-encoded, or plain text) is prepended to
---                       whatever this plugin puts in the left status - lets
---                       callers add their own app-specific decoration (e.g. a
---                       border block reflecting some other app's state) without
---                       this plugin needing to know anything about it.
---   - keymaps          table[]  Keymap-mode bindings (omit to disable keymap mode)
---                                Each entry: { key, description, command, execute?, confirm? }
---   - jump_keys        string  Label alphabet for `J` (word-jump), most-reachable
---                              keys first (default: "fjdkslaghrueiwotnvbc")
---   - jump_pattern     string  Lua pattern selecting `J`'s targets (default:
---                              "%S+" — every whitespace-separated token, so
---                              "pod-edge-0" or "-it" are each one target)
function M.apply_to_config(config, opts)
	opts = opts or {}

	local should_run = opts.should_run
		and function(pane) return opts.should_run(pane, pane_is_shell) end
		or pane_is_shell
	local keymaps   = opts.keymaps or {}
	local kt_timeout = opts.key_table_timeout or 2000
	local icon       = opts.icon or ""
	local left_status_prefix = opts.left_status_prefix

	config.key_tables = config.key_tables or {}
	config.keys       = config.keys or {}

	-- shared context passed to each mode builder
	local ctx = {
		NORMAL          = NORMAL,
		DELETE          = DELETE,
		YANK            = YANK,
		MOTION          = MOTION,
		REPLACE         = REPLACE,
		KEYMAP          = KEYMAP,
		COUNT           = COUNT,
		JUMP            = JUMP,
		enter_normal    = enter_normal,
		enter_insert    = enter_insert,
		noop            = noop,
		should_run      = should_run,
		kt_timeout      = kt_timeout,
		keymaps         = keymaps,
		execute_command = execute_command,
		nested_kts      = config.key_tables,
		count_state     = count_state,
		last_change     = last_change,
		do_change       = do_change,
		jump_keys       = opts.jump_keys,
		jump_pattern    = opts.jump_pattern,
		icon            = icon,
		left_status_prefix = left_status_prefix,
	}

	-- status.lua first: it stashes ctx.render_jump_status, which jump.lua
	-- uses to paint its label legend into the left status.
	load("status.lua")(ctx)
	ctx.jump = load("jump.lua")(ctx)

	config.key_tables[MOTION]  = load("modes/motion.lua")(ctx)
	config.key_tables[REPLACE] = load("modes/replace.lua")(ctx)
	config.key_tables[DELETE]  = load("modes/delete.lua")(ctx)
	config.key_tables[COUNT]   = load("modes/count.lua")(ctx)
	config.key_tables[JUMP]    = ctx.jump.key_table
	if #keymaps > 0 then
		config.key_tables[KEYMAP] = load("modes/keymap.lua")(ctx)
	end
	config.key_tables[YANK]    = load("modes/yank.lua")(ctx)
	config.key_tables[NORMAL]  = load("modes/normal.lua")(ctx)

	-- Escape: enter normal if shell, pass through otherwise
	table.insert(config.keys, {
		key = "Escape", mods = "NONE",
		action = wezterm.action_callback(function(window, pane)
			if should_run(pane) then
				window:perform_action(enter_normal, pane)
			else
				window:perform_action(wezterm.action.SendKey({ key = "Escape" }), pane)
			end
		end),
	})

	wezterm.on("window-config-reloaded", function(window, pane)
		if should_run(pane) then
			window:perform_action(enter_insert, pane)
		end
	end)

	wezterm.on("pane-focus-changed", function(window, pane)
		count_state.n = nil
		last_change.run = nil
		if should_run(pane) then
			window:perform_action(enter_insert, pane)
		else
			window:perform_action(wezterm.action.ClearKeyTableStack, pane)
		end
	end)

end

M.enter_normal = enter_normal
M.enter_insert = enter_insert

return M
