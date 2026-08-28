local wezterm = require("wezterm")

--- Build and return the keymap mode key table.
--- Entered via `:` in normal mode; listens for a configured keymap key and
--- runs its command. Lives in its own namespace, so keymaps are free to reuse
--- any letter (including vim motion keys like h/j/k/v/g) without conflict.
---
--- Single-char keys fire directly from this table. Two-char keys use their
--- first char as a nested one-shot prefix key table (mirrors gg/dd), scoped
--- entirely under `:` so it can never collide with normal mode's own bindings.
---
--- Malformed or conflicting keymaps are logged via wezterm.log_error and
--- skipped rather than raising — a mistake in `opts.keymaps` should not take
--- down the whole WezTerm config.
---
--- @param ctx table  Plugin context (enter_insert, noop, should_run, kt_timeout,
---                    keymaps, nested_kts, KEYMAP, execute_command)
--- @return table     List of WezTerm key binding definitions
return function(ctx)
	local enter_insert    = ctx.enter_insert
	local noop            = ctx.noop
	local should_run      = ctx.should_run
	local kt_timeout      = ctx.kt_timeout
	local keymaps         = ctx.keymaps
	local nested_kts      = ctx.nested_kts
	local KEYMAP          = ctx.KEYMAP
	local execute_command = ctx.execute_command

	local function run(binding)
		return wezterm.action_callback(function(window, pane)
			if not should_run(pane) then return end
			-- Restore normal terminal input routing *before* typing the command.
			-- Typing while still nested in a key table can race with the pane's
			-- handling of the keystroke that triggered this action, dropping the
			-- first character of the command; popping first avoids that.
			window:perform_action(enter_insert, pane)
			execute_command(pane, binding)
		end)
	end

	local direct      = {}
	local direct_seen = {}
	local prefixed    = {}

	for _, binding in ipairs(keymaps) do
		local k = binding.key or ""
		if #k == 1 then
			if direct_seen[k] then
				wezterm.log_error(
					"wezterm-modes: duplicate keymap key '" .. k .. "' — the later entry wins"
				)
			end
			direct_seen[k] = true
			table.insert(direct, binding)
		elseif #k == 2 then
			local prefix = k:sub(1, 1)
			local suffix = k:sub(2, 2)
			prefixed[prefix] = prefixed[prefix] or {}
			for _, entry in ipairs(prefixed[prefix]) do
				if entry.suffix == suffix then
					wezterm.log_error(
						"wezterm-modes: duplicate keymap key '" .. k .. "' — the later entry wins"
					)
				end
			end
			table.insert(prefixed[prefix], { suffix = suffix, binding = binding })
		else
			wezterm.log_error(
				"wezterm-modes: keymap key '" .. k .. "' must be 1 or 2 characters — skipping it"
			)
		end
	end

	for prefix in pairs(prefixed) do
		if direct_seen[prefix] then
			wezterm.log_error(
				"wezterm-modes: keymap key '" .. prefix .. "' conflicts with the prefix of '"
				.. prefix .. prefixed[prefix][1].suffix .. "' — dropping the two-char group, '"
				.. prefix .. "' stays a direct binding"
			)
			prefixed[prefix] = nil
		end
	end

	local kt = { { key = "Escape", mods = "NONE", action = noop } }

	for _, binding in ipairs(direct) do
		table.insert(kt, { key = binding.key, mods = "NONE", action = run(binding) })
	end

	local prefix_list = {}
	for prefix in pairs(prefixed) do table.insert(prefix_list, prefix) end
	table.sort(prefix_list)

	for _, prefix in ipairs(prefix_list) do
		local table_name = KEYMAP .. "_" .. prefix
		local sub_kt = { { key = "Escape", mods = "NONE", action = noop } }

		for _, entry in ipairs(prefixed[prefix]) do
			table.insert(sub_kt, { key = entry.suffix, mods = "NONE", action = run(entry.binding) })
		end

		nested_kts[table_name] = sub_kt

		table.insert(kt, {
			key = prefix, mods = "NONE",
			action = wezterm.action.ActivateKeyTable({
				name                 = table_name,
				one_shot             = true,
				timeout_milliseconds = kt_timeout,
			}),
		})
	end

	return kt
end
