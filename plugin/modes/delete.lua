local wezterm = require("wezterm")

--- Build and return the delete mode key table.
--- Entered via `d` in normal mode; times out after kt_timeout ms with no second key.
--- All operations return to normal mode after executing.
--- @param ctx table  Plugin context (enter_normal, noop, count_state, do_change)
--- @return table     List of WezTerm key binding definitions
return function(ctx)
	local enter_normal = ctx.enter_normal
	local noop         = ctx.noop
	local count_state  = ctx.count_state
	local do_change    = ctx.do_change

	--- Delete word forward/backward, repeated by any pending numeric prefix
	--- (e.g. the "3" in "3dw"), then clear the count and return to normal.
	--- @param send table  A wezterm.action.SendKey(...) action for one word-delete
	local function repeat_word_delete(send)
		return wezterm.action_callback(function(window, pane)
			local n = count_state.n or 1
			count_state.n = nil
			do_change(window, pane, function(w, p)
				local actions = {}
				for _ = 1, n do table.insert(actions, send) end
				table.insert(actions, enter_normal)
				w:perform_action(wezterm.action.Multiple(actions), p)
			end)
		end)
	end

	return {
		-- swallow these first so normal mode stack bindings can't fire
		{ key = "$", mods = "NONE",  action = noop },
		{ key = "$", mods = "SHIFT", action = noop },
		{ key = "4", mods = "SHIFT", action = noop },
		{ key = "0", mods = "NONE",  action = noop },
		{ key = "^", mods = "NONE",  action = noop },
		{ key = "^", mods = "SHIFT", action = noop },
		{ key = "6", mods = "SHIFT", action = noop },

		{ key = "Escape", action = enter_normal },

		-- db: delete word backward (readline CTRL+W), repeated by a pending count
		{ key = "b", action = repeat_word_delete(wezterm.action.SendKey({ key = "w", mods = "CTRL" })) },

		-- dw: delete word forward (readline ALT+D), repeated by a pending count
		{ key = "w", action = repeat_word_delete(wezterm.action.SendKey({ key = "d", mods = "ALT" })) },

		-- dd: delete whole line (readline CTRL+U + CTRL+K)
		{ key = "d", action = wezterm.action_callback(function(window, pane)
			do_change(window, pane, function(w, p)
				w:perform_action(wezterm.action.Multiple({
					wezterm.action.SendKey({ key = "u", mods = "CTRL" }),
					wezterm.action.SendKey({ key = "k", mods = "CTRL" }),
					enter_normal,
				}), p)
			end)
		end) },

		-- d$: delete to end of line (readline CTRL+K)
		{ key = "$", mods = "NONE",  action = wezterm.action_callback(function(window, pane)
			do_change(window, pane, function(w, p)
				w:perform_action(wezterm.action.Multiple({
					wezterm.action.SendKey({ key = "k", mods = "CTRL" }),
					enter_normal,
				}), p)
			end)
		end) },
		{ key = "$", mods = "SHIFT", action = wezterm.action_callback(function(window, pane)
			do_change(window, pane, function(w, p)
				w:perform_action(wezterm.action.Multiple({
					wezterm.action.SendKey({ key = "k", mods = "CTRL" }),
					enter_normal,
				}), p)
			end)
		end) },
		{ key = "4", mods = "SHIFT", action = wezterm.action_callback(function(window, pane)
			do_change(window, pane, function(w, p)
				w:perform_action(wezterm.action.Multiple({
					wezterm.action.SendKey({ key = "k", mods = "CTRL" }),
					enter_normal,
				}), p)
			end)
		end) },

		-- d0: delete to start of line (readline CTRL+U)
		{ key = "0", mods = "NONE", action = wezterm.action_callback(function(window, pane)
			do_change(window, pane, function(w, p)
				w:perform_action(wezterm.action.Multiple({
					wezterm.action.SendKey({ key = "u", mods = "CTRL" }),
					enter_normal,
				}), p)
			end)
		end) },

		-- d^: delete to first non-whitespace (readline CTRL+U then re-type leading whitespace)
		{ key = "^", mods = "NONE",  action = wezterm.action_callback(function(window, pane)
			do_change(window, pane, function(w, p)
				w:perform_action(wezterm.action.Multiple({
					wezterm.action.SendKey({ key = "u", mods = "CTRL" }),
					enter_normal,
				}), p)
			end)
		end) },
		{ key = "^", mods = "SHIFT", action = wezterm.action_callback(function(window, pane)
			do_change(window, pane, function(w, p)
				w:perform_action(wezterm.action.Multiple({
					wezterm.action.SendKey({ key = "u", mods = "CTRL" }),
					enter_normal,
				}), p)
			end)
		end) },
		{ key = "6", mods = "SHIFT", action = wezterm.action_callback(function(window, pane)
			do_change(window, pane, function(w, p)
				w:perform_action(wezterm.action.Multiple({
					wezterm.action.SendKey({ key = "u", mods = "CTRL" }),
					enter_normal,
				}), p)
			end)
		end) },
	}
end
