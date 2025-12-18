-- run-anon-apex.lua
--
-- Utilities for running anonymous Apex.
--

local M = {}

-- IMPORTS

local CurlReq = require("brocade.curl-request").CurlRequest
local FetchAuthInfo = require("brocade.org-session").FetchAuthInfo

-- IMPLEMENTATION

local function sq_escape(str) return string.gsub(str, "'", "\\'") end

function M.RunAnonApex()
	local self = {}
	local _self = {
		target_org = nil,
		anonymous_body = nil,
		instance_url = nil,
		api_version = nil,
		access_token = nil,
		username = nil,
		apex_log_id = nil,
		diagno_ns = nil,
	}

	local progress_handle = nil
	local function tell_wip(msg)
		vim.schedule(function()
			if not progress_handle then
				progress_handle = require("fidget").progress.handle.create({
					title = "brocade.nvim",
					message = msg,
				})
			else
				progress_handle:report({
					message = msg,
				})
			end
		end)
	end
	local function tell_failed(msg)
		vim.schedule(function()
			if not progress_handle then return end
			progress_handle.message = msg
			progress_handle:cancel()
		end)
	end
	local function tell_finished(msg)
		vim.schedule(function()
			if not progress_handle then return end
			progress_handle.message = msg
			progress_handle:finish()
		end)
	end

	local function tell_debug(msg) vim.notify(msg, vim.log.levels.DEBUG) end

	function self.set_target_org(value) _self.target_org = value end

	local function get_file_or_buf_lines()
		local file_path = vim.api.nvim_buf_get_name(0)
		if file_path and vim.fn.filereadable(file_path) == 1 then
			return vim.fn.readfile(file_path)
		else
			return vim.api.nvim_buf_get_lines(0, 0, -1, true)
		end
	end

	function self.run_this_buf()
		_self.diagno_ns = vim.api.nvim_create_namespace("brocade")
		-- reset error diagnostics from previous anon-apex run if present:
		vim.diagnostic.reset(_self.diagno_ns, 0)
		--
		local buf_lines = get_file_or_buf_lines()
		local buf_text = table.concat(buf_lines, "\n")
		_self.anonymous_body = buf_text
		tell_wip("Fetching auth info...")
		local fetch_auth_info = FetchAuthInfo:new()
		if _self.target_org then fetch_auth_info:set_target_org(_self.target_org) end
		fetch_auth_info:run_async(function(auth_info) _self.run_this_buf_save_auth_info(auth_info) end)
	end
	function _self.run_this_buf_save_auth_info(auth_info)
		---@cast auth_info brocade.org-session.AuthInfo
		_self.access_token = assert(auth_info.get_access_token())
		_self.instance_url = assert(auth_info.get_instance_url())
		_self.api_version = assert(auth_info.get_api_version())
		_self.username = assert(auth_info.get_username())
		_self.run_this_buf_fetch_user_id()
	end
	function _self.run_this_buf_fetch_user_id()
		local req = CurlReq()
		req.set_access_token(_self.access_token)
		req.set_api_version(_self.api_version)
		req.set_instance_url(_self.instance_url)
		req.set_tooling_suburl("/query")
		local username_sq_esc = sq_escape(_self.username)
		req.set_kv_data(
			"q",
			("SELECT Id FROM User WHERE Username = '%s' LIMIT 1"):format(username_sq_esc)
		)
		tell_wip("Quering user info...")
		req.send(_self.run_this_buf_parse_user_id)
	end
	function _self.run_this_buf_parse_user_id(result)
		assert(result, "User query result invalid!")
		assert(result.done == true, "Query not finished!")
		assert(result.size == 1, "Query result is not 1 record!")
		assert(result.totalSize == 1, "Query result is not 1 record total!")
		assert(result.entityTypeName == "User", "Unexpected query result entity!")
		local records = result.records
		local user_record = records[1]
		_self.user_id = assert(user_record.Id)
		-- fetch debug level ID:
		local req = CurlReq()
		req.set_access_token(_self.access_token)
		req.set_api_version(_self.api_version)
		req.set_instance_url(_self.instance_url)
		req.set_tooling_suburl("/query")
		local debug_lvl_dev_name = "SFDC_DevConsole"
		local debug_lvl_dev_name_sq_esc = sq_escape(debug_lvl_dev_name)
		req.set_kv_data(
			"q",
			("SELECT Id FROM DebugLevel WHERE DeveloperName = '%s' LIMIT 1"):format(
				debug_lvl_dev_name_sq_esc
			)
		)
		tell_wip("Quering debug level info...")
		req.send(_self.run_this_buf_parse_debug_lvl_query)
	end
	function _self.run_this_buf_parse_debug_lvl_query(result)
		assert(result, "Debug Level query result invalid!")
		assert(result.done == true, "Query not finished!")
		assert(result.entityTypeName == "DebugLevel", "Unexpected query result entity!")
		assert(result.size == 1, "Query result is not 1 record!")
		assert(result.totalSize == 1, "Query result is not 1 record total!")
		local records = result.records
		local debug_lvl_record = records[1]
		_self.debug_lvl_id = assert(debug_lvl_record.Id)
		_self.run_this_buf_query_prev_trace_flag()
	end
	function _self.run_this_buf_query_prev_trace_flag()
		-- todo query
		local req = CurlReq()
		req.set_access_token(_self.access_token)
		req.set_api_version(_self.api_version)
		req.set_instance_url(_self.instance_url)
		req.set_tooling_suburl("/query")
		local debug_lvl_id = assert(_self.debug_lvl_id)
		local debug_lvl_id_sq_esc = sq_escape(debug_lvl_id)
		local user_id = assert(_self.user_id)
		local user_id_sq_esc = sq_escape(user_id)
		req.set_kv_data(
			"q",
			("SELECT Id FROM TraceFlag WHERE DebugLevelId = '%s' AND TracedEntityId = '%s' LIMIT 1"):format(
				debug_lvl_id_sq_esc,
				user_id_sq_esc
			)
		)
		tell_wip("Querying previous trace flag...")
		req.send(_self.run_this_buf_patch_prev_trace_flag)
	end
	function _self.run_this_buf_patch_prev_trace_flag(result)
		assert(result, "Trace Flag query result invalid!")
		assert(result.done == true, "Query not finished!")
		assert(result.size, "No query result size given!")
		assert(result.totalSize, "No query result total size given!")
		assert(result.size == result.totalSize, "Query result size and total size don't match!")
		-- No need to delete previous trace flag:
		if result.size == 0 or result.totalSize == 0 then
			tell_wip("Creating new trace flag...")
			return _self.run_this_buf_create_trace_flag()
		end
		--
		assert(result.entityTypeName == "TraceFlag", "Unexpected query result entity!")
		assert(result.size == 1, "Query result size should be 1 at this point!")
		local records = result.records
		local prev_trace_flag_record = records[1] or {}
		local prev_trace_flag_url = (prev_trace_flag_record.attributes or {}).url
		assert(prev_trace_flag_url, "Previous Trace Flag URL invalid!")
		-- patch previous trace flag record with new date range:
		local req = CurlReq()
		req.set_access_token(_self.access_token)
		req.set_api_version(_self.api_version)
		req.set_instance_url(_self.instance_url)
		req.set_method("PATCH")
		local now_dt = os.date("*t")
		now_dt.min = now_dt.min - 1
		---@cast now_dt osdate
		local now_time = os.time(now_dt)
		local now_str = os.date("%Y-%m-%dT%T%z", now_time)
		local soon_dt = os.date("*t")
		soon_dt.min = soon_dt.min + 2
		---@cast soon_dt osdate
		local soon_time = os.time(soon_dt)
		local soon_str = os.date("%Y-%m-%dT%T%z", soon_time)
		req.set_json_data(vim.json.encode({
			["StartDate"] = now_str,
			["ExpirationDate"] = soon_str,
		}))
		req.set_suburl(prev_trace_flag_url)
		req.set_expect_json(false)
		tell_wip("Updating previous trace flag...")
		req.send(_self.run_this_buf_parse_trace_flag_post)
	end
	function _self.run_this_buf_create_trace_flag(_)
		local req = CurlReq()
		req.set_method("POST")
		req.set_access_token(_self.access_token)
		req.set_api_version(_self.api_version)
		req.set_instance_url(_self.instance_url)
		req.set_tooling_suburl("/sobjects/traceFlag")
		local now_dt = os.date("*t")
		now_dt.min = now_dt.min - 1
		---@cast now_dt osdate
		local now_time = os.time(now_dt)
		local now_str = os.date("%Y-%m-%dT%T%z", now_time)
		local soon_dt = os.date("*t")
		soon_dt.min = soon_dt.min + 2
		---@cast soon_dt osdate
		local soon_time = os.time(soon_dt)
		local soon_str = os.date("%Y-%m-%dT%T%z", soon_time)
		local user_id = _self.user_id
		local debug_lvl_id = assert(_self.debug_lvl_id)
		req.set_json_data(vim.json.encode({
			["ApexCode"] = "Finest",
			["ApexProfiling"] = "Error",
			["Callout"] = "Error",
			["Database"] = "Error",
			["StartDate"] = now_str,
			["ExpirationDate"] = soon_str,
			["System"] = "Error",
			["TracedEntityId"] = user_id,
			["Validation"] = "Error",
			["Visualforce"] = "Error",
			["Workflow"] = "Error",
			["LogType"] = "USER_DEBUG",
			["DebugLevelId"] = debug_lvl_id,
		}))
		tell_wip("Creating new trace flag...")
		req.send(_self.run_this_buf_parse_trace_flag_post)
	end
	function _self.run_this_buf_parse_trace_flag_post(result)
		if #result == 0 then
			tell_wip("Executing anonymous Apex...")
			_self.run_this_buf_exec_anon_apex()
		else
			tell_failed("Creating new trace flag failed!")
		end
	end
	function _self.run_this_buf_exec_anon_apex()
		local anon_body = assert(_self.anonymous_body, "Anon body is not set!")
		local req = CurlReq()
		req.set_method("GET")
		req.set_access_token(_self.access_token)
		req.set_api_version(_self.api_version)
		req.set_instance_url(_self.instance_url)
		req.set_tooling_suburl("/executeAnonymous")
		req.set_kv_data("anonymousBody", anon_body)
		req.send(_self.run_this_buf_parse_anon_apex)
	end
	function _self.run_this_buf_parse_anon_apex(result)
		assert(result, "Result invalid!")
		if not result.compiled then
			tell_failed("Apex didn't compile!")
			local line = assert(result.line)
			local column = assert(result.column)
			local compileProblem = assert(result.compileProblem)
			local diagno_ns = assert(_self.diagno_ns)
			vim.schedule(function()
				-- set a diagnostic message for that compilation failure:
				vim.diagnostic.set(diagno_ns, 0, {
					{ lnum = line, col = column, message = compileProblem },
				})
				-- after saving/re-reading the buffer, auto-clear this diagnostic:
				vim.api.nvim_create_autocmd(
					{ "BufRead", "BufWrite" },
					{ buffer = 0, once = true, callback = function() vim.diagnostic.reset(diagno_ns, 0) end }
				)
			end)
			return
		end
		if not result.success then
			tell_failed("Apex didn't succeed!")
			local line = result.line
			local column = result.column
			local except_msg = result.exceptionMessage
			local except_stacktrace = result.exceptionStackTrace
			local diagno_ns = _self.diagno_ns
			-- ensure all data is available for a diagnostic message:
			if line and column and except_msg and except_stacktrace and diagno_ns then
			else
				return
			end
			vim.schedule(function()
				-- set a diagnostic message for that runtime failure:
				vim.diagnostic.set(diagno_ns, 0, {
					{ lnum = line, col = column, message = except_msg .. "\n" .. except_stacktrace },
				})
				-- after saving/re-reading the buffer, auto-clear this diagnostic:
				vim.api.nvim_create_autocmd(
					{ "BufRead", "BufWrite" },
					{ buffer = 0, once = true, callback = function() vim.diagnostic.reset(diagno_ns, 0) end }
				)
			end)
			return
		end
		-- retrieve log from anon apex:
		local username = assert(_self.username)
		local username_sq_esc = sq_escape(username)
		--

		local req = CurlReq()
		req.set_method("GET")
		req.set_access_token(_self.access_token)
		req.set_api_version(_self.api_version)
		req.set_instance_url(_self.instance_url)
		req.set_tooling_suburl("/query")
		local operation = ("/services/data/v%s/tooling/executeAnonymous"):format(_self.api_version)
		local operation_sq_esc = sq_escape(operation)
		req.set_kv_data(
			"q",
			("SELECT Id FROM ApexLog WHERE LogUser.Username = '%s' AND OPERATION = '%s' ORDER BY StartTime DESC LIMIT 1"):format(
				username_sq_esc,
				operation_sq_esc
			)
		)
		tell_wip("Querying Apex log...")
		req.send(_self.run_this_buf_parse_log_query)
	end
	function _self.run_this_buf_parse_log_query(result)
		assert(result, "Apex Log query result invalid!")
		assert(result.done == true, "Query not finished!")
		assert(result.entityTypeName == "ApexLog", "Unexpected query result entity!")
		assert(result.size == 1, "Query result is not 1 record!")
		assert(result.totalSize == 1, "Query result is not 1 record total!")
		local records = result.records
		local apex_log_record = records[1]
		_self.apex_log_id = assert(apex_log_record.Id)
		local apex_log_path = assert(apex_log_record.attributes.url .. "/Body")
		--
		local req = CurlReq()
		req.set_method("GET")
		req.set_access_token(_self.access_token)
		req.set_api_version(_self.api_version)
		req.set_instance_url(_self.instance_url)
		req.set_suburl(apex_log_path)
		req.set_expect_json(false)
		tell_wip("Fetching Apex log body...")
		req.send(vim.schedule_wrap(_self.run_this_buf_parse_log_body))
	end
	function _self.run_this_buf_parse_log_body(log_text)
		local apex_log_id = assert(_self.apex_log_id)
		local log_lines = vim.split(log_text, "\n")
		-- to streamline launching replay debugger, tweak VISUALFORCE to FINEST:
		if log_lines[1] then
			log_lines[1] = string.gsub(log_lines[1], "VISUALFORCE,FINER", "VISUALFORCE,FINEST", 1)
		end
		-- create a buffer with only debug lines filtered and prettified:
		local debug_lines = {}
		local function get_user_debug_prefix(line)
			return string.match(line, "^[%d:.]+ [(]%d+[)][|]USER_DEBUG[|][[]%d+[]][|]DEBUG[|]")
		end
		local function is_any_log_entry(line) return not not string.match(line, "^[%d:.]+ [(]%d+[)][|]") end
		local in_user_debug = false
		for _, line in ipairs(log_lines) do
			local usr_dbg_prefix = get_user_debug_prefix(line)
			if usr_dbg_prefix then
				in_user_debug = true
				line = string.sub(line, #usr_dbg_prefix + 1)
				table.insert(debug_lines, line)
			elseif is_any_log_entry(line) then
				in_user_debug = false
			elseif in_user_debug then
				table.insert(debug_lines, line)
			end
		end
		local debugs_buf_nr = vim.api.nvim_create_buf(true, true)
		vim.api.nvim_buf_set_name(debugs_buf_nr, apex_log_id)
		vim.api.nvim_buf_set_lines(debugs_buf_nr, 0, -1, true, debug_lines)
		vim.api.nvim_open_win(debugs_buf_nr, true, { split = "below" })
		-- create a buffer with the whole log & write to a proper log file:
		local project_root_dir = vim.fs.root(".", { "sfdx-project.json", ".sf", ".sfdx" })
		local log_dir = vim.fs.joinpath(project_root_dir, ".sfdx", "tools", "debug", "logs")
		local log_path = vim.fs.joinpath(log_dir, apex_log_id .. ".log")
		assert(vim.fn.mkdir(log_dir, "p") ~= 0, "Creating log dir failed!")
		assert(vim.fn.writefile(log_lines, log_path, "s") == 0)
		--
		vim.cmd.split()
		vim.cmd.edit(log_path)
		vim.bo.filetype = "sflog"
		tell_finished("Anonymous Apex executed.")
	end

	return self
end

return M
