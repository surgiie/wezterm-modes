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
-- Unlike nvim-labels (which sub-splits camelCase/snake_case identifiers for
-- precise cursor placement inside a buffer), a shell line's atoms are its
-- whole space-separated tokens — flags, paths, resource names — not the
-- pieces within one. "pod-edge-admin-0" or "-it" are each one target you'd
-- want to jump straight to, not four/two choices to pick between. So each
-- non-blank run is exactly one target here, full stop.

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
-- That callback logic (accumulate a prefix, exact match wins, no viable
-- candidates cancels) is the same algorithm as nvim-labels' input.lua, just
-- driven by WezTerm key-table activation instead of a getcharstr() loop.
--
-- There's still no hook to draw labels inline over the text itself (see the
-- doc comment below `generate_labels` for why — the same reasoning that
-- ruled out QuickSelect applies here too), so the label:word legend is
-- rendered into the right-status bar for the duration of the pick instead.
--
-- @param ctx table  Plugin context (jump_keys, jump_pattern, JUMP, enter_normal)
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

	local function clear_status(window)
		window:set_right_status("")
	end

	local function render_status(window)
		local parts = {}
		for _, entry in ipairs(state.order) do
			if entry.label:sub(1, #state.prefix) == state.prefix then
				parts[#parts + 1] = entry.label .. ":" .. entry.text
			end
		end
		window:set_right_status(" JUMP  " .. table.concat(parts, "  ") .. " ")
	end

	local function cancel(window, pane)
		state.targets = nil
		clear_status(window)
		window:perform_action(enter_normal, pane)
	end

	local function commit(window, pane, col)
		local delta = col - state.cur_col
		state.targets = nil
		clear_status(window)
		local actions = {}
		local key = delta > 0 and "RightArrow" or "LeftArrow"
		for _ = 1, math.abs(delta) do
			actions[#actions + 1] = wezterm.action.SendKey({ key = key })
		end
		actions[#actions + 1] = enter_normal
		window:perform_action(wezterm.action.Multiple(actions), pane)
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
			render_status(window)
		else
			cancel(window, pane) -- no viable label starts with this key
		end
	end

	local function backspace(window, pane)
		if not state.targets then
			return
		end
		state.prefix = state.prefix:sub(1, -2)
		render_status(window)
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

	--- Compute this invocation's targets from the current input line and
	--- activate the (already-built) jump key table.
	--- Limitations:
	---  - No-ops without shell integration (no Input zone) or when the
	---    cursor isn't currently on the input line (e.g. mid-scrollback).
	---  - Assumes the input line fits on one row. A command long enough to
	---    wrap would throw off the column math, since wrapped rows don't
	---    continue accumulating column position the way this assumes.
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

		local cur_col = cursor.x - zone.start_x

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

		-- But build the legend in the words' own left-to-right order (`words`
		-- is already in that order, straight from collect_words) — matching
		-- proximity order here would read scrambled against the actual line.
		state.targets = {}
		state.order = {}
		state.prefix = ""
		state.cur_col = cur_col
		for idx, w in ipairs(words) do
			local label = label_by_idx[idx]
			state.targets[label] = w.col
			state.order[#state.order + 1] = { label = label, text = w.text }
		end

		window:perform_action(
			wezterm.action.ActivateKeyTable({ name = ctx.JUMP, one_shot = false, replace_current = true }),
			pane
		)
		render_status(window)
	end

	return { key_table = kt, open_word_jump = open_word_jump }
end
