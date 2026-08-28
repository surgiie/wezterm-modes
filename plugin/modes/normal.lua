local wezterm = require("wezterm")

-- All printable keys are swallowed in normal mode so they don't reach the shell.
-- Specific keys below override these no-ops with intentional actions.
local swallowed = {
	"a","b","c","d","e","f","g","h","i","j","k","l","m",
	"n","o","p","q","r","s","t","u","v","w","x","y","z",
	"A","B","C","D","E","F","G","H","I","J","K","L","M",
	"N","O","P","Q","R","S","T","U","V","W","X","Y","Z",
	"1","2","3","4","5","6","7","8","9","0",
	"`","~","!","@","#","$","%","^","&","*","(",")","_",
	"+","=","[","]","{","}","\\","|",";","'",":",'"',
	",",".","<",">","/","?","-"," ",
}

-- WezTerm sends some shifted combos as key=digit mods=SHIFT rather than the
-- resulting symbol, so these need an explicit SHIFT entry to be swallowed too.
local swallowed_shift = {
	"1","2","3","4","5","6","7","8","9","0","-","=","[","]","\\",";","'",",",".","/"," ",
}

local function goto_first_non_whitespace(window, pane)
	local zones = pane:get_semantic_zones("Input")
	local leading = 0
	if zones and #zones > 0 then
		local text = pane:get_text_from_semantic_zone(zones[#zones]):gsub("%s+$", "")
		local prefix = text:match("^(%s*)")
		leading = prefix and #prefix or 0
	end
	local actions = { wezterm.action.SendKey({ key = "a", mods = "CTRL" }) }
	for _ = 1, leading do
		table.insert(actions, wezterm.action.SendKey({ key = "RightArrow" }))
	end
	window:perform_action(wezterm.action.Multiple(actions), pane)
end

--- Build and return the normal mode key table.
--- @param ctx table  Plugin context (enter_insert, noop, YANK, DELETE, MOTION, KEYMAP, COUNT)
--- @return table     List of WezTerm key binding definitions
return function(ctx)
	local enter_insert    = ctx.enter_insert
	local noop            = ctx.noop
	local YANK            = ctx.YANK
	local DELETE          = ctx.DELETE
	local MOTION          = ctx.MOTION
	local REPLACE         = ctx.REPLACE
	local KEYMAP          = ctx.KEYMAP
	local COUNT           = ctx.COUNT
	local should_run      = ctx.should_run
	local kt_timeout      = ctx.kt_timeout
	local keymaps         = ctx.keymaps
	local execute_command = ctx.execute_command
	local count_state     = ctx.count_state
	local last_change     = ctx.last_change
	local do_change       = ctx.do_change

	local function open_keymap_picker(window, pane)
		if not should_run(pane) then return end
		local choices = {}
		for _, binding in ipairs(keymaps) do
			table.insert(choices, { id = binding.key, label = (binding.description or binding.key) .. " (" .. binding.key .. ")" })
		end
		window:perform_action(
			wezterm.action.InputSelector({
				title   = "Keymaps",
				fuzzy   = true,
				choices = choices,
				action  = wezterm.action_callback(function(inner_window, inner_pane, id)
					if not id then return end
					for _, binding in ipairs(keymaps) do
						if binding.key == id then
							if not should_run(inner_pane) then return end
							execute_command(inner_pane, binding)
							inner_window:perform_action(enter_insert, inner_pane)
							return
						end
					end
				end),
			}),
			pane
		)
	end

	local keys = {}

	for _, k in ipairs(swallowed) do
		table.insert(keys, { key = k, mods = "NONE",  action = noop })
		table.insert(keys, { key = k, mods = "SHIFT", action = noop })
	end
	for _, k in ipairs(swallowed_shift) do
		table.insert(keys, { key = k, mods = "SHIFT", action = noop })
	end

	local bindings = {
		-- swallow keys that should not pass through in normal mode
		{ key = "Backspace", action = noop },
		{ key = "Delete",    action = noop },
		{ key = "Enter",     action = noop },

		-- mode transitions
		{ key = "i",      action = enter_insert },
		{ key = "Escape", action = wezterm.action.SendKey({ key = "Escape" }) },

		-- cursor movement
		{ key = "h", action = wezterm.action.SendKey({ key = "LeftArrow" }) },
		{ key = "j", action = wezterm.action.SendKey({ key = "DownArrow" }) },
		{ key = "k", action = wezterm.action.SendKey({ key = "UpArrow" }) },
		{ key = "l", action = wezterm.action.SendKey({ key = "RightArrow" }) },

		-- word jump
		{ key = "w", action = wezterm.action.SendKey({ key = "f", mods = "ALT" }) },
		{ key = "b", action = wezterm.action.SendKey({ key = "b", mods = "ALT" }) },
		{ key = "e", action = wezterm.action.SendKey({ key = "f", mods = "ALT" }) },

		-- character delete: x deletes forward (DEL), X deletes backward (Backspace)
		{ key = "x", action = wezterm.action_callback(function(window, pane)
			do_change(window, pane, function(w, p)
				w:perform_action(wezterm.action.SendKey({ key = "Delete" }), p)
			end)
		end) },
		{ key = "X", action = wezterm.action_callback(function(window, pane)
			do_change(window, pane, function(w, p)
				w:perform_action(wezterm.action.SendKey({ key = "Backspace" }), p)
			end)
		end) },

		-- insert at line boundaries
		{ key = "A", action = wezterm.action.Multiple({
			wezterm.action.SendKey({ key = "e", mods = "CTRL" }), -- move to end of line
			enter_insert,
		}) },
		{ key = "I", action = wezterm.action.Multiple({
			wezterm.action.SendKey({ key = "a", mods = "CTRL" }), -- move to start of line
			enter_insert,
		}) },

		-- C: delete to end of line, enter insert
		{ key = "C", action = wezterm.action.Multiple({
			wezterm.action.SendKey({ key = "k", mods = "CTRL" }),
			enter_insert,
		}) },

		-- D: delete to end of line, stay in normal
		{ key = "D", action = wezterm.action_callback(function(window, pane)
			do_change(window, pane, function(w, p)
				w:perform_action(wezterm.action.SendKey({ key = "k", mods = "CTRL" }), p)
			end)
		end) },

		-- s: delete char forward, enter insert
		{ key = "s", action = wezterm.action.Multiple({
			wezterm.action.SendKey({ key = "Delete" }),
			enter_insert,
		}) },

		-- S: delete whole line, enter insert
		{ key = "S", action = wezterm.action.Multiple({
			wezterm.action.SendKey({ key = "u", mods = "CTRL" }),
			wezterm.action.SendKey({ key = "k", mods = "CTRL" }),
			enter_insert,
		}) },

		-- line start/end
		{ key = "0",             action = wezterm.action.SendKey({ key = "a", mods = "CTRL" }) },
		{ key = "$", mods = "NONE",  action = wezterm.action.SendKey({ key = "e", mods = "CTRL" }) },
		{ key = "$", mods = "SHIFT", action = wezterm.action.SendKey({ key = "e", mods = "CTRL" }) },
		{ key = "4", mods = "SHIFT", action = wezterm.action.SendKey({ key = "e", mods = "CTRL" }) },

		-- ^/6: move to first non-whitespace character (vim-style)
		{ key = "^", mods = "NONE",  action = wezterm.action_callback(goto_first_non_whitespace) },
		{ key = "^", mods = "SHIFT", action = wezterm.action_callback(goto_first_non_whitespace) },
		{ key = "6", mods = "SHIFT", action = wezterm.action_callback(goto_first_non_whitespace) },

		-- gg/G motions (g activates motion key table; G jumps to line end directly)
		{ key = "G", action = wezterm.action.SendKey({ key = "e", mods = "CTRL" }) },
		{ key = "g", action = wezterm.action.ActivateKeyTable({ name = MOTION, one_shot = false, timeout_milliseconds = 1000 }) },

		-- scrollback
		{ key = "u", mods = "CTRL", action = wezterm.action.ScrollByPage(-0.5) },
		{ key = "d", mods = "CTRL", action = wezterm.action.ScrollByPage(0.5) },
		{ key = "f", mods = "CTRL", action = wezterm.action.ScrollByPage(1) },
		{ key = "b", mods = "CTRL", action = wezterm.action.ScrollByPage(-1) },

		-- r: replace single char (capture next key in replace mode)
		{ key = "r", action = wezterm.action.ActivateKeyTable({ name = REPLACE, one_shot = true, timeout_milliseconds = 5000 }) },

		-- u: undo, via readline's built-in undo binding (CTRL+_).
		-- Not full vim undo (it's the shell's line-edit undo, not a true history
		-- stack across mode changes), but recovers the common case: an accidental
		-- x/dd/etc. on the current input line. CTRL+u stays bound to half-page
		-- scroll above, matching existing behavior.
		{ key = "u", mods = "NONE", action = wezterm.action.SendKey({ key = "_", mods = "CTRL" }) },

		-- .: repeat the last change (x, X, D, dd, dw, db, d$, d0, d^, yd, r{c}, etc.)
		{ key = ".", mods = "NONE", action = wezterm.action_callback(function(window, pane)
			if last_change.run then last_change.run(window, pane) end
		end) },

		-- visual mode: enters WezTerm's built-in copy_mode key table; status shows VISUAL
		{ key = "v", action = wezterm.action.ActivateCopyMode },

		-- yank/paste/delete
		{ key = "y", action = wezterm.action.ActivateKeyTable({ name = YANK,   one_shot = false, timeout_milliseconds = 2000 }) },
		{ key = "d", action = wezterm.action.ActivateKeyTable({ name = DELETE,  one_shot = false, timeout_milliseconds = 2000 }) },
		{ key = "p", action = wezterm.action_callback(function(window, pane)
			window:perform_action(wezterm.action({ PasteFrom = "Clipboard" }), pane)
		end) },

		-- ?: fuzzy picker over configured keymaps
		{ key = "?", mods = "NONE",  action = wezterm.action_callback(function(window, pane) open_keymap_picker(window, pane) end) },
		{ key = "?", mods = "SHIFT", action = wezterm.action_callback(function(window, pane) open_keymap_picker(window, pane) end) },
		{ key = "/", mods = "SHIFT", action = wezterm.action_callback(function(window, pane) open_keymap_picker(window, pane) end) },

		-- ctrl passthroughs
		{ key = "c", mods = "CTRL", action = wezterm.action.SendKey({ key = "c", mods = "CTRL" }) },
		{ key = "z", mods = "CTRL", action = wezterm.action.SendKey({ key = "z", mods = "CTRL" }) },
		{ key = "l", mods = "CTRL", action = wezterm.action.SendKey({ key = "l", mods = "CTRL" }) },
	}

	if keymaps and #keymaps > 0 then
		-- :: enter keymap mode (its own key table, built in keymap.lua).
		-- Custom keymaps live entirely under this namespace, so they're free to
		-- reuse any letter — including vim motion keys like h/j/k/v/g — without
		-- colliding with normal mode's own bindings.
		local activate_keymap = wezterm.action.ActivateKeyTable({
			name                 = KEYMAP,
			one_shot             = true,
			timeout_milliseconds = kt_timeout,
		})
		table.insert(bindings, { key = ":", mods = "NONE",  action = activate_keymap })
		table.insert(bindings, { key = ":", mods = "SHIFT", action = activate_keymap })
	end

	-- 1-9: start a numeric prefix for word motions (3w, 5b) and counted
	-- delete (3dw, 2db). A leading 0 stays line-start per vim convention,
	-- so it's excluded here and left bound above.
	for d = 1, 9 do
		table.insert(bindings, {
			key = tostring(d),
			action = wezterm.action_callback(function(window, pane)
				count_state.n = d
				window:perform_action(wezterm.action.ActivateKeyTable({
					name = COUNT, one_shot = false, timeout_milliseconds = kt_timeout,
				}), pane)
			end),
		})
	end

	for _, b in ipairs(bindings) do
		table.insert(keys, b)
	end

	return keys
end
