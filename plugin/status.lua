local wezterm = require("wezterm")

local COLORS = {
	leader  = "#ffff87",
	normal  = "#a4e400",
	insert  = "#89ddff",
	visual  = "#e0a060",
	keymap  = "#c792ea",
	jump    = "#ff5555",
	other   = "#ffff87",
	fg      = "#000001",
}

--- Register the update-status event handler that drives the mode status bar.
--- Active key table name determines the displayed mode label.
---
--- Also stashes `ctx.render_jump_status`, a pane->text renderer jump.lua uses
--- to paint its label:word legend directly into the left status.
---
--- @param ctx table  Plugin context:
---   - NORMAL     string    Normal mode key table name
---   - JUMP       string    Jump mode key table name — paints its own left
---                         status (via ctx.render_jump_status) instead of
---                         the plain mode block below; this handler skips
---                         the left status while a pick is in progress so
---                         it can't stomp that legend mid-pick.
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

	-- jump.lua's entry point into this module's rendering: the same colored
	-- " JUMP " badge as every other mode, then ResetAttributes hands back to
	-- default styling for the legend text that follows (jump.lua separately
	-- blanks every tab title for the same duration, so this lands in an
	-- otherwise-empty tab bar).
	ctx.render_jump_status = function(pane, legend)
		return prefix(pane) .. wezterm.format({
			{ Background = { Color = COLORS.jump } },
			{ Foreground = { Color = COLORS.fg } },
			{ Attribute = { Intensity = "Bold" } },
			{ Text = " JUMP " },
			"ResetAttributes",
			{ Text = legend ~= "" and ("  " .. legend .. " ") or "" },
		})
	end

	wezterm.on("update-status", function(window, pane)
		local kt = window:active_key_table()
		local active = should_run(pane)

		-- Skip the left status while a jump pick is in progress — jump.lua
		-- paints its own legend there directly, and this handler would
		-- otherwise stomp it. Gated on ctx.jump_state.targets rather than
		-- `kt == JUMP`, since ActivateKeyTable only enqueues the switch and
		-- active_key_table() can briefly still report the old table.
		if active and ctx.jump_state and ctx.jump_state.targets then
			return
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
		elseif kt == YANK or kt == DELETE or kt == COUNT then
			window:set_left_status(render(pane, COLORS.normal, " NORMAL "))
		elseif kt == JUMP then
			-- Pick just ended but enter_normal hasn't landed yet — plain
			-- badge, no legend, instead of falling through to INSERT.
			window:set_left_status(ctx.render_jump_status(pane, ""))
		elseif kt == KEYMAP or (kt and KEYMAP and kt:find("^" .. KEYMAP .. "_")) then
			window:set_left_status(render(pane, COLORS.keymap, " KEYMAP "))
		elseif kt and kt:find("^" .. NORMAL) then
			window:set_left_status(render(pane, COLORS.normal, " NORMAL "))
		else
			window:set_left_status(render(pane, COLORS.insert, " INSERT "))
		end
	end)
end
