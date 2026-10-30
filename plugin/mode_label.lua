--- Build a resolver that maps the active key table to a mode label.
--- Pure: no wezterm dependency, so it can be unit tested directly.
---
--- @param ctx table  Key table name constants: NORMAL, YANK, DELETE, MOTION, REPLACE, KEYMAP, COUNT, JUMP
--- @return fun(key_table: string?, leader_active: boolean): string
return function(ctx)
	local NORMAL  = ctx.NORMAL
	local YANK    = ctx.YANK
	local DELETE  = ctx.DELETE
	local MOTION  = ctx.MOTION
	local REPLACE = ctx.REPLACE
	local KEYMAP  = ctx.KEYMAP
	local COUNT   = ctx.COUNT
	local JUMP    = ctx.JUMP

	return function(key_table, leader_active)
		if leader_active then
			return "LEADER"
		elseif key_table == NORMAL then
			return "NORMAL"
		elseif key_table == "copy_mode" then
			return "VISUAL"
		elseif key_table == YANK or key_table == DELETE or key_table == COUNT
			or key_table == MOTION or key_table == REPLACE then
			return "NORMAL"
		elseif key_table == JUMP then
			return "JUMP"
		elseif key_table == KEYMAP or (key_table and KEYMAP and key_table:find("^" .. KEYMAP .. "_")) then
			return "KEYMAP"
		elseif key_table and key_table:find("^" .. NORMAL) then
			return "NORMAL"
		end
		return "INSERT"
	end
end
