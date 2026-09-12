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
---   - JUMP       string    Jump mode key table name — the only mode that
---                         owns the right status (its label:word legend);
---                         every other mode gets it forced blank here on
---                         every tick, so the legend can't outlive jump_mode
---                         no matter how it was left (a completed jump,
---                         Escape, a pane focus change, config reload, or
---                         any key falling through unhandled) — jump.lua's
---                         own clear on commit/cancel is still there for
---                         immediate feedback; this is the backstop.
---   - should_run function  function(pane) → boolean; false = plugin is no-op for this pane
---   - left_status_prefix function(pane) → string?  Caller-supplied decoration
---                         prepended to every left-status render; this module
---                         has no opinion on what it contains.
return function(ctx)
	local NORMAL     = ctx.NORMAL
	local YANK       = ctx.YANK
	local DELETE     = ctx.DELETE
	local KEYMAP     = ctx.KEYMAP
	local COUNT      = ctx.COUNT
	local JUMP       = ctx.JUMP
	local should_run = ctx.should_run
	local icon       = ctx.icon or ""
	local left_status_prefix = ctx.left_status_prefix

	local function prefix(pane)
		if not left_status_prefix then
			return ""
		end
		return left_status_prefix(pane) or ""
	end

	--- Render a bold colored status block with no separator glyphs.
	--- @param pane userdata WezTerm pane, passed through to left_status_prefix
	--- @param bg   string  Hex background color
	--- @param text string  Label text (include surrounding spaces for padding)
	--- @return string      Formatted WezTerm status string
	local function render(pane, bg, text)
		return prefix(pane) .. wezterm.format({
			{ Background = { Color = bg } },
			{ Foreground = { Color = COLORS.fg } },
			{ Attribute = { Intensity = "Bold" } },
			{ Text = text },
			{ Attribute = { Intensity = "Normal" } },
		})
	end

	wezterm.on("update-status", function(window, pane)
		local kt = window:active_key_table()
		local active = should_run(pane)

		-- The right status is jump_mode's label:word legend and belongs to
		-- it alone, and only while the plugin actually considers itself
		-- active for this pane. Force it blank every other tick, so it
		-- can't outlive jump_mode regardless of how that mode was left —
		-- jump.lua clears it itself on a completed jump or Escape, but a
		-- pane focus change, config reload, or any key falling through
		-- unhandled would otherwise leave it stuck.
		if kt ~= JUMP or not active then
			window:set_right_status("")
		end

		if not active then
			if kt ~= nil then
				window:perform_action(wezterm.action.PopKeyTable, pane)
			end
			if window:leader_is_active() then
				window:set_left_status(render(pane, COLORS.leader, " LEADER "))
			else
				window:set_left_status(prefix(pane) .. (icon ~= "" and (" " .. icon .. " ") or ""))
			end
			return
		end

		if window:leader_is_active() then
			window:set_left_status(render(pane, COLORS.leader, " LEADER "))
		elseif kt == NORMAL then
			window:set_left_status(render(pane, COLORS.normal, " NORMAL "))
		elseif kt == "copy_mode" then
			window:set_left_status(render(pane, COLORS.visual, " VISUAL "))
		elseif kt == YANK or kt == DELETE or kt == COUNT or kt == JUMP then
			window:set_left_status(render(pane, COLORS.normal, " NORMAL "))
		elseif kt == KEYMAP or (kt and KEYMAP and kt:find("^" .. KEYMAP .. "_")) then
			window:set_left_status(render(pane, COLORS.keymap, " KEYMAP "))
		elseif kt and kt:find("^" .. NORMAL) then
			window:set_left_status(render(pane, COLORS.normal, " NORMAL "))
		else
			window:set_left_status(render(pane, COLORS.insert, " INSERT "))
		end
	end)
end
