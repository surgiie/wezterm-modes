local wezterm = require("wezterm")

--- Copy the current shell input line to the clipboard using WezTerm semantic zones.
--- Requires WezTerm shell integration to be sourced so the terminal emits Input zones.
--- Trailing whitespace is stripped before copying.
--- @param window table  WezTerm Window object
--- @param pane   table  WezTerm Pane object
local function yank_input(window, pane)
	local zones = pane:get_semantic_zones("Input")
	if zones and #zones > 0 then
		local text = pane:get_text_from_semantic_zone(zones[#zones])
		window:copy_to_clipboard(text:gsub("%s+$", ""), "ClipboardAndPrimarySelection")
	end
end

--- Build and return the yank mode key table.
--- Entered via `y` in normal mode; times out after kt_timeout ms with no second key.
--- @param ctx table  Plugin context (enter_normal, do_change)
--- @return table     List of WezTerm key binding definitions
return function(ctx)
	local enter_normal = ctx.enter_normal
	local do_change    = ctx.do_change

	return {
		{ key = "Escape", action = enter_normal },

		-- yy: copy current input line to clipboard, return to normal.
		-- Not tracked for `.` repeat — a copy isn't a "change".
		{ key = "y", action = wezterm.action_callback(function(window, pane)
			yank_input(window, pane)
			window:perform_action(enter_normal, pane)
		end) },

		-- yd: copy current input line then delete it, return to normal
		{ key = "d", action = wezterm.action_callback(function(window, pane)
			yank_input(window, pane)
			do_change(window, pane, function(w, p)
				w:perform_action(wezterm.action.Multiple({
					wezterm.action.SendKey({ key = "u", mods = "CTRL" }),
					wezterm.action.SendKey({ key = "k", mods = "CTRL" }),
					enter_normal,
				}), p)
			end)
		end) },
	}
end
