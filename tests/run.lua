-- Run from the repo root: lua tests/run.lua

local failures = 0
local total = 0

local function test(name, fn)
	total = total + 1
	local ok, err = pcall(fn)
	if not ok then
		failures = failures + 1
		print("FAIL  " .. name .. "\n      " .. tostring(err))
	else
		print("ok    " .. name)
	end
end

local function assert_equal(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
	end
end

local KEY_TABLES = {
	NORMAL  = "normal_mode",
	YANK    = "yank_mode",
	DELETE  = "delete_mode",
	MOTION  = "motion_mode",
	REPLACE = "replace_mode",
	KEYMAP  = "keymap_mode",
	COUNT   = "count_mode",
	JUMP    = "jump_mode",
}

-- ── mode_label ────────────────────────────────────────────────────────────────

local resolve_label = dofile("plugin/mode_label.lua")(KEY_TABLES)

test("mode_label: no key table is INSERT", function()
	assert_equal(resolve_label(nil, false), "INSERT")
end)

test("mode_label: leader wins over any key table", function()
	assert_equal(resolve_label("normal_mode", true), "LEADER")
	assert_equal(resolve_label(nil, true), "LEADER")
end)

test("mode_label: normal and its sub-modes are NORMAL", function()
	for _, key_table in ipairs({ "normal_mode", "yank_mode", "delete_mode", "count_mode", "motion_mode", "replace_mode" }) do
		assert_equal(resolve_label(key_table, false), "NORMAL", key_table)
	end
end)

test("mode_label: copy_mode is VISUAL", function()
	assert_equal(resolve_label("copy_mode", false), "VISUAL")
end)

test("mode_label: search_mode is VISUAL", function()
	assert_equal(resolve_label("search_mode", false), "VISUAL")
end)

test("mode_label: jump_mode is JUMP", function()
	assert_equal(resolve_label("jump_mode", false), "JUMP")
end)

test("mode_label: keymap tables, including nested group tables, are KEYMAP", function()
	assert_equal(resolve_label("keymap_mode", false), "KEYMAP")
	assert_equal(resolve_label("keymap_mode_g", false), "KEYMAP")
end)

test("mode_label: unknown key table falls back to INSERT", function()
	assert_equal(resolve_label("something_else", false), "INSERT")
end)

test("mode_label: tolerates keymap mode being disabled", function()
	local without_keymap = dofile("plugin/mode_label.lua")({
		NORMAL = "normal_mode", YANK = "yank_mode", DELETE = "delete_mode", MOTION = "motion_mode",
		REPLACE = "replace_mode", COUNT = "count_mode", JUMP = "jump_mode",
	})
	assert_equal(without_keymap("keymap_mode", false), "INSERT")
end)

-- ── starship state publisher ──────────────────────────────────────────────────

local function fake_filesystem()
	local files = {}
	local made_directories = {}
	return {
		files = files,
		made_directories = made_directories,
		deps = {
			open = function(path)
				if path:find("unwritable", 1, true) then
					return nil
				end
				local buffer = {}
				return {
					write = function(_, text) buffer[#buffer + 1] = text end,
					close = function() files[path] = table.concat(buffer) end,
				}
			end,
			remove = function(path) files[path] = nil end,
			rename = function(from, to)
				files[to] = files[from]
				files[from] = nil
				return true
			end,
			mkdir = function(path) made_directories[#made_directories + 1] = path end,
		},
	}
end

test("starship: publish writes the label to the pane file", function()
	local filesystem = fake_filesystem()
	local publisher = dofile("plugin/starship.lua")({ state_dir = "/state" }, filesystem.deps)
	assert_equal(publisher.publish(7, "NORMAL"), true)
	assert_equal(filesystem.files["/state/7"], "NORMAL")
end)

test("starship: writes go through a temp file that is renamed into place", function()
	local filesystem = fake_filesystem()
	local renames = {}
	local original_rename = filesystem.deps.rename
	filesystem.deps.rename = function(from, to)
		renames[#renames + 1] = { from = from, to = to }
		return original_rename(from, to)
	end
	local publisher = dofile("plugin/starship.lua")({ state_dir = "/state" }, filesystem.deps)
	publisher.publish(7, "NORMAL")
	assert_equal(#renames, 1)
	assert_equal(renames[1].from, "/state/7.tmp")
	assert_equal(renames[1].to, "/state/7")
	assert_equal(filesystem.files["/state/7.tmp"], nil)
end)

test("starship: a failed rename reports failure and retries next time", function()
	local filesystem = fake_filesystem()
	local original_rename = filesystem.deps.rename
	local rename_works = false
	filesystem.deps.rename = function(from, to)
		if not rename_works then return nil end
		return original_rename(from, to)
	end
	local publisher = dofile("plugin/starship.lua")({ state_dir = "/state" }, filesystem.deps)
	assert_equal(publisher.publish(7, "NORMAL"), false)
	rename_works = true
	assert_equal(publisher.publish(7, "NORMAL"), true)
	assert_equal(filesystem.files["/state/7"], "NORMAL")
end)

test("starship: unchanged label does not rewrite", function()
	local filesystem = fake_filesystem()
	local publisher = dofile("plugin/starship.lua")({ state_dir = "/state" }, filesystem.deps)
	publisher.publish(7, "NORMAL")
	assert_equal(publisher.publish(7, "NORMAL"), false)
	assert_equal(publisher.publish(7, "INSERT"), true)
	assert_equal(filesystem.files["/state/7"], "INSERT")
end)

test("starship: panes are tracked independently", function()
	local filesystem = fake_filesystem()
	local publisher = dofile("plugin/starship.lua")({ state_dir = "/state" }, filesystem.deps)
	publisher.publish(1, "NORMAL")
	publisher.publish(2, "INSERT")
	assert_equal(filesystem.files["/state/1"], "NORMAL")
	assert_equal(filesystem.files["/state/2"], "INSERT")
end)

test("starship: directory is created once", function()
	local filesystem = fake_filesystem()
	local publisher = dofile("plugin/starship.lua")({ state_dir = "/state" }, filesystem.deps)
	publisher.publish(1, "NORMAL")
	publisher.publish(2, "NORMAL")
	assert_equal(#filesystem.made_directories, 1)
	assert_equal(filesystem.made_directories[1], "/state")
end)

test("starship: clear removes the file and allows a later identical publish", function()
	local filesystem = fake_filesystem()
	local publisher = dofile("plugin/starship.lua")({ state_dir = "/state" }, filesystem.deps)
	publisher.publish(7, "NORMAL")
	publisher.clear(7)
	assert_equal(filesystem.files["/state/7"], nil)
	assert_equal(publisher.publish(7, "NORMAL"), true)
end)

test("starship: clear on an unknown pane is a no-op", function()
	local filesystem = fake_filesystem()
	local publisher = dofile("plugin/starship.lua")({ state_dir = "/state" }, filesystem.deps)
	publisher.clear(99)
	assert_equal(next(filesystem.files), nil)
end)

test("starship: unwritable file reports failure and retries next time", function()
	local filesystem = fake_filesystem()
	local publisher = dofile("plugin/starship.lua")({ state_dir = "/unwritable" }, filesystem.deps)
	assert_equal(publisher.publish(7, "NORMAL"), false)
	assert_equal(publisher.publish(7, "NORMAL"), false)
end)

test("starship: default directory honours XDG_RUNTIME_DIR shape", function()
	local publisher = dofile("plugin/starship.lua")({}, fake_filesystem().deps)
	local expected_root = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/wezterm-modes/"
	assert_equal(publisher.path_for(3), expected_root .. "3")
end)

-- ── status.lua wiring (stubbed wezterm) ───────────────────────────────────────

local signals_sent = {}

local function load_status(extra_ctx)
	local handlers = {}
	signals_sent = {}
	package.loaded["wezterm"] = {
		on = function(event, handler) handlers[event] = handler end,
		format = function(items)
			local text = {}
			for _, item in ipairs(items) do
				if type(item) == "table" and item.Text then text[#text + 1] = item.Text end
			end
			return table.concat(text)
		end,
		action = { PopKeyTable = "pop" },
		background_child_process = function(argv) signals_sent[#signals_sent + 1] = argv end,
	}

	local filesystem = fake_filesystem()
	local real_starship_loader = dofile
	local ctx = {
		NORMAL = KEY_TABLES.NORMAL, YANK = KEY_TABLES.YANK, DELETE = KEY_TABLES.DELETE,
		MOTION = KEY_TABLES.MOTION, REPLACE = KEY_TABLES.REPLACE,
		KEYMAP = KEY_TABLES.KEYMAP, COUNT = KEY_TABLES.COUNT, JUMP = KEY_TABLES.JUMP,
		should_run = function() return true end,
		load = function(path)
			if path == "starship.lua" then
				local factory = real_starship_loader("plugin/starship.lua")
				return function(opts) return factory(opts, filesystem.deps) end
			end
			return real_starship_loader("plugin/" .. path)
		end,
	}
	for key, value in pairs(extra_ctx or {}) do ctx[key] = value end

	dofile("plugin/status.lua")(ctx)
	return handlers["update-status"], filesystem, ctx
end

local function fake_window(key_table, leader_active)
	local window = { left_status = nil }
	function window:active_key_table() return key_table end
	function window:leader_is_active() return leader_active or false end
	function window:set_left_status(text) self.left_status = text end
	function window:perform_action() end
	return window
end

local function fake_pane(pane_id)
	return {
		pane_id = function() return pane_id end,
		get_user_vars = function() return { wezterm_modes_prompt = "1" } end,
		get_foreground_process_info = function() return { pid = 4242, name = "zsh", executable = "/usr/bin/zsh" } end,
	}
end

test("status: without starship opts, nothing is written and the badge shows", function()
	local handler, filesystem = load_status()
	local window = fake_window("normal_mode")
	handler(window, fake_pane(5))
	assert_equal(next(filesystem.files), nil)
	assert_equal(window.left_status, " NORMAL ")
end)

test("status: with starship opts, the label is published and the badge still shows", function()
	local handler, filesystem = load_status({ starship = { state_dir = "/state" } })
	local window = fake_window("normal_mode")
	handler(window, fake_pane(5))
	assert_equal(filesystem.files["/state/5"], "NORMAL")
	assert_equal(window.left_status, " NORMAL ")
end)

test("status: badge = false publishes but leaves only the prefix in the left status", function()
	local handler, filesystem = load_status({
		starship = { state_dir = "/state", badge = false },
		left_status_prefix = function() return "[p]" end,
	})
	local window = fake_window(nil)
	handler(window, fake_pane(5))
	assert_equal(filesystem.files["/state/5"], "INSERT")
	assert_equal(window.left_status, "[p]")
end)

test("status: badge = false keeps the badge in a non-shell pane", function()
	local handler = load_status({
		starship = { state_dir = "/state", badge = false },
		pane_is_shell = function() return false end,
	})
	local window = fake_window("normal_mode")
	handler(window, fake_pane(5))
	assert_equal(window.left_status, " NORMAL ")
end)

test("status: mode change republishes", function()
	local handler, filesystem = load_status({ starship = { state_dir = "/state" } })
	handler(fake_window(nil), fake_pane(5))
	assert_equal(filesystem.files["/state/5"], "INSERT")
	handler(fake_window("normal_mode"), fake_pane(5))
	assert_equal(filesystem.files["/state/5"], "NORMAL")
	handler(fake_window("normal_mode", true), fake_pane(5))
	assert_equal(filesystem.files["/state/5"], "LEADER")
end)

test("status: inactive pane clears its state file", function()
	local active = true
	local handler, filesystem = load_status({
		starship = { state_dir = "/state" },
		should_run = function() return active end,
	})
	handler(fake_window("normal_mode"), fake_pane(5))
	assert_equal(filesystem.files["/state/5"], "NORMAL")
	active = false
	handler(fake_window(nil), fake_pane(5))
	assert_equal(filesystem.files["/state/5"], nil)
end)

test("status: jump pick in progress publishes JUMP and leaves the left status alone", function()
	local handler, filesystem = load_status({
		starship = { state_dir = "/state" },
		jump_state = { targets = { "x" } },
	})
	local window = fake_window("jump_mode")
	handler(window, fake_pane(5))
	assert_equal(filesystem.files["/state/5"], "JUMP")
	assert_equal(window.left_status, nil)
end)

test("redraw: signal is sent once per mode change, not on unchanged ticks", function()
	local handler = load_status({ starship = { state_dir = "/state" } })
	local window = fake_window("normal_mode")
	handler(window, fake_pane(5))
	handler(window, fake_pane(5))
	assert_equal(#signals_sent, 1)
	assert_equal(signals_sent[1][1], "kill")
	assert_equal(signals_sent[1][2], "-USR1")
	assert_equal(signals_sent[1][3], "4242")
	local next_window = fake_window(nil)
	handler(next_window, fake_pane(5))
	assert_equal(#signals_sent, 2)
end)

test("redraw: entering a jump pick sends no signal, leaving it does", function()
	local jump_state = { targets = nil }
	local handler = load_status({ starship = { state_dir = "/state" }, jump_state = jump_state })
	handler(fake_window("normal_mode"), fake_pane(5))
	assert_equal(#signals_sent, 1)

	jump_state.targets = { f = 0 }
	handler(fake_window("jump_mode"), fake_pane(5))
	handler(fake_window("jump_mode"), fake_pane(5))
	assert_equal(#signals_sent, 1)

	jump_state.targets = nil
	handler(fake_window("normal_mode"), fake_pane(5))
	assert_equal(#signals_sent, 2)
end)

test("redraw: entering copy mode signals the shell once and types nothing into the pane", function()
	local handler = load_status({ starship = { state_dir = "/state" } })
	handler(fake_window("normal_mode"), fake_pane(5))
	local before = #signals_sent
	local window = fake_window("copy_mode")
	handler(window, fake_pane(5))
	assert_equal(#signals_sent, before + 1)
	handler(fake_window("search_mode"), fake_pane(5))
	assert_equal(#signals_sent, before + 1, "search_mode is the same VISUAL label")
end)

test("badge: badge = false keeps the badge visible in copy mode", function()
	local handler = load_status({ starship = { state_dir = "/state", badge = false } })
	local window = fake_window("copy_mode")
	handler(window, fake_pane(5))
	assert_equal(window.left_status, " VISUAL ")
end)

test("redraw: only a zsh foreground process is signalled", function()
	for _, executable in ipairs({ "/usr/bin/bash", "/usr/bin/fzf", "/usr/bin/nvim" }) do
		local handler = load_status({ starship = { state_dir = "/state" } })
		local pane = fake_pane(5)
		pane.get_foreground_process_info = function() return { pid = 99, name = executable, executable = executable } end
		handler(fake_window("normal_mode"), pane)
		assert_equal(#signals_sent, 0, executable)
	end
end)

test("redraw: no signal when the process info is unavailable", function()
	local handler = load_status({ starship = { state_dir = "/state" } })
	local pane = fake_pane(5)
	pane.get_foreground_process_info = function() return nil end
	handler(fake_window("normal_mode"), pane)
	assert_equal(#signals_sent, 0)
end)

test("redraw: a signal that could not be sent is retried on a later tick", function()
	local handler = load_status({ starship = { state_dir = "/state" } })
	local pane = fake_pane(5)
	local real_info = pane.get_foreground_process_info
	pane.get_foreground_process_info = function() return nil end
	handler(fake_window("normal_mode"), pane)
	assert_equal(#signals_sent, 0)
	pane.get_foreground_process_info = real_info
	handler(fake_window("normal_mode"), pane)
	assert_equal(#signals_sent, 1)
end)

test("redraw: redraw = false sends nothing but still publishes", function()
	local handler, filesystem = load_status({ starship = { state_dir = "/state", redraw = false } })
	local window = fake_window("normal_mode")
	handler(window, fake_pane(5))
	assert_equal(#signals_sent, 0)
	assert_equal(filesystem.files["/state/5"], "NORMAL")
end)

test("redraw: nothing is sent to an inactive pane", function()
	local handler = load_status({
		starship = { state_dir = "/state" },
		should_run = function() return false end,
	})
	local window = fake_window(nil)
	handler(window, fake_pane(5))
	assert_equal(#signals_sent, 0)
end)

test("redraw: not sent to a non-shell pane even when should_run allows it", function()
	local handler, filesystem = load_status({
		starship = { state_dir = "/state" },
		pane_is_shell = function() return false end,
	})
	local window = fake_window("normal_mode")
	handler(window, fake_pane(5))
	assert_equal(#signals_sent, 0)
	assert_equal(filesystem.files["/state/5"], "NORMAL")
end)

test("redraw: sent when pane_is_shell confirms a shell", function()
	local handler = load_status({
		starship = { state_dir = "/state" },
		pane_is_shell = function() return true end,
	})
	local window = fake_window("normal_mode")
	handler(window, fake_pane(5))
	assert_equal(#signals_sent, 1)
end)

local function pane_with_prompt_var(pane_id, prompt_flag)
	local user_vars = {}
	user_vars.wezterm_modes_prompt = prompt_flag
	return {
		pane_id = function() return pane_id end,
		get_user_vars = function() return user_vars end,
		user_vars = user_vars,
		get_foreground_process_info = function() return { pid = 4242, name = "zsh", executable = "/usr/bin/zsh" } end,
	}
end

test("redraw: sent when the shell reports it is at its prompt", function()
	local handler = load_status({ starship = { state_dir = "/state" } })
	local window = fake_window("normal_mode")
	handler(window, pane_with_prompt_var(5, "1"))
	assert_equal(#signals_sent, 1)
end)

test("redraw: unset prompt var holds the redraw and keeps the badge until the shell reports", function()
	local handler = load_status({ starship = { state_dir = "/state", badge = false } })
	local pane = pane_with_prompt_var(5, nil)
	local early_window = fake_window("normal_mode")
	handler(early_window, pane)
	assert_equal(#signals_sent, 0)
	assert_equal(early_window.left_status, " NORMAL ")
	pane.user_vars.wezterm_modes_prompt = "1"
	local ready_window = fake_window("normal_mode")
	handler(ready_window, pane)
	assert_equal(#signals_sent, 1)
	assert_equal(ready_window.left_status, "")
end)

test("redraw: pane without user var support never redraws", function()
	local handler = load_status({ starship = { state_dir = "/state" } })
	local window = fake_window("normal_mode")
	handler(window, { pane_id = function() return 5 end })
	assert_equal(#signals_sent, 0)
end)

test("redraw: not sent while a command runs, but the label is still published", function()
	local handler, filesystem = load_status({ starship = { state_dir = "/state" } })
	local window = fake_window("normal_mode")
	handler(window, pane_with_prompt_var(5, "0"))
	assert_equal(#signals_sent, 0)
	assert_equal(filesystem.files["/state/5"], "NORMAL")
end)

test("redraw: a dropped redraw is delivered once the prompt returns", function()
	local handler = load_status({ starship = { state_dir = "/state" } })
	local pane = pane_with_prompt_var(5, "0")
	local running_window = fake_window("normal_mode")
	handler(running_window, pane)
	handler(running_window, pane)
	assert_equal(#signals_sent, 0)
	pane.user_vars.wezterm_modes_prompt = "1"
	local prompt_window = fake_window("normal_mode")
	handler(prompt_window, pane)
	assert_equal(#signals_sent, 1)
	handler(prompt_window, pane)
	assert_equal(#signals_sent, 1)
end)

test("redraw: pending redraw is dropped when the pane goes inactive", function()
	local active = true
	local handler = load_status({
		starship = { state_dir = "/state" },
		should_run = function() return active end,
	})
	local pane = pane_with_prompt_var(5, "0")
	handler(fake_window("normal_mode"), pane)
	active = false
	handler(fake_window(nil), pane)
	active = true
	pane.user_vars.wezterm_modes_prompt = "1"
	local window = fake_window("normal_mode")
	handler(window, pane)
	assert_equal(#signals_sent, 1)
end)

test("redraw: held while a just-sent command has not been read by the shell", function()
	local now = 100
	local handler, _, ctx = load_status({ starship = { state_dir = "/state" }, clock = function() return now end })
	local pane = pane_with_prompt_var(5, "1")
	ctx.mark_command_sent(pane)
	local window = fake_window("normal_mode")
	handler(window, pane)
	assert_equal(#signals_sent, 0)
end)

test("redraw: delivered once the command has run and the prompt returns", function()
	local now = 100
	local handler, _, ctx = load_status({ starship = { state_dir = "/state" }, clock = function() return now end })
	local pane = pane_with_prompt_var(5, "1")
	ctx.mark_command_sent(pane)
	local window = fake_window("normal_mode")
	handler(window, pane)
	pane.user_vars.wezterm_modes_prompt = "0"
	handler(window, pane)
	assert_equal(#signals_sent, 0)
	pane.user_vars.wezterm_modes_prompt = "1"
	handler(window, pane)
	assert_equal(#signals_sent, 1)
end)

test("redraw: a command that finished between ticks settles after the timeout", function()
	local now = 100
	local handler, _, ctx = load_status({ starship = { state_dir = "/state" }, clock = function() return now end })
	local pane = pane_with_prompt_var(5, "1")
	ctx.mark_command_sent(pane)
	local window = fake_window("normal_mode")
	handler(window, pane)
	now = 101
	handler(window, pane)
	assert_equal(#signals_sent, 0)
	now = 102
	handler(window, pane)
	assert_equal(#signals_sent, 1)
end)

test("redraw: in-flight marker is dropped when the pane goes inactive", function()
	local active = true
	local now = 100
	local handler, _, ctx = load_status({
		starship = { state_dir = "/state" },
		should_run = function() return active end,
		clock = function() return now end,
	})
	local pane = pane_with_prompt_var(5, "1")
	ctx.mark_command_sent(pane)
	active = false
	handler(fake_window(nil), pane)
	active = true
	local window = fake_window("normal_mode")
	handler(window, pane)
	assert_equal(#signals_sent, 1)
end)

test("redraw: prompt var cannot override a non-shell process", function()
	local handler = load_status({
		starship = { state_dir = "/state" },
		pane_is_shell = function() return false end,
	})
	local window = fake_window("normal_mode")
	handler(window, pane_with_prompt_var(5, "1"))
	assert_equal(#signals_sent, 0)
end)

test("badge: badge = false shows the badge while a command runs", function()
	local handler = load_status({ starship = { state_dir = "/state", badge = false } })
	local window = fake_window("normal_mode")
	handler(window, pane_with_prompt_var(5, "0"))
	assert_equal(window.left_status, " NORMAL ")
end)

test("badge: badge = false hides the badge at the prompt", function()
	local handler = load_status({ starship = { state_dir = "/state", badge = false } })
	local window = fake_window("normal_mode")
	handler(window, pane_with_prompt_var(5, "1"))
	assert_equal(window.left_status, "")
end)

test("redraw: nothing is sent when starship is not configured", function()
	local handler = load_status()
	local window = fake_window("normal_mode")
	handler(window, fake_pane(5))
	assert_equal(#signals_sent, 0)
end)

local function load_jump()
	package.loaded["wezterm"] = {
		on = function() end,
		action_callback = function(callback) return { callback = callback } end,
		action = setmetatable({}, { __index = function() return function(arg) return arg end end }),
		time = { call_after = function() end },
		log_info = function() end,
	}
	local ctx = {
		JUMP = "jump_mode",
		enter_normal = "enter_normal",
		render_jump_status = function() return " JUMP " end,
	}
	return dofile("plugin/jump.lua")(ctx), ctx
end

local function jump_pane(pane_id)
	local zone = { start_x = 0, start_y = 0, end_y = 0 }
	return {
		pane_id = function() return pane_id end,
		get_semantic_zones = function() return { zone } end,
		get_cursor_position = function() return { x = 0, y = 0 } end,
		get_text_from_semantic_zone = function() return "kubectl exec" end,
		get_dimensions = function() return { cols = 80 } end,
		injected = {},
		inject_output = function(self, sequence) self.injected[#self.injected + 1] = sequence end,
	}
end

local function key_callback(jump, key)
	for _, binding in ipairs(jump.key_table) do
		if binding.key == key and binding.mods == "NONE" then return binding.action.callback end
	end
end

test("jump: collect_words counts characters, not bytes", function()
	local jump = load_jump()
	local words = jump.collect_words("echo caf\195\169 \226\149\176\226\148\128\226\158\164 end")
	assert_equal(#words, 4)
	assert_equal(words[2].col, 5)
	assert_equal(words[2].length, 4)
	assert_equal(words[3].col, 10)
	assert_equal(words[3].length, 3)
	assert_equal(words[4].col, 14)
end)

test("jump: collect_words honours a custom pattern and ignores blank lines", function()
	local jump = load_jump()
	local words = jump.collect_words("a-b c_d", "[%w_]+")
	assert_equal(#words, 3)
	assert_equal(words[3].text, "c_d")
	assert_equal(#jump.collect_words("   "), 0)
end)

test("jump: screen_cell maps an offset on the zone's first row", function()
	local jump = load_jump()
	local row, column = jump.screen_cell({ start_x = 2, start_y = 4 }, 10, 80)
	assert_equal(row, 4)
	assert_equal(column, 12)
end)

test("jump: screen_cell wraps onto later rows", function()
	local jump = load_jump()
	local zone = { start_x = 5, start_y = 3 }
	local row, column = jump.screen_cell(zone, 75, 80)
	assert_equal(row, 4)
	assert_equal(column, 0)
	row, column = jump.screen_cell(zone, 160, 80)
	assert_equal(row, 5)
	assert_equal(column, 5)
end)

test("jump: opening paints a reverse-video label over each word", function()
	local jump = load_jump()
	local pane = jump_pane(1)
	jump.open_word_jump(fake_window("normal_mode"), pane)
	assert_equal(#pane.injected, 1)
	assert_equal(
		pane.injected[1],
		"\0277\27[1;1H\27[7mf\27[0m\27[1;9H\27[7mj\27[0m\0278"
	)
end)

test("jump: label_cells keeps the characters a label covers", function()
	local jump = load_jump()
	local words = jump.collect_words("ab cd", "%S+")
	local characters = { "a", "b", " ", "c", "d" }
	local zone = { start_x = 0, start_y = 2, end_y = 2 }
	local cells = jump.label_cells(words, { "fj", "k" }, characters, zone, 80)
	assert_equal(#cells, 3)
	assert_equal(cells[1].original, "a")
	assert_equal(cells[2].original, "b")
	assert_equal(cells[2].column, 1)
	assert_equal(cells[3].original, "c")
	assert_equal(cells[3].row, 2)
	assert_equal(jump.restore_sequence(cells), "\0277\27[3;1Ha\27[3;2Hb\27[3;4Hc\0278")
end)

test("jump: label_cells draws only labels matching the typed prefix, minus the prefix", function()
	local jump = load_jump()
	local words = jump.collect_words("ab cd ef", "%S+")
	local characters = { "a", "b", " ", "c", "d", " ", "e", "f" }
	local zone = { start_x = 0, start_y = 0, end_y = 0 }
	local cells = jump.label_cells(words, { "k", "fj", "fd" }, characters, zone, 80, "f")
	assert_equal(#cells, 2)
	assert_equal(cells[1].label_character, "j")
	assert_equal(cells[1].column, 3)
	assert_equal(cells[2].label_character, "d")
	assert_equal(cells[2].column, 6)
end)

test("jump: typing a prefix restores the old labels and draws the narrowed set", function()
	local jump, ctx = load_jump()
	local words = {}
	for index = 1, 21 do
		words[index] = string.char(96 + index)
	end
	local pane = jump_pane(1)
	pane.get_text_from_semantic_zone = function() return table.concat(words, " ") end
	local window = fake_window("normal_mode")
	jump.open_word_jump(window, pane)
	local long_label
	for label in pairs(ctx.jump_state.targets) do
		if #label == 2 then long_label = label end
	end
	assert_equal(long_label ~= nil, true)

	key_callback(jump, long_label:sub(1, 1))(window, pane)
	assert_equal(#pane.injected, 3)
	assert_equal(pane.injected[2]:find("\27[7m", 1, true), nil)
	local _, drawn = pane.injected[3]:gsub("\27%[7m", "")
	local expected = 0
	for label in pairs(ctx.jump_state.targets) do
		if label:sub(1, 1) == long_label:sub(1, 1) and #label > 1 then expected = expected + 1 end
	end
	assert_equal(drawn, expected)

	key_callback(jump, "Backspace")(window, pane)
	assert_equal(#pane.injected, 5)
end)

test("jump: cancelling restores the covered characters", function()
	local jump = load_jump()
	local pane = jump_pane(1)
	local window = fake_window("normal_mode")
	jump.open_word_jump(window, pane)
	key_callback(jump, "Escape")(window, pane)
	assert_equal(pane.injected[2], "\0277\27[1;1Hk\27[1;9He\0278")
end)

test("jump: a pane without inject_output still opens", function()
	local jump = load_jump()
	local pane = jump_pane(1)
	pane.inject_output = nil
	local window = fake_window("normal_mode")
	jump.open_word_jump(window, pane)
	assert_equal(window.left_status, " JUMP ")
end)

test("jump: the status bar shows the badge only, with no label legend", function()
	local jump = load_jump()
	local window = fake_window("normal_mode")
	jump.open_word_jump(window, jump_pane(1))
	assert_equal(window.left_status, " JUMP ")
end)

test("jump: nothing is written to prompt state while a pick starts, cancels or commits", function()
	local jump, ctx = load_jump()
	ctx.publish_legend = function() error("legend must not reach the prompt") end
	ctx.clear_legend = function() error("legend must not reach the prompt") end
	local window = fake_window("normal_mode")
	jump.open_word_jump(window, jump_pane(1))
	key_callback(jump, "Escape")(window, jump_pane(2))
	jump.open_word_jump(window, jump_pane(1))
	key_callback(jump, next(ctx.jump_state.targets))(window, jump_pane(2))
end)

-- ── randomized tick sequences ────────────────────────────────────────────────
-- Random mode changes, leader toggles, jump picks, command launches and
-- active/inactive flips across several panes. Invariants checked after a
-- final settle: the state file matches the real mode, the last signal to a
-- pane came after the last write, and no signal ever hit a pane that was not
-- at its prompt.

local FUZZ_PANE_IDS = { 1, 2, 3 }
local FUZZ_KEY_TABLES = { false, "normal_mode", "yank_mode", "count_mode", "keymap_mode", "copy_mode", "search_mode" }
local FUZZ_SEEDS = 300
local FUZZ_STEPS = 80

local function run_fuzz_sequence(seed)
	math.randomseed(seed)
	local now = 0
	local handler, filesystem, ctx = load_status({
		starship = { state_dir = "/state" },
		clock = function() return now end,
		should_run = function(pane) return pane.active end,
	})

	local panes = {}
	local windows = {}
	local pane_by_pid = {}
	for _, pane_id in ipairs(FUZZ_PANE_IDS) do
		local pane = {
			active = true,
			prompt_value = "1",
			pid = 1000 + pane_id,
		}
		function pane:pane_id() return pane_id end
		function pane:get_user_vars() return { wezterm_modes_prompt = self.prompt_value } end
		function pane:get_foreground_process_info()
			return { pid = self.pid, name = "zsh", executable = "/usr/bin/zsh" }
		end
		panes[pane_id] = pane
		pane_by_pid[tostring(pane.pid)] = pane

		local window = { key_table = nil, leader = false }
		function window:active_key_table() return self.key_table or nil end
		function window:leader_is_active() return self.leader end
		function window:set_left_status() end
		function window:perform_action() self.key_table = nil end
		windows[pane_id] = window
	end

	local last_signal_snapshot = {}
	local violations = {}
	local wezterm_stub = package.loaded["wezterm"]
	wezterm_stub.background_child_process = function(argv)
		local pane = pane_by_pid[argv[3]]
		if argv[1] ~= "kill" or argv[2] ~= "-USR1" or not pane then
			violations[#violations + 1] = "signal sent to an unknown target"
			return
		end
		if pane.prompt_value ~= "1" then
			violations[#violations + 1] = "signal sent to pane " .. pane:pane_id() .. " while not at its prompt"
		end
		last_signal_snapshot[pane:pane_id()] = filesystem.files["/state/" .. pane:pane_id()]
	end

	local log = {}
	for _ = 1, FUZZ_STEPS do
		local pane_id = FUZZ_PANE_IDS[math.random(#FUZZ_PANE_IDS)]
		local pane = panes[pane_id]
		local window = windows[pane_id]
		local roll = math.random(10)
		if roll == 1 then
			window.key_table = FUZZ_KEY_TABLES[math.random(#FUZZ_KEY_TABLES)] or nil
			log[#log + 1] = pane_id .. ":key_table=" .. tostring(window.key_table)
		elseif roll == 2 then
			window.leader = not window.leader
			log[#log + 1] = pane_id .. ":leader=" .. tostring(window.leader)
		elseif roll == 3 then
			ctx.jump_state = ctx.jump_state and nil or { targets = {} }
			log[#log + 1] = "jump=" .. tostring(ctx.jump_state ~= nil)
		elseif roll == 4 then
			pane.prompt_value = pane.prompt_value == "1" and "0" or "1"
			log[#log + 1] = pane_id .. ":prompt=" .. pane.prompt_value
		elseif roll == 5 then
			ctx.mark_command_sent(pane)
			log[#log + 1] = pane_id .. ":command_sent"
		elseif roll == 6 then
			pane.active = not pane.active
			log[#log + 1] = pane_id .. ":active=" .. tostring(pane.active)
		end
		now = now + math.random() * 1.5
		handler(window, pane)
		log[#log + 1] = pane_id .. ":tick"
	end

	-- Quiesce without forcing any change: every shell is back at its prompt
	-- and enough time passes for in-flight commands to settle. Anything the
	-- sequence left undelivered must be delivered by the ticks that follow.
	for _, pane_id in ipairs(FUZZ_PANE_IDS) do
		panes[pane_id].prompt_value = "1"
	end
	now = now + 10
	for _ = 1, 3 do
		for _, pane_id in ipairs(FUZZ_PANE_IDS) do
			handler(windows[pane_id], panes[pane_id])
		end
	end

	for _, pane_id in ipairs(FUZZ_PANE_IDS) do
		local written = filesystem.files["/state/" .. pane_id]
		if not panes[pane_id].active then
			if written ~= nil then
				violations[#violations + 1] = string.format("inactive pane %d still has state file %s", pane_id, written)
			end
		else
			local expected = ctx.jump_state and "JUMP" or resolve_label(windows[pane_id].key_table, windows[pane_id].leader)
			if written ~= expected then
				violations[#violations + 1] = string.format(
					"pane %d state file is %s, expected %s", pane_id, tostring(written), expected)
			end
			if written ~= "JUMP" and last_signal_snapshot[pane_id] ~= written then
				violations[#violations + 1] = string.format(
					"pane %d last signal saw %s but the file ended as %s",
					pane_id, tostring(last_signal_snapshot[pane_id]), tostring(written))
			end
		end
	end

	return violations, log
end

test("fuzz: random tick sequences keep state files and redraw signals consistent", function()
	for seed = 1, FUZZ_SEEDS do
		local violations, log = run_fuzz_sequence(seed)
		if #violations > 0 then
			error(string.format("seed %d: %s\n      steps: %s",
				seed, table.concat(violations, "; "), table.concat(log, " ")))
		end
	end
end)

print(string.format("\n%d tests, %d failed", total, failures))
os.exit(failures == 0 and 0 or 1)
