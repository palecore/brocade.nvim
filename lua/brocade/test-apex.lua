local M = {}

-- IMPORTS
local FetchAuthInfo = require("brocade.org-session").FetchAuthInfo
local CurlReq = require("brocade.curl-request").CurlRequest
local Logger = require("brocade.logging").Logger
local buf_diagnostics = require("brocade.diagnostics")

-- IMPLEMENTATION

local RunTests = {
	_logger = Logger:get_instance(),
	_target_org = nil,
	_auth_info = nil,
	_class_name = nil,
	---@type string[]?
	_test_methods = nil,
}
RunTests.__index = RunTests
M.Run = RunTests

function RunTests:new() return setmetatable({}, self) end

function RunTests:set_target_org(target_org) self._target_org = target_org end
function RunTests:set_class_name(name) self._class_name = name end

---Restricts the test run to a specific subset of test methods on the class.
---When `nil` or empty, all test methods on the class are executed.
---@param methods string[]?
function RunTests:set_test_methods(methods)
	if methods and #methods > 0 then
		self._test_methods = methods
	else
		self._test_methods = nil
	end
end

---@async
function RunTests:run_async()
	self._logger:tell_wip("Fetching auth info...")
	local fetch_auth_info = FetchAuthInfo:new()
	if self._target_org then fetch_auth_info:set_target_org(self._target_org) end
	self._auth_info = fetch_auth_info:run_async()

	assert(self._class_name, "Class name must be set")

	-- Build request payload for runTestsSynchronous
	local class_entry = { className = self._class_name }
	if self._test_methods then class_entry.testMethods = self._test_methods end
	local test_payload = { tests = { class_entry } }

	local req = CurlReq:new()
	req:use_auth_info(self._auth_info)
	req:set_tooling_suburl("/runTestsSynchronous/")
	req:set_method("POST")
	req:set_json_data(vim.json.encode(test_payload))

	self._logger:tell_wip("Running tests for " .. self._class_name .. "...")
	local resp = assert(req:send_async(), "Test result invalid!")

	local result = {
		failures = resp.failures or {},
		successes = resp.successes or {},
		num_failures = resp.numFailures or 0,
		num_tests_run = resp.numTestsRun or 0,
	}
	return result
end

---@async
function RunTests:run_on_this_buf_async()
	-- the rest runs in plenary async context:
	local file_path = vim.api.nvim_buf_get_name(0)
	if not file_path or file_path == "" then
		self._logger:tell_failed("Buffer has no filename")
		return
	end

	-- must be a .cls file inside force-app/main/default/classes
	local class_name = string.match(file_path, "([^/]+)%.cls$")
	if not class_name or not string.find(file_path, "force%-app/main/default/classes/") then
		self._logger:tell_failed(
			"Current buffer is not an Apex class in force-app/main/default/classes"
		)
		return
	end

	self:set_class_name(class_name)

	-- Clear previous diagnostics
	local ns = vim.api.nvim_create_namespace("brocade-apex-test")
	vim.schedule(function() vim.diagnostic.reset(ns, 0) end)

	local result = self:run_async()

	-- Process results on main thread
	vim.schedule(function()
		if result.num_failures > 0 then
			self:_show_test_failures(result.failures, ns, 0, class_name)
			self._logger:tell_failed(
				string.format(
					"%d of %d tests failed for %s",
					result.num_failures,
					result.num_tests_run,
					class_name
				)
			)
		elseif result.num_tests_run == 0 then
			self._logger:tell_failed("No tests were run for " .. class_name)
		else
			self._logger:tell_finished(
				string.format("Successfully ran %d tests for %s", result.num_tests_run, class_name)
			)
		end
	end)
end

---Parse stack trace to find line and column for a specific class
---@param stack_trace string The stack trace string
---@param class_name string The class name to find
---@return number|nil line_num Zero-based line number
---@return number|nil col_num Zero-based column number
function RunTests:_parse_stack_trace(stack_trace, class_name)
	if not stack_trace or stack_trace == "" then
		return nil, nil
	end

	-- Stack trace format: "Class.ClassName.methodName: line X, column Y"
	-- Split by newlines and look for the matching class
	for line in stack_trace:gmatch("[^\n]+") do
		local matched_class, line_str, col_str = line:match("Class%.([^.:]+)[^:]*:%s*line%s*(%d+),%s*column%s*(%d+)")
		if matched_class == class_name then
			local line_num = tonumber(line_str)
			local col_num = tonumber(col_str)
			if line_num and col_num then
				return line_num - 1, col_num - 1  -- Convert to zero-based
			end
		end
	end

	return nil, nil
