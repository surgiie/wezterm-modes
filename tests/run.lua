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

test("starship: legend is written to the sibling .jump file", function()
	local filesystem = fake_filesystem()
	local publisher = dofile("plugin/starship.lua")({ state_dir = "/state" }, filesystem.deps)
	assert_equal(publisher.publish_legend(7, "f:kubectl  j:exec"), true)
	assert_equal(filesystem.files["/state/7.jump"], "f:kubectl  j:exec")
	assert_equal(filesystem.files["/state/7"], nil)
end)

test("starship: unchanged legend does not rewrite, a narrowed one does", function()
	local filesystem = fake_filesystem()
	local publisher = dofile("plugin/starship.lua")({ state_dir = "/state" }, filesystem.deps)
	publisher.publish_legend(7, "fa:one  fb:two")
	assert_equal(publisher.publish_legend(7, "fa:one  fb:two"), false)
	assert_equal(publisher.publish_legend(7, "fa:one"), true)
	assert_equal(filesystem.files["/state/7.jump"], "fa:one")
end)

test("starship: legend strips control characters", function()
	local filesystem = fake_filesystem()
	local publisher = dofile("plugin/starship.lua")({ state_dir = "/state" }, filesystem.deps)
	publisher.publish_legend(7, "f:\27[31mred\n")
	assert_equal(filesystem.files["/state/7.jump"], "f:[31mred")
end)

test("starship: empty legend is not written", function()
	local filesystem = fake_filesystem()
	local publisher = dofile("plugin/starship.lua")({ state_dir = "/state" }, filesystem.deps)
	assert_equal(publisher.publish_legend(7, ""), false)
	assert_equal(filesystem.files["/state/7.jump"], nil)
end)

test("starship: clear_legend removes the file and allows an identical republish", function()
	local filesystem = fake_filesystem()
	local publisher = dofile("plugin/starship.lua")({ state_dir = "/state" }, filesystem.deps)
	publisher.publish_legend(7, "f:one")
	publisher.clear_legend(7)
	assert_equal(filesystem.files["/state/7.jump"], nil)
	assert_equal(publisher.publish_legend(7, "f:one"), true)
end)

test("starship: clear_legend on an unknown pane is a no-op", function()
	local filesystem = fake_filesystem()
	local publisher = dofile("plugin/starship.lua")({ state_dir = "/state" }, filesystem.deps)
	publisher.clear_legend(99)
	assert_equal(next(filesystem.files), nil)
end)

test("starship: default directory honours XDG_RUNTIME_DIR shape", function()
	local publisher = dofile("plugin/starship.lua")({}, fake_filesystem().deps)
	local expected_root = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/wezterm-modes/"
	assert_equal(publisher.path_for(3), expected_root .. "3")
end)

-- ── status.lua wiring (stubbed wezterm) ───────────────────────────────────────

