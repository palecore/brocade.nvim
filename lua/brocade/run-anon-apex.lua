-- run-anon-apex.lua
--
-- Utilities for running anonymous Apex.
--

local M = {}

local function sq_escape(str) return string.gsub(str, "'", "\\'") end

local function sf_config_path()
	local sfdx_project_dir = vim.fs.root(".", { ".sf" })
	assert(sfdx_project_dir, "Couldn't find SFDX project root directory!")
	return vim.fs.joinpath(sfdx_project_dir, ".sf", "config.json")
end

local function read_project_config()
	local sf_config_lines = vim.fn.readfile(sf_config_path())
	assert(sf_config_lines, "Couldn't read project's SF CLI configuration!")
	local sf_config_json = table.concat(sf_config_lines, "\n")
	local sf_config = vim.json.decode(sf_config_json, { luanil = { array = true, object = true } })
	assert(sf_config, "Couldn't parse project's SF CLI configuration!")
	--
	return {
		sf_target_org = sf_config["target-org"],
		sf_config = sf_config,
	}
end

local function fetch_org_info(target_org, callback)
	-- if target org is not given, use project-default one:
	if not target_org then target_org = read_project_config().sf_target_org end
	--
	local org_infos = vim.g.brocade_org_infos or {}
	-- in case this org's info has been already cached - return it:
	if org_infos[target_org] then
		callback(org_infos[target_org])
		return
	end
	-- otherwise, fetch it from SF CLI:
	local sf_cmd = { "sf", "org", "display", "--json" }
	if target_org then table.insert(sf_cmd, "--target-org=" .. target_org) end
	vim.system(sf_cmd, {}, function(obj)
		assert(obj.stdout, "No standard output!")
		assert(type(obj.stdout) == "string", "Standard output is not a string!")
		--
		local response = vim.json.decode(obj.stdout, { luanil = { object = true, array = true } })
		assert(response["status"] == 0, "Response has a non-zero status!")
		assert(response["result"], "Response doesn't have a result")
		--
		local org_info = {
			api_version = assert(response["result"]["apiVersion"]),
			instance_url = assert(response["result"]["instanceUrl"]),
			access_token = assert(response["result"]["accessToken"]),
			username = assert(response["result"]["username"]),
			alias = assert(response["result"]["alias"]),
		}
		org_infos[org_info.username] = org_info
		org_infos[org_info.alias] = org_info
		vim.g.brocade_org_infos = org_infos
		callback(org_info)
	end)
end

local function CurlReq()
	local self = {}
	local _self = {
		method = "GET",
		api_version = nil,
		instance_url = nil,
		access_token = nil,
		suburl = nil,
		tooling_suburl = nil,
		data_key = nil,
		data_value = nil,
		json_data = nil,
		is_expecting_json = true,
	}
	function self.set_method(m) _self.method = m end
	function self.set_api_version(av) _self.api_version = av end
	function self.set_instance_url(iu) _self.instance_url = iu end
	function self.set_access_token(at) _self.access_token = at end
	function self.set_suburl(su) _self.suburl = su end
	function self.set_tooling_suburl(tsu) _self.tooling_suburl = tsu end
	function self.set_json_data(jd) _self.json_data = jd end
	function self.set_expect_json(is_expecting_json) _self.is_expecting_json = is_expecting_json end
	function self.set_kv_data(k, v)
		_self.data_key = k
		_self.data_value = v
	end

	function self.send(cb)
		-- required inputs:
		local instance_url = assert(_self.instance_url)
		local api_version = assert(_self.api_version)
		local access_token = assert(_self.access_token)
		local method = assert(_self.method)
		-- optional inputs:
		local tooling_suburl = _self.tooling_suburl
		local json_data = _self.json_data
		-- request building:
		local call_url = instance_url
		if _self.suburl then
			call_url = call_url .. _self.suburl
		elseif _self.tooling_suburl then
			call_url = call_url .. "/services/data/" .. "v" .. api_version .. "/tooling" .. tooling_suburl
		else
			assert(false, "No URL of any variant given!")
		end
		local call_cmd = {
			"curl",
			"-s",
			"-H",
			"Authorization: Bearer " .. access_token,
		}
		if _self.is_expecting_json then
			table.insert(call_cmd, "-H")
			table.insert(call_cmd, "Accept: application/json")
		end
		local call_stdin = nil
		if method == "GET" then
			table.insert(call_cmd, "-G")
			local data_key = _self.data_key
			local data_value = _self.data_value
			if data_key and data_value then
				table.insert(call_cmd, "--data-urlencode")
				table.insert(call_cmd, data_key .. "@-")
				call_stdin = data_value
			end
		elseif method == "POST" and json_data then
			table.insert(call_cmd, "-X")
			table.insert(call_cmd, "POST")
			table.insert(call_cmd, "-H")
			table.insert(call_cmd, "Content-Type: application/json")
			table.insert(call_cmd, "--data")
			table.insert(call_cmd, "@-")
			call_stdin = json_data
		elseif method == "DELETE" then
			table.insert(call_cmd, "-X")
			table.insert(call_cmd, "DELETE")
		elseif method == "PATCH" and json_data then
			table.insert(call_cmd, "-X")
			table.insert(call_cmd, "PATCH")
			table.insert(call_cmd, "-H")
			table.insert(call_cmd, "Content-Type: application/json")
			table.insert(call_cmd, "--data")
			table.insert(call_cmd, "@-")
			call_stdin = json_data
		end
		table.insert(call_cmd, call_url)
		vim.system(call_cmd, { stdin = call_stdin }, function(obj)
			if not _self.is_expecting_json then
				local result = obj.stdout
				vim.notify(
					vim.inspect({ "call_cmd", call_cmd, "stdin", call_stdin, "result", result }),
					vim.log.levels.DEBUG
				)
				cb(result)
				return
			end
			--
			local result_json = obj.stdout
			if not result_json then
				error("Response is incomplete!")
				return
			end
			local result_ok, result =
				pcall(vim.json.decode, result_json, { luanil = { array = true, object = true } })
			if not result_ok then
				error("Couldn't parse result JSON: " .. vim.inspect(result))
				return
			end
			vim.notify(
				vim.inspect({ "call_cmd", call_cmd, "stdin", call_stdin, "result", result }),
				vim.log.levels.DEBUG
			)
			cb(result)
		end)
	end

	return self
end

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

	function self.run_this_buf()
		local buf_lines = vim.api.nvim_buf_get_lines(0, 0, -1, true)
		local buf_text = table.concat(buf_lines, "\n")
		_self.anonymous_body = buf_text
		fetch_org_info(_self.target_org, _self.run_this_buf_save_org_info)
	end
	function _self.run_this_buf_save_org_info(org_info)
		_self.access_token = assert(org_info.access_token)
		_self.instance_url = assert(org_info.instance_url)
		_self.api_version = assert(org_info.api_version)
		_self.username = assert(org_info.username)
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
			tell_debug(vim.inspect(result))
			return
		end
		if not result.success then
			tell_failed("Apex didn't succeed!")
			tell_debug(vim.inspect(result))
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
		local function is_any_log_entry(line)
			return not not string.match(line, "^[%d:.]+ [(]%d+[)][|]")
		end
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
