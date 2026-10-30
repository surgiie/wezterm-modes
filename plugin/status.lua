local wezterm = require("wezterm")

local COLORS = {
	leader  = "#ffff87",
	normal  = "#a4e400",
	insert  = "#5fafd7",
	visual  = "#e0a060",
	keymap  = "#c792ea",
	jump    = "#ff5555",
	other   = "#ffff87",
	block   = "#1c1c1c",
}

local DEFAULT_REDRAW_SEQUENCE = "\27[9001~"

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
	local should_run = ctx.should_run
	local icon       = ctx.icon or ""
	local left_status_prefix = ctx.left_status_prefix

	local resolve_label = ctx.load("mode_label.lua")(ctx)
	local starship_opts = ctx.starship
	local state_publisher = starship_opts and ctx.load("starship.lua")(starship_opts) or nil
	local badge_enabled = not (starship_opts and starship_opts.badge == false)
	local redraw_sequence = nil
	if starship_opts and starship_opts.redraw_sequence ~= false then
		redraw_sequence = starship_opts.redraw_sequence or DEFAULT_REDRAW_SEQUENCE
	end

	local LABEL_COLORS = {
		LEADER = COLORS.leader,
		NORMAL = COLORS.normal,
		INSERT = COLORS.insert,
		VISUAL = COLORS.visual,
		KEYMAP = COLORS.keymap,
		JUMP   = COLORS.jump,
	}

	local function prefix(pane)
		if not left_status_prefix then
			return ""
		end
		return left_status_prefix(pane) or ""
	end

	--- Render a bold status block with no separator glyphs: mode-colored text
	--- on a dark block.
	--- @param pane userdata WezTerm pane, passed through to left_status_prefix
	--- @param color string Hex text color
	--- @param text string  Label text (include surrounding spaces for padding)
	--- @return string      Formatted WezTerm status string
	local function render(pane, color, text)
		return prefix(pane) .. wezterm.format({
			{ Background = { Color = COLORS.block } },
			{ Foreground = { Color = color } },
			{ Attribute = { Intensity = "Bold" } },
			{ Text = text },
			{ Attribute = { Intensity = "Normal" } },
		})
	end

	--- A bash script or fzf launched from the prompt still passes the
	--- process-name check, so with shell integration the cursor must also be
	--- inside the last Input zone. Without integration the zone check is
	--- skipped.
	local function at_shell(pane)
		if ctx.pane_is_shell and not ctx.pane_is_shell(pane) then
			return false
		end
		local zones_ok, zones = pcall(pane.get_semantic_zones, pane, "Input")
		if not zones_ok or not zones or #zones == 0 then
			return true
		end
		local zone = zones[#zones]
		local cursor_row = pane:get_cursor_position().y
		return cursor_row >= zone.start_y and cursor_row <= zone.end_y
	end

	--- Set the left status to a mode badge, or to just the caller's prefix when
	--- the badge is disabled and the pane is at a shell prompt (starship shows
	--- the mode there; other panes such as a REPL keep the badge).
	local function show_badge(window, pane, rendered)
		local hidden = not badge_enabled and at_shell(pane)
		window:set_left_status(hidden and prefix(pane) or rendered)
	end

	--- Publish the label to starship's state file and, when it changed, nudge
	--- the shell to redraw its prompt. should_run can be true for non-shell
	--- panes (callers may allow e.g. a REPL), so the sequence is additionally
	--- gated on ctx.pane_is_shell to keep it out of TUIs.
	local function publish_mode(window, pane, label)
		if not state_publisher then
			return
		end
		local changed = state_publisher.publish(pane:pane_id(), label)
		if changed and redraw_sequence and at_shell(pane) then
			window:perform_action(wezterm.action.SendString(redraw_sequence), pane)
		end
	end

	--- jump.lua's hooks for showing the legend in the prompt. No-ops without
	--- starship opts. The redraw is gated like publish_mode's.
	ctx.publish_legend = function(window, pane, text)
		if not state_publisher then
			return
		end
		local changed = state_publisher.publish_legend(pane:pane_id(), text)
		if changed and redraw_sequence and at_shell(pane) then
			window:perform_action(wezterm.action.SendString(redraw_sequence), pane)
		end
	end

	ctx.clear_legend = function(pane)
		if state_publisher then
			state_publisher.clear_legend(pane:pane_id())
		end
	end

	-- jump.lua's entry point into this module's rendering: the same colored
	-- " JUMP " badge as every other mode, then ResetAttributes hands back to
	-- default styling for the legend text that follows (jump.lua separately
	-- blanks every tab title for the same duration, so this lands in an
	-- otherwise-empty tab bar).
	ctx.render_jump_status = function(pane, legend)
		return prefix(pane) .. wezterm.format({
			{ Background = { Color = COLORS.block } },
			{ Foreground = { Color = COLORS.jump } },
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
			publish_mode(window, pane, "JUMP")
			return
		end

		if not active then
			if kt ~= nil then
				window:perform_action(wezterm.action.PopKeyTable, pane)
			end
			if state_publisher then
				state_publisher.clear(pane:pane_id())
			end
			if window:leader_is_active() then
				show_badge(window, pane, render(pane, COLORS.leader, " LEADER "))
			else
				window:set_left_status(prefix(pane) .. (icon ~= "" and (" " .. icon .. " ") or ""))
			end
			return
		end

		local label = resolve_label(kt, window:leader_is_active())
		publish_mode(window, pane, label)

		if label == "JUMP" then
			-- Pick just ended but enter_normal hasn't landed yet — plain
			-- badge, no legend, instead of falling through to INSERT.
			show_badge(window, pane, ctx.render_jump_status(pane, ""))
		else
			show_badge(window, pane, render(pane, LABEL_COLORS[label], " " .. label .. " "))
		end
	end)
end