local function load_status(extra_ctx)
	local handlers = {}
	package.loaded["wezterm"] = {
		on = function(event, handler) handlers[event] = handler end,
		format = function(items)
			local text = {}
			for _, item in ipairs(items) do
				if type(item) == "table" and item.Text then text[#text + 1] = item.Text end
			end
			return table.concat(text)
		end,
		action = { PopKeyTable = "pop", SendString = function(text) return { send = text } end },
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
	local window = { left_status = nil, sent = {} }
	function window:active_key_table() return key_table end
	function window:leader_is_active() return leader_active or false end
	function window:set_left_status(text) self.left_status = text end
	function window:perform_action(action)
		if type(action) == "table" and action.send then
			self.sent[#self.sent + 1] = action.send
		end
	end
	return window
end

local function fake_pane(pane_id)
	return { pane_id = function() return pane_id end }
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

test("redraw: sequence is sent once per mode change, not on unchanged ticks", function()
	local handler = load_status({ starship = { state_dir = "/state" } })
	local window = fake_window("normal_mode")
	handler(window, fake_pane(5))
	handler(window, fake_pane(5))
	assert_equal(#window.sent, 1)
	assert_equal(window.sent[1], "\27[9001~")
	local next_window = fake_window(nil)
	handler(next_window, fake_pane(5))
	assert_equal(#next_window.sent, 1)
end)

test("redraw: custom sequence is used", function()
	local handler = load_status({ starship = { state_dir = "/state", redraw_sequence = "\27[9999~" } })
	local window = fake_window("normal_mode")
	handler(window, fake_pane(5))
	assert_equal(window.sent[1], "\27[9999~")
end)

test("redraw: redraw_sequence = false sends nothing but still publishes", function()
	local handler, filesystem = load_status({ starship = { state_dir = "/state", redraw_sequence = false } })
	local window = fake_window("normal_mode")
	handler(window, fake_pane(5))
	assert_equal(#window.sent, 0)
	assert_equal(filesystem.files["/state/5"], "NORMAL")
end)

test("redraw: nothing is sent to an inactive pane", function()
	local handler = load_status({
		starship = { state_dir = "/state" },
		should_run = function() return false end,
	})
	local window = fake_window(nil)
	handler(window, fake_pane(5))
	assert_equal(#window.sent, 0)
end)

test("redraw: not sent to a non-shell pane even when should_run allows it", function()
	local handler, filesystem = load_status({
		starship = { state_dir = "/state" },
		pane_is_shell = function() return false end,
	})
	local window = fake_window("normal_mode")
	handler(window, fake_pane(5))
	assert_equal(#window.sent, 0)
	assert_equal(filesystem.files["/state/5"], "NORMAL")
end)

test("redraw: sent when pane_is_shell confirms a shell", function()
	local handler = load_status({
		starship = { state_dir = "/state" },
		pane_is_shell = function() return true end,
	})
	local window = fake_window("normal_mode")
	handler(window, fake_pane(5))
	assert_equal(#window.sent, 1)
end)

local function pane_with_zone(pane_id, zone, cursor_row)
	return {
		pane_id = function() return pane_id end,
		get_semantic_zones = function() return zone and { zone } or {} end,
		get_cursor_position = function() return { x = 0, y = cursor_row } end,
	}
end

test("redraw: sent when the cursor is inside the last Input zone", function()
	local handler = load_status({ starship = { state_dir = "/state" } })
	local window = fake_window("normal_mode")
	handler(window, pane_with_zone(5, { start_y = 10, end_y = 11 }, 11))
	assert_equal(#window.sent, 1)
end)

test("redraw: not sent while a command runs below the Input zone", function()
	local handler, filesystem = load_status({ starship = { state_dir = "/state" } })
	local window = fake_window("normal_mode")
	handler(window, pane_with_zone(5, { start_y = 10, end_y = 10 }, 14))
	assert_equal(#window.sent, 0)
	assert_equal(filesystem.files["/state/5"], "NORMAL")
end)

test("redraw: no Input zones (no shell integration) falls back to sending", function()
	local handler = load_status({ starship = { state_dir = "/state" } })
	local window = fake_window("normal_mode")
	handler(window, pane_with_zone(5, nil, 3))
	assert_equal(#window.sent, 1)
end)

test("redraw: zone check cannot override a non-shell process", function()
	local handler = load_status({
		starship = { state_dir = "/state" },
		pane_is_shell = function() return false end,
	})
	local window = fake_window("normal_mode")
	handler(window, pane_with_zone(5, { start_y = 10, end_y = 11 }, 11))
	assert_equal(#window.sent, 0)
end)

test("badge: badge = false shows the badge while a command runs", function()
	local handler = load_status({ starship = { state_dir = "/state", badge = false } })
	local window = fake_window("normal_mode")
	handler(window, pane_with_zone(5, { start_y = 10, end_y = 10 }, 14))
	assert_equal(window.left_status, " NORMAL ")
end)

test("redraw: nothing is sent when starship is not configured", function()
	local handler = load_status()
	local window = fake_window("normal_mode")
	handler(window, fake_pane(5))
	assert_equal(#window.sent, 0)
end)

test("legend: published and redrawn only when it changes", function()
	local _, filesystem, ctx = load_status({ starship = { state_dir = "/state" } })
	local window = fake_window("jump_mode")
	ctx.publish_legend(window, fake_pane(5), "fa:one  fb:two")
	ctx.publish_legend(window, fake_pane(5), "fa:one  fb:two")
	assert_equal(filesystem.files["/state/5.jump"], "fa:one  fb:two")
	assert_equal(#window.sent, 1)
	ctx.publish_legend(window, fake_pane(5), "fa:one")
	assert_equal(#window.sent, 2)
end)

test("legend: clear_legend removes the file", function()
	local _, filesystem, ctx = load_status({ starship = { state_dir = "/state" } })
	ctx.publish_legend(fake_window("jump_mode"), fake_pane(5), "f:one")
	ctx.clear_legend(fake_pane(5))
	assert_equal(filesystem.files["/state/5.jump"], nil)
end)

test("legend: redraw is not sent to a non-shell pane but the file is written", function()
	local _, filesystem, ctx = load_status({
		starship = { state_dir = "/state" },
		pane_is_shell = function() return false end,
	})
	local window = fake_window("jump_mode")
	ctx.publish_legend(window, fake_pane(5), "f:one")
	assert_equal(filesystem.files["/state/5.jump"], "f:one")
	assert_equal(#window.sent, 0)
end)

test("legend: redraw_sequence = false writes the file but sends nothing", function()
	local _, filesystem, ctx = load_status({ starship = { state_dir = "/state", redraw_sequence = false } })
	local window = fake_window("jump_mode")
	ctx.publish_legend(window, fake_pane(5), "f:one")
	assert_equal(filesystem.files["/state/5.jump"], "f:one")
	assert_equal(#window.sent, 0)
end)

test("legend: without starship opts, publish and clear are no-ops", function()
	local _, filesystem, ctx = load_status()
	local window = fake_window("jump_mode")
	ctx.publish_legend(window, fake_pane(5), "f:one")
	ctx.clear_legend(fake_pane(5))
	assert_equal(next(filesystem.files), nil)
	assert_equal(#window.sent, 0)
end)

print(string.format("\n%d tests, %d failed", total, failures))
os.exit(failures == 0 and 0 or 1)