end

function RunTests:_show_test_failures(failures, ns, bufnr, class_name)
	if not failures or type(failures) ~= "table" or #failures == 0 then return end

	local diagnostics = {}
	for _, failure in ipairs(failures) do
		-- Only show failures for the current class
		local failure_class = failure.name or ""
		if failure_class == class_name then
			local line_num = failure.lineNumber and (failure.lineNumber - 1) or nil
			local col_num = failure.columnNumber and (failure.columnNumber - 1) or nil

			-- If line/column not provided, try parsing from stack trace
			if not line_num or not col_num then
				local parsed_line, parsed_col = self:_parse_stack_trace(failure.stackTrace, class_name)
				line_num = line_num or parsed_line or 0
				col_num = col_num or parsed_col or 0
			end

			-- Build error message
			local msg_parts = {}
			if failure.methodName then
				table.insert(msg_parts, "Test: " .. failure.methodName)
			end
			if failure.message then table.insert(msg_parts, failure.message) end
			if failure.stackTrace then table.insert(msg_parts, "\n" .. failure.stackTrace) end

			local msg = #msg_parts > 0 and table.concat(msg_parts, "\n") or "Test failure"

			table.insert(diagnostics, {
				lnum = line_num,
				col = col_num,
				message = msg,
				severity = vim.diagnostic.severity.ERROR,
				source = "apex-test",
			})
		end
	end

if #diagnostics > 0 then buf_diagnostics._set(ns, bufnr, diagnostics) end
end

---Scans Apex source lines for declarations of test methods.
---Recognises both:
---  * Modern style: an `@isTest` annotation followed (after optional further
---    annotations and modifiers) by a method declaration.
---  * Legacy style: methods using the `testMethod` modifier inline.
---Comments and `@isTest(...)` argument lists are tolerated.
---@param lines string[]
---@return string[] method_names In source order, deduplicated.
function M.find_test_methods(lines)
	local results = {}
	local seen = {}
	local function push(name)
		if not name or name == "" then return end
		if seen[name] then return end
		seen[name] = true
		table.insert(results, name)
	end

	---Strips line and block comments from a single line. Block comments
	---spanning multiple lines are out of scope; this is a heuristic helper.
	local function strip_comments(line)
		line = line:gsub("//.*$", "")
		line = line:gsub("/%*.-%*/", "")
		return line
	end

	---Returns a method name if `line` looks like an Apex method declaration
	---(return type + identifier + `(`).
	local function method_name_in(line)
		-- Strip leading modifiers and the `testMethod` keyword (case-insensitive)
		-- before matching, so that legacy `static testMethod void foo()` works.
		local ident = "[%w_]+"
		-- Try patterns like "<returnType> <name>(":
		local name = line:match(ident .. "%s+(" .. ident .. ")%s*%(")
		return name
	end

	local pending_istest = false
	for _, raw_line in ipairs(lines) do
		local line = strip_comments(raw_line)
		local trimmed = vim.trim(line)
		if trimmed ~= "" then
			local lower = trimmed:lower()
			-- Detect @isTest / @IsTest annotations (with or without arguments).
			if lower:match("^@istest") then
				-- @isTest on a class line is fine; we'll just look at subsequent
				-- method declarations to decide what is a test method.
				pending_istest = true
				-- @isTest may be on the same line as the method declaration:
				local after_anno = trimmed:gsub("^@[Ii][Ss][Tt][Ee][Ss][Tt][^%s]*%s*", "")
				-- The above gsub is intentionally tolerant; fall back to simply
				-- continuing onto the next non-annotation line.
				local name = method_name_in(after_anno)
				if name then
					push(name)
					pending_istest = false
				end
			elseif lower:match("^@") then
				-- Some other annotation on its own line; keep the pending flag.
			elseif lower:match("%f[%w_]class%f[^%w_]") or lower:match("%f[%w_]interface%f[^%w_]") then
				-- A class/interface declaration consumes any pending @isTest;
				-- the annotation marks the *type* as a test type, not a method.
				pending_istest = false
			elseif lower:find("testmethod", 1, true) then
				-- Legacy `testMethod` modifier; counts as a test method even
				-- without an `@isTest` annotation directly above.
				local name = method_name_in(line)
				if name and name:lower() ~= "testmethod" then push(name) end
				pending_istest = false
			elseif pending_istest then
				local name = method_name_in(line)
				if name then
					push(name)
					pending_istest = false
				end
			end
		end
	end
	return results
end

return M
