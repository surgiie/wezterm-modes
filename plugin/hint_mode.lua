local wezterm = require("wezterm")

local DEFAULT_KEYS = "fjdkslaghrueiwotnbc"
local COPY_MODE_DELAY_SECONDS = 0.05
local CATCH_ALL_CHARACTERS =
	"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789`~!@#$%^&*()_+=[]{}\\|;':\",.<>/? -"

--- Hint labels over the viewport's text; the chosen label opens copy mode with
--- the cursor on that token, so `v` can start the selection straight away.
--- Labels are painted on the real screen with pane:inject_output before copy
--- mode opens, and every exit path restores the rows from their escape codes.
--- @param ctx table  Plugin context (HINT, enter_normal, load, hint_keys?, hint_pattern?)
--- @return table     { key_table, open }
return function(ctx)
	local hints = ctx.load("hints.lua")
	local generate_labels = ctx.load("labels.lua").generate_labels
	local keys = ctx.hint_keys or DEFAULT_KEYS
	local pattern = ctx.hint_pattern
	local enter_normal = ctx.enter_normal
	local should_run = ctx.should_run or function() return true end

	local state = {
		tokens = nil,
		label_by_token = nil,
		prefix = "",
		cursor_row = 0,
		columns = 0,
		painted = nil,
		escaped_rows = nil,
	}
	ctx.hint_state = state

	local plain_copy_mode = wezterm.action.Multiple({ wezterm.action.PopKeyTable, wezterm.action.ActivateCopyMode })

	local function paint(pane)
		state.painted = hints.label_cells(state.tokens, state.label_by_token, state.prefix, state.columns)
		pcall(function()
			pane:inject_output(hints.paint_sequence(state.painted))
		end)
	end

	local function clear(pane)
		local cells = state.painted
		state.painted = nil
		if not cells then
			return
		end
		pcall(function()
			pane:inject_output(hints.restore_sequence(cells, state.escaped_rows))
		end)
	end

	local function reset()
		state.tokens = nil
		state.label_by_token = nil
		state.escaped_rows = nil
		state.prefix = ""
	end

	local function cancel(window, pane)
		clear(pane)
		reset()
		if should_run(pane) then
			window:perform_action(enter_normal, pane)
		else
			window:perform_action(wezterm.action.ClearKeyTableStack, pane)
		end
	end

	local function open_plain_copy_mode(window, pane)
		clear(pane)
		reset()
		window:perform_action(plain_copy_mode, pane)
	end

	local function commit(window, pane, token)
		local cursor_row = state.cursor_row
		clear(pane)
		reset()
		window:perform_action(plain_copy_mode, pane)

		local actions = { wezterm.action.EmitEvent("wezterm-modes-hint-noop") }
		for _, step in ipairs(hints.copy_mode_steps(cursor_row, token)) do
			actions[#actions + 1] = wezterm.action.CopyMode(step)
		end
		wezterm.time.call_after(COPY_MODE_DELAY_SECONDS, function()
			window:perform_action(wezterm.action.Multiple(actions), pane)
		end)
	end

	local function handle_key(window, pane, key)
		if not state.tokens then
			return
		end
		local candidate = state.prefix .. key
		local viable = false
		for token_index, label in pairs(state.label_by_token) do
			if label == candidate then
				commit(window, pane, state.tokens[token_index])
				return
			end
			if label:sub(1, #candidate) == candidate then
				viable = true
			end
		end
		if not viable then
			cancel(window, pane)
			return
		end
		clear(pane)
		state.prefix = candidate
		paint(pane)
	end

	local function backspace(_, pane)
		if not state.tokens then
			return
		end
		clear(pane)
		state.prefix = state.prefix:sub(1, -2)
		paint(pane)
	end

	local function plain_copy_mode_callback(window, pane)
		if state.tokens then
			open_plain_copy_mode(window, pane)
		end
	end

	local key_table = {
		{ key = "Escape", mods = "NONE", action = wezterm.action_callback(cancel) },
		{ key = "Backspace", mods = "NONE", action = wezterm.action_callback(backspace) },
		{ key = "v", mods = "NONE", action = wezterm.action_callback(plain_copy_mode_callback) },
	}

	local bound = { Escape = true, Backspace = true, v = true }
	for key in keys:gmatch(".") do
		if not bound[key] then
			bound[key] = true
			key_table[#key_table + 1] = {
				key = key,
				mods = "NONE",
				action = wezterm.action_callback(function(window, pane)
					handle_key(window, pane, key)
				end),
			}
		end
	end

	local cancel_action = wezterm.action_callback(cancel)
	local catch_all_keys = {}
	for character in CATCH_ALL_CHARACTERS:gmatch(".") do
		catch_all_keys[#catch_all_keys + 1] = character
	end
	for _, name in ipairs({
		"Tab",
		"Enter",
		"Delete",
		"Home",
		"End",
		"PageUp",
		"PageDown",
		"LeftArrow",
		"RightArrow",
		"UpArrow",
		"DownArrow",
	}) do
		catch_all_keys[#catch_all_keys + 1] = name
	end
	for _, key in ipairs(catch_all_keys) do
		if not bound[key] then
			key_table[#key_table + 1] = { key = key, mods = "NONE", action = cancel_action }
		end
		key_table[#key_table + 1] = { key = key, mods = "SHIFT", action = cancel_action }
	end

	--- Paint hints over the viewport, or fall back to plain copy mode when
	--- there is nothing sensible to label.
	--- @param window table  WezTerm Window object
	--- @param pane   table  WezTerm Pane object
	local function open(window, pane)
		local escaped_rows = hints.split_viewport_rows(pane:get_lines_as_escapes())
		local tokens = hints.collect_viewport_tokens(hints.strip_escapes(escaped_rows), pattern)
		if #tokens == 0 then
			window:perform_action(wezterm.action.ActivateCopyMode, pane)
			return
		end

		local dimensions = pane:get_dimensions()
		local cursor = pane:get_cursor_position()
		local cursor_row = cursor.y - (dimensions.physical_top or 0)
		local labels = generate_labels(#tokens, (keys:gsub("v", "")))
		if #labels < #tokens then
			window:perform_action(wezterm.action.ActivateCopyMode, pane)
			return
		end

		state.tokens = tokens
		state.label_by_token = hints.assign_labels(tokens, labels, cursor_row, cursor.x)
		state.prefix = ""
		state.cursor_row = cursor_row
		state.columns = dimensions.cols
		state.escaped_rows = escaped_rows

		window:perform_action(wezterm.action.ActivateKeyTable({ name = ctx.HINT, one_shot = false }), pane)
		paint(pane)
	end

	return { key_table = key_table, open = open }
end
