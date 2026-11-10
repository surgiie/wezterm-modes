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

local REDRAW_SIGNAL = "USR1"
local SIGNAL_TARGET_SHELL = "zsh"
local PROMPT_USER_VAR = "wezterm_modes_prompt"
local COMMAND_SETTLE_SECONDS = 2
local OVERLAY_KEY_TABLES = { copy_mode = true, search_mode = true }

--- Register the update-status event handler that drives the mode status bar.
--- Active key table name determines the displayed mode label.
---
--- Also stashes `ctx.render_jump_status`, a pane->text renderer jump.lua uses
--- to paint the JUMP badge directly into the left status.
---
--- @param ctx table  Plugin context:
---   - NORMAL     string    Normal mode key table name
---   - JUMP       string    Jump mode key table name — paints its own left
---                         status (via ctx.render_jump_status) instead of
---                         the plain mode block below; this handler skips
---                         the left status while a pick is in progress so
---                         it can't stomp that badge mid-pick.
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
	local redraw_enabled = starship_opts ~= nil and starship_opts.redraw ~= false

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

	local clock = ctx.clock or os.time
	local commands_in_flight = {}

	--- Called when a keymap types a command into the pane. The shell still
	--- reports "1" until it reads that input, so a redraw sent in that gap
	--- would queue behind the command and land in whatever it launches (fzf).
	--- The pane counts as busy until the shell reports running ("0") and then
	--- the prompt again; a command that finishes between two ticks is never
	--- seen running, so it settles after COMMAND_SETTLE_SECONDS instead.
	ctx.mark_command_sent = function(pane)
		commands_in_flight[pane:pane_id()] = { sent_at = clock(), seen_running = false }
	end

	local function command_settled(pane, prompt_value)
		local pane_id = pane:pane_id()
		local in_flight = commands_in_flight[pane_id]
		if not in_flight then
			return true
		end
		if prompt_value ~= "1" then
			in_flight.seen_running = true
			return false
		end
		if in_flight.seen_running or clock() - in_flight.sent_at >= COMMAND_SETTLE_SECONDS then
			commands_in_flight[pane_id] = nil
			return true
		end
		return false
	end

	--- A bash script or fzf launched from the prompt still passes the
	--- process-name check, so the shell must report that it is at its prompt
	--- via the PROMPT_USER_VAR user var ("1" at the prompt, anything else, or
	--- unset, means not ready). A new shell is therefore not treated as ready
	--- until its first line-init, which keeps the redraw out of rc-file loading.
	local function at_shell(pane)
		local result = false
		if not ctx.pane_is_shell or ctx.pane_is_shell(pane) then
			local vars_ok, user_vars = pcall(function() return pane:get_user_vars() end)
			local prompt_value = vars_ok and user_vars ~= nil and user_vars[PROMPT_USER_VAR] or nil
			local settled = command_settled(pane, prompt_value)
			result = prompt_value == "1" and settled
		end
		return result
	end

	local redraw_pending = {}

	--- Copy mode and its search bar are overlays on the pane. The badge stays
	--- visible there because the shell prompt underneath is not what is shown.
	local function in_overlay(window)
		return OVERLAY_KEY_TABLES[window:active_key_table()] == true
	end

	--- Signal the pane's foreground shell so it redraws its prompt. Nothing is
	--- typed into the pane, so an overlay or a half-read escape sequence cannot
	--- swallow it. Only a zsh is signalled: SIGUSR1 terminates any process
	--- without a handler.
	--- @return boolean  true if a signal was sent
	local function signal_shell(pane)
		local info_ok, info = pcall(function() return pane:get_foreground_process_info() end)
		if not info_ok or type(info) ~= "table" or not info.pid then
			return false
		end
		local executable = info.executable or info.name or ""
		if executable:match("[^/]*$") ~= SIGNAL_TARGET_SHELL then
			return false
		end
		wezterm.background_child_process({ "kill", "-" .. REDRAW_SIGNAL, tostring(info.pid) })
		return true
	end

	--- Signal the shell now if the pane is at a prompt, otherwise leave it
	--- pending so a later tick delivers it instead of losing it.
	local function request_redraw(window, pane)
		if not redraw_enabled then
			return
		end
		local pane_id = pane:pane_id()
		if at_shell(pane) and signal_shell(pane) then
			redraw_pending[pane_id] = nil
		else
			redraw_pending[pane_id] = true
		end
	end

	local function flush_pending_redraw(window, pane)
		if redraw_pending[pane:pane_id()] then
			request_redraw(window, pane)
		end
	end

	--- Set the left status to a mode badge, or to just the caller's prefix when
	--- the badge is disabled and the pane is at a shell prompt (starship shows
	--- the mode there; other panes such as a REPL keep the badge).
	local function show_badge(window, pane, rendered)
		local hidden = not badge_enabled and at_shell(pane) and not in_overlay(window)
		window:set_left_status(hidden and prefix(pane) or rendered)
	end

	--- Publish the label to starship's state file and, when it changed, nudge
	--- the shell to redraw its prompt. should_run can be true for non-shell
	--- panes (callers may allow e.g. a REPL), so the sequence is additionally
	--- gated on ctx.pane_is_shell to keep it out of TUIs.
	local function publish_mode(window, pane, label, skip_redraw)
		if not state_publisher then
			return
		end
		local changed = state_publisher.publish(pane:pane_id(), label)
		if skip_redraw then
			return
		end
		if changed then
			request_redraw(window, pane)
		else
			flush_pending_redraw(window, pane)
		end
	end

	-- jump.lua's entry point into this module's rendering: the same colored
	-- " JUMP " badge as every other mode.
	ctx.render_jump_status = function(pane)
		return prefix(pane) .. wezterm.format({
			{ Background = { Color = COLORS.block } },
			{ Foreground = { Color = COLORS.jump } },
			{ Attribute = { Intensity = "Bold" } },
			{ Text = " JUMP " },
			"ResetAttributes",
		})
	end

	wezterm.on("update-status", function(window, pane)
		local kt = window:active_key_table()
		local active = should_run(pane)

		-- Skip the left status while a jump pick is in progress — jump.lua
		-- paints its own badge there directly, and this handler would
		-- otherwise stomp it. Gated on ctx.jump_state.targets rather than
		-- `kt == JUMP`, since ActivateKeyTable only enqueues the switch and
		-- active_key_table() can briefly still report the old table.
		if active and ctx.jump_state and ctx.jump_state.targets then
			-- No redraw: it would reset the line and wipe the in-line labels.
			-- Leaving JUMP changes the label again and redraws then.
			publish_mode(window, pane, "JUMP", true)
			return
		end

		if active and ctx.hint_state and ctx.hint_state.tokens then
			publish_mode(window, pane, "VISUAL", true)
			show_badge(window, pane, render(pane, COLORS.visual, " VISUAL "))
			return
		end

		if not active then
			local in_visual = ctx.hint_state and ctx.hint_state.tokens ~= nil
				or OVERLAY_KEY_TABLES[kt] == true
				or (ctx.HINT ~= nil and kt == ctx.HINT)
			if in_visual and should_run(pane, "visual") then
				show_badge(window, pane, render(pane, COLORS.visual, " VISUAL "))
				return
			end
			if kt ~= nil then
				window:perform_action(wezterm.action.PopKeyTable, pane)
			end
			redraw_pending[pane:pane_id()] = nil
			commands_in_flight[pane:pane_id()] = nil
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
