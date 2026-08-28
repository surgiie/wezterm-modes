local wezterm = require("wezterm")

local COLORS = {
	leader  = "#ffff87",
	normal  = "#a4e400",
	insert  = "#89ddff",
	visual  = "#e0a060",
	keymap  = "#c792ea",
	other   = "#ffff87",
	fg      = "#000001",
}

--- Register the update-status event handler that drives the mode status bar.
--- Active key table name determines the displayed mode label.
---
--- @param ctx table  Plugin context:
---   - NORMAL     string    Normal mode key table name
---   - should_run function  function(pane) → boolean; false = plugin is no-op for this pane
return function(ctx)
	local NORMAL     = ctx.NORMAL
	local YANK       = ctx.YANK
	local DELETE     = ctx.DELETE
	local KEYMAP     = ctx.KEYMAP
	local COUNT      = ctx.COUNT
	local should_run = ctx.should_run
	local icon       = ctx.icon or ""

	--- Render a bold colored status block with no separator glyphs.
	--- @param bg   string  Hex background color
	--- @param text string  Label text (include surrounding spaces for padding)
	--- @return string      Formatted WezTerm status string
	local function render(bg, text)
		return wezterm.format({
			{ Background = { Color = bg } },
			{ Foreground = { Color = COLORS.fg } },
			{ Attribute = { Intensity = "Bold" } },
			{ Text = text },
			{ Attribute = { Intensity = "Normal" } },
		})
	end

	wezterm.on("update-status", function(window, pane)
		if not should_run(pane) then
			if window:active_key_table() ~= nil then
				window:perform_action(wezterm.action.PopKeyTable, pane)
			end
			if window:leader_is_active() then
				window:set_left_status(render(COLORS.leader, " LEADER "))
			else
				window:set_left_status(icon ~= "" and (" " .. icon .. " ") or "")
			end
			return
		end

		local kt = window:active_key_table()

		if window:leader_is_active() then
			window:set_left_status(render(COLORS.leader, " LEADER "))
		elseif kt == NORMAL then
			window:set_left_status(render(COLORS.normal, " NORMAL "))
		elseif kt == "copy_mode" then
			window:set_left_status(render(COLORS.visual, " VISUAL "))
		elseif kt == YANK or kt == DELETE or kt == COUNT then
			window:set_left_status(render(COLORS.normal, " NORMAL "))
		elseif kt == KEYMAP or (kt and KEYMAP and kt:find("^" .. KEYMAP .. "_")) then
			window:set_left_status(render(COLORS.keymap, " KEYMAP "))
		elseif kt and kt:find("^" .. NORMAL) then
			window:set_left_status(render(COLORS.normal, " NORMAL "))
		else
			window:set_left_status(render(COLORS.insert, " INSERT "))
		end
	end)
end
