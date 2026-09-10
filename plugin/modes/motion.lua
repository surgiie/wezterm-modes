local wezterm = require("wezterm")

--- Build and return the motion mode key table.
--- Entered via `g` in normal mode to handle multi-key motions (e.g. gg).
--- Times out after 1000 ms with no second key.
--- @param ctx table  Plugin context (enter_normal)
--- @return table     List of WezTerm key binding definitions
return function(ctx)
	local enter_normal = ctx.enter_normal

	return {
		{ key = "Escape", action = enter_normal },

		-- gg: jump to start of line (readline CTRL+A)
		{ key = "g", action = wezterm.action.Multiple({
			wezterm.action.SendKey({ key = "a", mods = "CTRL" }),
			enter_normal,
		}) },
	}
end
