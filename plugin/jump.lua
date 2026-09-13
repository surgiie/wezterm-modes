local wezterm = require("wezterm")

-- ── Label generation ──────────────────────────────────────────────────────────
-- Ported from surgiie/nvim-labels' label.lua: build a prefix-free label set from
-- an ordered key alphabet, shortest labels first, so the caller can hand the
-- cheapest labels to the nearest/most useful targets.

local UTF8 = "[%z\1-\127\194-\244][\128-\191]*"

local function to_list(keys)
	if type(keys) == "table" then
		return keys
	end
	local list = {}
	for ch in keys:gmatch(UTF8) do
		list[#list + 1] = ch
	end
	return list
end

local function generate_labels(n, keys)
	local alphabet = to_list(keys)
	local k = #alphabet
	if k < 2 or n <= 0 then
		return {}
	end

	local rank = {}
	for i, ch in ipairs(alphabet) do
		rank[ch] = i
	end

	local slots = {}
	for i = 1, k do
		slots[i] = alphabet[i]
	end

	-- Split the right-most shortest slot into k children until there are enough.
	while #slots < n do
		local min_len = math.huge
		for _, s in ipairs(slots) do
			min_len = math.min(min_len, #s)
		end
		local idx
		for i = #slots, 1, -1 do
			if #slots[i] == min_len then
				idx = i
				break
			end
		end
		local parent = table.remove(slots, idx)
		for i = 1, k do
			slots[#slots + 1] = parent .. alphabet[i]
		end
	end

	local function key_seq(label)
		local out = {}
		for ch in label:gmatch(UTF8) do
			out[#out + 1] = rank[ch] or math.huge
		end
		return out
	end
	table.sort(slots, function(a, b)
		if #a ~= #b then
			return #a < #b
		end
		local sa, sb = key_seq(a), key_seq(b)
		for i = 1, #sa do
			if sa[i] ~= sb[i] then
				return sa[i] < sb[i]
			end
		end
		return false
	end)

	local out = {}
	for i = 1, n do
		out[i] = slots[i]
	end
	return out
end

-- ── Word tokenization ─────────────────────────────────────────────────────────
-- Unlike nvim-labels (which sub-splits camelCase/snake_case identifiers), a
-- shell line's atoms are its whole space-separated tokens — "pod-edge-0" or
-- "-it" are each one target, not several to pick between.

--- Collect { col, text } for every whitespace-separated token in `line`,
--- 0-indexed byte columns, in left-to-right order.
--- @param line    string
--- @param pattern string  Lua pattern selecting what counts as a token;
---                        default "%S+" (any non-blank run).
--- @return table[]
local function collect_words(line, pattern)
	pattern = pattern or "%S+"
	local words = {}
	local col = 1
	while true do
		local s, e = line:find(pattern, col)
		if not s then
			break
		end
		words[#words + 1] = { col = s - 1, text = line:sub(s, e) }
		col = e + 1
	end
	return words
end

--- Convert a screen position into a 0-indexed offset into an Input zone's
--- flattened text (what pane:get_text_from_semantic_zone returns, and what
--- collect_words' word columns are measured against). The naive
--- `x - zone.start_x` only holds on the zone's first row; a position on a
--- wrapped row needs the first row's remaining width plus every full
--- wrapped row before it added back in.
--- @param zone       table  Semantic zone (start_x, start_y, ...)
--- @param y          number Row of the position to convert
--- @param x          number Screen column of the position to convert
--- @param pane_width number Pane width in columns (pane:get_dimensions().cols)
--- @return number           0-indexed offset into the zone's flattened text
local function linear_offset(zone, y, x, pane_width)
	if y <= zone.start_y then
		return x - zone.start_x
	end
	local first_row_width = pane_width - zone.start_x
	local full_wrapped_rows = (y - zone.start_y - 1) * pane_width
	return first_row_width + full_wrapped_rows + x
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- ── Press-the-label selector ──────────────────────────────────────────────────
--
-- WezTerm key tables are fixed at config-load time, but the actual jump
-- targets (today's input line's words) are only known once `J` is pressed.
-- So instead of building a key table per invocation (not possible), this
-- builds ONE static key table up front — one binding per character in
-- `jump_keys`, always present — whose callbacks all read a small shared
-- mutable `state` table that `open_word_jump` refills on every `J` press.
--
-- There's no hook to draw labels inline over the text itself (WezTerm has no
-- way to overlay text on live pane content), so the label:word legend is
-- rendered into the left-status bar for the duration of the pick instead —
-- wide enough there to take the tab bar's place rather than share it
-- (format-tab-title is blanked for the same duration, see below `state`).
--
-- @param ctx table  Plugin context (jump_keys, jump_pattern, JUMP, enter_normal, render_jump_status)
-- @return table     { key_table = <WezTerm key table>,
--                      open_word_jump = function(window, pane) }
return function(ctx)
	local keys         = ctx.jump_keys or "fjdkslaghrueiwotnvbc"
	local jump_pattern = ctx.jump_pattern
	local enter_normal = ctx.enter_normal

	-- Per-invocation state, closed over by the static key table's callbacks.
	-- targets: { [label] = column }; order: [{ label, text }] nearest-first,
	-- for the status-bar legend. prefix narrows as keys are typed.
	local state = { targets = nil, order = nil, prefix = "", cur_col = 0 }
	-- Exposed so status.lua can gate on it directly instead of on
	-- window:active_key_table(), which can briefly lag state.targets right
	-- after ActivateKeyTable (only enqueued, not applied synchronously).
	ctx.jump_state = state

	-- Blank every tab's title for as long as a pick is in progress, so the
	-- legend takes the tab bar's own space. Only the first format-tab-title
	-- handler registered ever runs (WezTerm's rule), and state.targets is
	-- shared plugin-wide state like count_state/last_change elsewhere in
	-- this codebase, so a pick in one window blanks tabs in every window.
	wezterm.on("format-tab-title", function()
		if state.targets then
			return ""
		end
		return nil -- defer to WezTerm's normal tab title computation
	end)

	local function render_status(window, pane)
		local parts = {}
		for _, entry in ipairs(state.order) do
			if entry.label:sub(1, #state.prefix) == state.prefix then
				parts[#parts + 1] = entry.label .. ":" .. entry.text
			end
		end
		window:set_left_status(ctx.render_jump_status(pane, table.concat(parts, "  ")))
	end

	local function cancel(window, pane)
		state.targets = nil
		window:perform_action(enter_normal, pane)
	end

	local function commit(window, pane, col)
		local delta = col - state.cur_col
		state.targets = nil

		-- CTRL+F/CTRL+B, not arrow keys: confirmed via bindkey that both
		-- land on forward-char/backward-char, but as a single control byte
		-- with no ESC prefix — repeated arrow-key escape sequences were
		-- getting misparsed by ZLE's escape-timing heuristic and leaking
		-- partial sequences as literal text.
		--
		-- The leading EmitEvent is a disposable no-op (no handler is
		-- registered for that name): the keystroke that commits a jump can
		-- still be mid-processing when this Multiple's first action fires,
		-- and that one loses the race. For a typed string that drops a
		-- leading byte, visible as truncated text; for a single-byte
		-- CTRL+F/CTRL+B, a dropped press is invisible — just a silent
		-- one-off undershoot. Sacrificing the no-op absorbs that instead of
		-- a real keypress.
		local actions = { wezterm.action.EmitEvent("wezterm-modes-jump-noop") }
		local move = delta > 0 and { key = "f", mods = "CTRL" } or { key = "b", mods = "CTRL" }
		for _ = 1, math.abs(delta) do
			actions[#actions + 1] = wezterm.action.SendKey(move)
		end
		actions[#actions + 1] = enter_normal

		window:perform_action(wezterm.action.Multiple(actions), pane)

		-- Backstop: verify where the cursor actually landed a beat later
		-- and nudge it the rest of the way if it's off. CTRL+SHIFT+L logs
		-- only when a correction fires — should be rare to never.
		wezterm.time.call_after(0.05, function()
			pcall(function()
				local zones = pane:get_semantic_zones("Input")
				if not zones or #zones == 0 then return end
				local zone = zones[#zones]
				local cursor = pane:get_cursor_position()
				if cursor.y < zone.start_y or cursor.y > zone.end_y then return end
				local actual_col = linear_offset(zone, cursor.y, cursor.x, pane:get_dimensions().cols)
				local correction = col - actual_col
				if correction == 0 then return end
				wezterm.log_info(string.format(
					"[jump] correcting drift: landed at %d, wanted %d (%+d)",
					actual_col, col, correction
				))
				local corr_move = correction > 0 and { key = "f", mods = "CTRL" } or { key = "b", mods = "CTRL" }
				local corr_actions = {}
				for _ = 1, math.abs(correction) do
					corr_actions[#corr_actions + 1] = wezterm.action.SendKey(corr_move)
				end
				window:perform_action(wezterm.action.Multiple(corr_actions), pane)
			end)
		end)
	end

	local function handle_key(window, pane, ch)
		if not state.targets then
			return
		end
		local candidate = state.prefix .. ch
		local col = state.targets[candidate]
		if col then
			commit(window, pane, col)
			return
		end
		local any = false
		for label in pairs(state.targets) do
			if label:sub(1, #candidate) == candidate then
				any = true
				break
			end
		end
		if any then
			state.prefix = candidate
			render_status(window, pane)
		else
			cancel(window, pane) -- no viable label starts with this key
		end
	end

	local function backspace(window, pane)
		if not state.targets then
			return
		end
		state.prefix = state.prefix:sub(1, -2)
		render_status(window, pane)
	end

	-- Built once: one binding per (deduplicated) alphabet character, plus
	-- Escape/Backspace. No timeout, matching nvim-labels' own jump() — it
	-- waits indefinitely for a key, not on a clock.
	local kt = {
		{ key = "Escape", mods = "NONE", action = wezterm.action_callback(cancel) },
		{ key = "Backspace", mods = "NONE", action = wezterm.action_callback(backspace) },
	}
	local seen = {}
	for ch in keys:gmatch(".") do
		if not seen[ch] then
			seen[ch] = true
			table.insert(kt, {
				key = ch,
				mods = "NONE",
				action = wezterm.action_callback(function(window, pane)
					handle_key(window, pane, ch)
				end),
			})
		end
	end

	-- Everything else cancels back to normal rather than being left unbound
	-- (which would fall through the key-table stack). JUMP carries extra
	-- state — state.targets, the tab-title blank, the left-status legend —
	-- that only cancel()/commit() unwind, so a key falling all the way
	-- through would leave that stuck while leaking into the shell or
	-- triggering an unrelated normal_mode action.
	local cancel_action = wezterm.action_callback(cancel)
	local other_keys = {
		"a","b","c","d","e","f","g","h","i","j","k","l","m",
		"n","o","p","q","r","s","t","u","v","w","x","y","z",
		"A","B","C","D","E","F","G","H","I","J","K","L","M",
		"N","O","P","Q","R","S","T","U","V","W","X","Y","Z",
		"0","1","2","3","4","5","6","7","8","9",
		"`","~","!","@","#","$","%","^","&","*","(",")","_",
		"+","=","[","]","{","}","\\","|",";","'",":",'"',
		",",".","<",">","/","?","-"," ",
		"Tab","Enter","Delete","Home","End","PageUp","PageDown",
		"LeftArrow","RightArrow","UpArrow","DownArrow",
	}
	for _, ch in ipairs(other_keys) do
		if not seen[ch] then
			table.insert(kt, { key = ch, mods = "NONE", action = cancel_action })
		end
		table.insert(kt, { key = ch, mods = "SHIFT", action = cancel_action })
	end

	--- Compute this invocation's targets from the current input line and
	--- activate the (already-built) jump key table.
	--- Limitations:
	---  - No-ops without shell integration (no Input zone) or when the
	---    cursor isn't currently on the input line (e.g. mid-scrollback).
	---  - Assumes the pane's width doesn't change between reading the
	---    cursor position and reading the zone text (see linear_offset).
	--- @param window table  WezTerm Window object
	--- @param pane   table  WezTerm Pane object
	local function open_word_jump(window, pane)
		local zones = pane:get_semantic_zones("Input")
		if not zones or #zones == 0 then
			return
		end
		local zone = zones[#zones]

		local cursor = pane:get_cursor_position()
		if cursor.y < zone.start_y or cursor.y > zone.end_y then
			return -- cursor isn't on the input line right now
		end

		local text = pane:get_text_from_semantic_zone(zone):gsub("%s+$", "")
		local words = collect_words(text, jump_pattern)
		if #words == 0 then
			return
		end

		local pane_width = pane:get_dimensions().cols
		local cur_col = linear_offset(zone, cursor.y, cursor.x, pane_width)

		-- Assign labels nearest-cursor-first, like nvim-labels: shortest
		-- labels go to the closest words.
		local order_idx = {}
		for i = 1, #words do
			order_idx[i] = i
		end
		table.sort(order_idx, function(a, b)
			return math.abs(words[a].col - cur_col) < math.abs(words[b].col - cur_col)
		end)

		local labels = generate_labels(#words, keys)
		local label_by_idx = {}
		for rank, idx in ipairs(order_idx) do
			label_by_idx[idx] = labels[rank]
		end

		-- But build the legend in the words' own left-to-right order —
		-- proximity order here would read scrambled against the line.
		state.targets = {}
		state.order = {}
		state.prefix = ""
		state.cur_col = cur_col
		for idx, w in ipairs(words) do
			local label = label_by_idx[idx]
			state.targets[label] = w.col
			state.order[#state.order + 1] = { label = label, text = w.text }
		end

		-- No replace_current: stack JUMP on top of normal_mode (matching
		-- YANK/DELETE/COUNT) as a second line of defense under the
		-- cancel-catchall above.
		window:perform_action(
			wezterm.action.ActivateKeyTable({ name = ctx.JUMP, one_shot = false }),
			pane
		)
		render_status(window, pane)
	end

	return { key_table = kt, open_word_jump = open_word_jump }
end
