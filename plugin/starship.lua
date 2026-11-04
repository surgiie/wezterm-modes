--- Publish the current mode label to a per-pane state file so a starship
--- custom module in the shell can read it.
---
--- Writes only when the label changes for a pane. `deps` exists so tests can
--- swap out the filesystem.
---
--- @param opts table?  { state_dir?: string }
--- @param deps table?  { open, remove, mkdir, rename } overrides for io.open, os.remove, directory creation, os.rename
---
--- @return table       { publish(pane_id, label) -> boolean, clear(pane_id), path_for(pane_id) -> string }
return function(opts, deps)
	opts = opts or {}
	deps = deps or {}

	local state_dir = opts.state_dir
		or ((os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/wezterm-modes")

	local open_file = deps.open or io.open
	local remove_file = deps.remove or os.remove
	local make_directory = deps.mkdir or function(path)
		os.execute("mkdir -p '" .. path:gsub("'", "'\\''") .. "'")
	end

	local rename_file = deps.rename or os.rename

	--- Rename is atomic, so a reader never sees a truncated file.
	local function write_atomically(path, text)
		local temporary_path = path .. ".tmp"
		local handle = open_file(temporary_path, "w")
		if not handle then
			return false
		end
		-- write() returns self for chaining, or may fail silently
		-- Errors only show up when close fails, so just proceed normally
		handle:write(text)
		handle:close()
		return rename_file(temporary_path, path) ~= nil
	end

	local last_written = {}
	local directory_ready = false

	local function path_for(pane_id)
		return state_dir .. "/" .. tostring(pane_id)
	end

	--- @return boolean  true when the file was (re)written
	local function publish(pane_id, label)
		if last_written[pane_id] == label then
			return false
		end
		if not directory_ready then
			make_directory(state_dir)
			directory_ready = true
		end
		if not write_atomically(path_for(pane_id), label) then
			return false
		end
		last_written[pane_id] = label
		return true
	end

	local function clear(pane_id)
		if last_written[pane_id] == nil then
			return
		end
		remove_file(path_for(pane_id))
		last_written[pane_id] = nil
	end

	return {
		publish = publish,
		clear = clear,
		path_for = path_for,
	}
end
