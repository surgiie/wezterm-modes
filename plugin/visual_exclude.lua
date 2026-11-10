local DEFAULT_PATTERNS = { "^g?n?vim", "^vi$", "^view$", "^vimdiff$", " %- g?n?vim$" }

--- Return true when the pane's foreground process name or title matches one
--- of the patterns (Lua patterns, matched case-insensitively).
--- Title is checked too because process names don't cross the WSL boundary.
--- @param pane     table     WezTerm Pane object
--- @param patterns string[]  Lua patterns
--- @return boolean
local function pane_matches(pane, patterns)
	local executable = (pane:get_foreground_process_name() or ""):lower():match("[^/\\]*$")
	local title = (pane:get_title() or ""):lower()
	for _, pattern in ipairs(patterns) do
		if executable:find(pattern) or title:find(pattern) then return true end
	end
	return false
end

return { DEFAULT_PATTERNS = DEFAULT_PATTERNS, pane_matches = pane_matches }
