local wezterm = require("wezterm")

--- Build and return the count mode key table.
--- Entered via a leading digit 1-9 in normal mode (e.g. the "3" in "3dw").
--- Accumulates further digits, then applies the pending count to a word
--- motion (w/b/e) or forwards it into delete mode for a counted dw/db.
--- Any other key cancels the pending count and returns to normal.
--- @param ctx table  Plugin context (enter_normal, noop, DELETE, MOTION, count_state)
--- @return table     List of WezTerm key binding definitions
return function(ctx)
	local enter_normal = ctx.enter_normal
	local DELETE       = ctx.DELETE
	local count_state  = ctx.count_state
	local do_change    = ctx.do_change

	--- Run a SendKey action `count_state.n` times (defaulting to 1), then
	--- clear the pending count and return to normal mode.
	--- @param send table  A wezterm.action.SendKey(...) action
	local function repeat_motion(send)
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

	local function accumulate(d)
		return wezterm.action_callback(function(window, pane)
			count_state.n = (count_state.n or 0) * 10 + d
			-- replace_current: refresh this table's timeout without stacking a
			-- second COUNT entry on top of itself for every extra digit typed.
			window:perform_action(wezterm.action.ActivateKeyTable({
				name = ctx.COUNT, one_shot = false, replace_current = true, timeout_milliseconds = ctx.kt_timeout,
			}), pane)
		end)
	end

	local keys = {
		{ key = "Escape", action = wezterm.action.Multiple({
			wezterm.action_callback(function() count_state.n = nil end),
			enter_normal,
		}) },

		-- further digits extend the pending count
		{ key = "0", action = accumulate(0) },
		{ key = "1", action = accumulate(1) },
		{ key = "2", action = accumulate(2) },
		{ key = "3", action = accumulate(3) },
		{ key = "4", action = accumulate(4) },
		{ key = "5", action = accumulate(5) },
		{ key = "6", action = accumulate(6) },
		{ key = "7", action = accumulate(7) },
		{ key = "8", action = accumulate(8) },
		{ key = "9", action = accumulate(9) },

		-- word motions: repeat N times
		{ key = "w", action = repeat_motion(wezterm.action.SendKey({ key = "f", mods = "ALT" })) },
		{ key = "b", action = repeat_motion(wezterm.action.SendKey({ key = "b", mods = "ALT" })) },
		{ key = "e", action = repeat_motion(wezterm.action.SendKey({ key = "f", mods = "ALT" })) },

		-- d: forward the pending count into delete mode for 3dw/2db.
		-- count_state.n is left set; delete.lua's w/b handlers consume it.
		-- replace_current so COUNT doesn't stay stacked beneath DELETE.
		{ key = "d", action = wezterm.action.ActivateKeyTable({
			name = DELETE, one_shot = false, replace_current = true, timeout_milliseconds = ctx.kt_timeout,
		}) },
	}

	-- Any other key: cancel the pending count and fall back to normal mode,
	-- rather than either swallowing it forever or letting it leak through to
	-- the pane as a literal typed character.
	local fallback = wezterm.action.Multiple({
		wezterm.action_callback(function() count_state.n = nil end),
		enter_normal,
	})
	local other_keys = {
		"a","c","f","g","h","i","j","k","l","m","n","o","p","q","r","s","t","u","v","x","y","z",
		"A","B","C","D","E","F","G","H","I","J","K","L","M",
		"N","O","P","Q","R","S","T","U","V","W","X","Y","Z",
		"`","~","!","@","#","$","%","^","&","*","(",")","_",
		"+","=","[","]","{","}","\\","|",";","'",":",'"',
		",",".","<",">","/","?","-"," ",
		"Backspace","Delete","Enter",
	}
	for _, k in ipairs(other_keys) do
		table.insert(keys, { key = k, mods = "NONE",  action = fallback })
		table.insert(keys, { key = k, mods = "SHIFT", action = fallback })
	end

	return keys
end
