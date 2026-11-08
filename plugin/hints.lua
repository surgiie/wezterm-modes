local function character_count(text)
	local _, count = text:gsub("[^\128-\191]", "")
	return count
end

local UTF8 = "[%z\1-\127\194-\244][\128-\191]*"

local M = {}

--- Every token in the viewport's rows, top to bottom, left to right.
--- Columns and lengths count characters, not bytes; double-width characters
--- are not special-cased.
--- @param viewport_lines string[]  One entry per screen row, top row first
--- @param pattern        string?   Lua pattern for a token; default "%S+"
--- @return table[]  { row = 0-indexed, col = 0-indexed, length, text }
function M.collect_viewport_tokens(viewport_lines, pattern)
	pattern = pattern or "%S+"
	local tokens = {}
	for row_index, line in ipairs(viewport_lines) do
		local search_from = 1
		while true do
			local start_byte, end_byte = line:find(pattern, search_from)
			if not start_byte then
				break
			end
			local text = line:sub(start_byte, end_byte)
			tokens[#tokens + 1] = {
				row = row_index - 1,
				col = character_count(line:sub(1, start_byte - 1)),
				length = character_count(text),
				text = text,
			}
			search_from = end_byte + 1
		end
	end
	return tokens
end

--- Split the text WezTerm returns for the viewport into one string per row.
--- @param viewport_text string
--- @return string[]
function M.split_viewport_rows(viewport_text)
	local rows = {}
	for row in (viewport_text .. "\n"):gmatch("(.-)\n") do
		rows[#rows + 1] = (row:gsub("\r$", ""))
	end
	if rows[#rows] == "" then
		rows[#rows] = nil
	end
	return rows
end

--- Remove CSI and charset escape sequences from rows, keeping the text.
--- @param escaped_rows string[]
--- @return string[]
function M.strip_escapes(escaped_rows)
	local plain_rows = {}
	for index, row in ipairs(escaped_rows) do
		local without_csi = row:gsub("\27%[[%d;:?]*%a", "")
		plain_rows[index] = (without_csi:gsub("\27%(%a", ""))
	end
	return plain_rows
end

--- Pair tokens with labels, nearest to the anchor first so they get the
--- shortest labels. Distance is rows first, then columns.
--- @param tokens     table[]   From collect_viewport_tokens
--- @param labels     string[]  Shortest first; must hold at least #tokens entries
--- @param anchor_row number    0-indexed viewport row (the cursor)
--- @param anchor_col number    0-indexed column
--- @return string[]  label by token index
function M.assign_labels(tokens, labels, anchor_row, anchor_col)
	local order = {}
	for index = 1, #tokens do
		order[index] = index
	end
	table.sort(order, function(left, right)
		local left_token, right_token = tokens[left], tokens[right]
		local left_rows = math.abs(left_token.row - anchor_row)
		local right_rows = math.abs(right_token.row - anchor_row)
		if left_rows ~= right_rows then
			return left_rows < right_rows
		end
		local left_cols = math.abs(left_token.col - anchor_col)
		local right_cols = math.abs(right_token.col - anchor_col)
		if left_cols ~= right_cols then
			return left_cols < right_cols
		end
		return left < right
	end)
	local label_by_token = {}
	for rank, token_index in ipairs(order) do
		label_by_token[token_index] = labels[rank]
	end
	return label_by_token
end

--- One cell per label character, starting at the token's first column.
--- Cells past the last column are dropped.
--- @param tokens         table[]
--- @param label_by_token string[]
--- @param prefix         string?  Typed so far; only matching labels are drawn, minus the prefix
--- @param columns        number   Pane width
--- @return table[]  { row, column, label_character }
function M.label_cells(tokens, label_by_token, prefix, columns)
	prefix = prefix or ""
	local cells = {}
	for index, token in ipairs(tokens) do
		local label = label_by_token[index]
		if label and label:sub(1, #prefix) == prefix then
			local offset = 0
			for label_character in label:sub(#prefix + 1):gmatch(UTF8) do
				local column = token.col + offset
				if column < columns then
					cells[#cells + 1] = { row = token.row, column = column, label_character = label_character }
				end
				offset = offset + 1
			end
		end
	end
	return cells
end

--- CopyMode action names that walk the copy-mode cursor from the terminal
--- cursor to a token. Copy mode has no absolute move: rows first, then back
--- to column 0, then right.
--- @param cursor_row number  0-indexed screen row the copy-mode cursor starts on
--- @param token      table   { row, col }
--- @return string[]
function M.copy_mode_steps(cursor_row, token)
	local steps = {}
	local row_delta = token.row - cursor_row
	for _ = 1, math.abs(row_delta) do
		steps[#steps + 1] = row_delta < 0 and "MoveUp" or "MoveDown"
	end
	steps[#steps + 1] = "MoveToStartOfLine"
	for _ = 1, token.col do
		steps[#steps + 1] = "MoveRight"
	end
	return steps
end

local ESC = "\27"

local function move_to(row, column)
	return string.format("%s[%d;%dH", ESC, row + 1, column + 1)
end

--- Reverse-video label characters, cursor position preserved.
--- @param cells table[]  From label_cells
--- @return string
function M.paint_sequence(cells)
	local parts = { ESC .. "7" }
	for _, cell in ipairs(cells) do
		parts[#parts + 1] = move_to(cell.row, cell.column) .. ESC .. "[7m" .. cell.label_character .. ESC .. "[0m"
	end
	parts[#parts + 1] = ESC .. "8"
	return table.concat(parts)
end

--- Rewrite every row a label touched from its original escape-coded text, so
--- colours and attributes come back exactly.
--- @param cells        table[]   Painted cells
--- @param escaped_rows string[]  Original rows from pane:get_lines_as_escapes, 0-indexed row = index - 1
--- @return string
function M.restore_sequence(cells, escaped_rows)
	local touched, seen = {}, {}
	for _, cell in ipairs(cells) do
		if not seen[cell.row] then
			seen[cell.row] = true
			touched[#touched + 1] = cell.row
		end
	end
	table.sort(touched)
	local parts = { ESC .. "7" }
	for _, row in ipairs(touched) do
		local reset = ESC .. "[0m"
		parts[#parts + 1] = move_to(row, 0) .. reset .. (escaped_rows[row + 1] or "") .. reset .. ESC .. "[K"
	end
	parts[#parts + 1] = ESC .. "8"
	return table.concat(parts)
end

return M
