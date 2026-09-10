local wezterm = require("wezterm")

--- Build and return the replace mode key table.
--- Entered via `r` in normal mode; waits for one char, replaces char under
--- cursor with it (delete forward + insert char), then returns to normal.
--- @param ctx table  Plugin context (enter_normal, do_change)
--- @return table     List of WezTerm key binding definitions
return function(ctx)
	local enter_normal = ctx.enter_normal
	local do_change    = ctx.do_change

	local keys = {}

	-- Every printable character: delete the char under cursor and type the replacement
	local chars = {
		"a","b","c","d","e","f","g","h","i","j","k","l","m",
		"n","o","p","q","r","s","t","u","v","w","x","y","z",
		"A","B","C","D","E","F","G","H","I","J","K","L","M",
		"N","O","P","Q","R","S","T","U","V","W","X","Y","Z",
		"1","2","3","4","5","6","7","8","9","0",
		"`","~","!","@","#","$","%","^","&","*","(",")","_",
		"+","=","[","]","{","}","\\","|",";","'",":",'"',
		",",".","<",">","/","?","-"," ",
	}

	for _, k in ipairs(chars) do
		table.insert(keys, {
			key = k,
			action = wezterm.action_callback(function(window, pane)
				do_change(window, pane, function(w, p)
					w:perform_action(wezterm.action.Multiple({
						wezterm.action.SendKey({ key = "Delete" }),
						wezterm.action.SendKey({ key = k }),
						wezterm.action.SendKey({ key = "LeftArrow" }),
						enter_normal,
					}), p)
				end)
			end),
		})
	end

	table.insert(keys, { key = "Escape", action = enter_normal })

	return keys
end
