-- replay-debugger.lua
--
-- Utilize VSC Replay Debugger installation to debug Apex logs.

local M = {}

-- Locate the Apex Replay Debugger adapter within the VS Code extension
local function get_apex_replay_adapter()
	local uv = vim.loop
	local home = vim.env.HOME or "~"
	local extensions_root = home .. "/.vscode-server/extensions"
	local dirs = vim.fn.globpath(
		extensions_root,
		"salesforce.salesforcedx-vscode-apex-replay-debugger-*",
		false,
		true
	)
	table.sort(dirs, function(a, b) return a > b end)
	local extdir = dirs[1]
	if not extdir then
		return nil, "Can't find Salesforce Apex Replay Debugger extension under " .. extensions_root
	end

	-- Try reading package.json for the adapter "program" entry
	local pkg_path = extdir .. "/package.json"
	local adapter_js
	local fd = uv.fs_open(pkg_path, "r", 438)
	if fd then
		local stat = uv.fs_fstat(fd)
		local buf = uv.fs_read(fd, stat.size, 0)
		uv.fs_close(fd)
		local ok, pkg = pcall(vim.json.decode, buf)
		if ok and pkg and pkg.contributes and pkg.contributes.debuggers then
			for _, dbg in ipairs(pkg.contributes.debuggers) do
				if dbg.type == "apex-replay" and dbg.program then
					adapter_js = extdir .. "/" .. dbg.program
					break
				end
			end
		end
	end
	-- Fall back to common bundle locations
	if not adapter_js then
		local candidates = {
			"/dist/apexreplaydebug.js",
			"/dist/apex-replay-debugger.js",
			"/out/src/adapter/apexReplayDebugger.js",
			"/out/src/debugger/apexReplayDebugger.js",
			"/dist/debugAdapter.js",
		}
		for _, rel in ipairs(candidates) do
			local p = extdir .. rel
			if uv.fs_stat(p) then
				adapter_js = p
				break
			end
		end
	end
	if not adapter_js then
		return nil, "Couldn't locate Apex Replay Debugger JS inside: " .. extdir
	end

	return {
		type = "executable",
		command = "node",
		args = { adapter_js },
		-- IMPORTANT: run from the extension folder (the adapter uses relative assets)
		options = { cwd = extdir },
	}
end

-- Read a text file safely
local function read_file_text(path)
	local ok, data = pcall(vim.fn.readfile, path)
	if not ok or not data then return nil end
	return table.concat(data, "\n")
end

-- helper: build lineBreakpointInfo without Apex LS
local function build_line_breakpoint_info(root)
	local uv = vim.loop
	local function file_uri(p) return vim.uri_from_fname(vim.fn.fnamemodify(p, ":p")) end

	-- collect files
	local files = {}
	local function scan(dir)
		local fd = uv.fs_scandir(dir)
		if not fd then return end
		while true do
			local name, t = uv.fs_scandir_next(fd)
			if not name then break end
			local p = dir .. "/" .. name
			if t == "directory" then
				if name ~= ".git" and name ~= ".sfdx" and name ~= "node_modules" then scan(p) end
			else
				if name:match("%.cls$") or name:match("%.trigger$") then table.insert(files, p) end
			end
		end
	end
	scan(root)

	local function readlines(p)
		local ok, data = pcall(vim.fn.readfile, p)
		if not ok or not data then return {} end
		return data
	end

	local function is_breakpointable(line, state)
		local s = line:gsub("%s+$", "")
		-- very light heuristics
		if s == "" then return false end
		if s:match("^%s*//") then return false end
		if s:match("^%s*/%*") then
			state.block = true
			return false
		end
		if state.block then
			if s:match("%*/") then state.block = false end
			return false
		end
		return true
	end

	local function extract_typeref_class(lines)
		-- look for "class <Name>"
		for _, l in ipairs(lines) do
			local name = l:match("%f[%w_]class%s+([%a_][%w_]*)")
			if name then return name end
		end
	end

	local function extract_typeref_trigger(lines)
		-- trigger TriggerName on ObjectName (...)
		for _, l in ipairs(lines) do
			local obj = l:match("%f[%w_]trigger%s+[%a_][%w_]*%s+on%s+([%a_][%w_]*)")
			if obj then return "__sfdc_trigger/" .. obj end
		end
	end

	local result = {}
	for _, f in ipairs(files) do
		local lines = readlines(f)
		local bp = {}
		local st = { block = false }
		for i, l in ipairs(lines) do
			if is_breakpointable(l, st) then table.insert(bp, i) end
		end

		local typeref
		if f:match("%.cls$") then
			typeref = extract_typeref_class(lines)
		else
			typeref = extract_typeref_trigger(lines)
		end

		if typeref and #bp > 0 then
			table.insert(result, {
				uri = file_uri(f),
				lines = bp,
				typeref = typeref,
			})
		end
	end

	return result
end

-- Build a full set of args the adapter expects (incl. logFileContents)
local function make_replay_args(log_path)
	local abs = vim.fn.fnamemodify(log_path, ":p")
	local name = vim.fn.fnamemodify(log_path, ":t")
	local contents = read_file_text(abs)
	return {
		-- These three are what the adapter actually reads
		logFileContents = contents, -- REQUIRED to avoid the crash you saw
		logFilePath = abs,
		logFileName = name,

		-- Keep these for parity and for UI messages
		logFile = abs,

		-- Project root (used for org info / heap dump fetch paths)
		projectPath = vim.fn.getcwd(),

		-- Provide a truthy array to let the adapter proceed without Apex LS
		-- (breakpoint verification will be limited, but stepping works)
		lineBreakpointInfo = function() return build_line_breakpoint_info(vim.fn.getcwd()) end,

		stopOnEntry = true,
		trace = true,
	}
end

---@class brocade.replay-debugger.ReplayDebugger
local ReplayDebugger = {}
ReplayDebugger.__index = ReplayDebugger

---@return brocade.replay-debugger.ReplayDebugger
function M.a_replay_debugger() return setmetatable({}, ReplayDebugger) end

function ReplayDebugger:setup()
	local has_dap, dap = pcall(require, "dap")
	if not has_dap or not dap then
		vim.notify("nvim-dap is required for Apex Replay Debugger support", vim.log.levels.ERROR)
		return
	end

	local dap_apex_cfgs = dap.configurations.apex or {}
	dap.configurations.apex = dap_apex_cfgs
	dap_apex_cfgs[#dap_apex_cfgs + 1] = {
		name = "Apex Replay: current log file",
		type = "apex-replay",
		request = "launch",

		-- Use the current buffer as the log source
		logFileContents = function()
			local p = vim.fn.expand("%:p")
			local args = make_replay_args(p)
			return args.logFileContents
		end,
		logFileName = function() return vim.fn.expand("%:t") end,
		logFilePath = function() return vim.fn.expand("%:p") end,
		projectPath = function() return vim.fn.getcwd() end,
		lineBreakpointInfo = function() return build_line_breakpoint_info(vim.fn.getcwd()) end,

		stopOnEntry = true,
		trace = true,

		cwd = vim.fn.getcwd(),
		workspaceRoot = vim.fn.getcwd(),
	}

	-- Also allow starting from *.log buffers (filetype 'log')
	dap.configurations.sflog = dap.configurations.apex

	local adapter, err = get_apex_replay_adapter()
	if not adapter then
		err = tostring(err) or "Unknown error when locating Apex Replay Debugger adapter!"
		vim.notify(err, vim.log.levels.ERROR)
		return
	end
	dap.adapters = dap.adapters or {}
	dap.adapters["apex-replay"] = adapter
end

return M
