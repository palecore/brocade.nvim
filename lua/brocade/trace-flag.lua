local M = {}

-- IMPORTS

local FetchAuthInfo = require("brocade.org-session").FetchAuthInfo
local CurlReq = require("brocade.curl-request").CurlRequest
local Logger = require("brocade.logging").Logger

-- IMPLEMENTATION

local function sq_escape(str) return string.gsub(str, "'", "\\'") end

local GetTraceFlags = {
	-- DEPENDENCIES
	---@type brocade.logging.Logger
	_logger = Logger:get_instance(),
	-- STATE
	_target_org = nil,
	---@type brocade.org-session.AuthInfo
	_auth_info = nil,
	---@type string
	_user_id = nil,
	---@type string
	_debug_lvl_id = nil,
}
GetTraceFlags.__index = GetTraceFlags
M.Get = GetTraceFlags

---@class brocade.trace-flag.GetTraceFlag.Result
local GetTraceFlagResult = {
	_payload = nil,
	_debug_lvl_id = nil,
	_user_id = nil,
	_size = nil,
	_records = nil,
}
GetTraceFlagResult.__index = GetTraceFlagResult
GetTraceFlags.Result = GetTraceFlagResult

---NOTE: Needs vim.fn.schedule()
---@return integer
local function parse_sf_datetime(dt_str) return vim.fn.strptime("%Y-%m-%dT%X.%S%Z", dt_str) end

function GetTraceFlagResult:user_id() return self._user_id end

function GetTraceFlagResult:debug_level_id() return self._debug_lvl_id end

function GetTraceFlagResult:trace_flags_count() return self._size end

function GetTraceFlagResult:trace_flag_url_at(idx)
	local record = self._records[idx]
	if not record then return nil end
	return record._url
end

function GetTraceFlagResult:trace_flag_id_at(idx)
	local record = self._records[idx]
	if not record then return nil end
	return record._id
end

function GetTraceFlagResult:trace_flag_start_dt_at(idx)
	local record = self._records[idx]
	if not record then return nil end
	return parse_sf_datetime(record._start_dt_str)
end

function GetTraceFlagResult:trace_flex_exp_dt_at(idx)
	local record = self._records[idx]
	if not record then return nil end
	return parse_sf_datetime(record._exp_dt_str)
end

function GetTraceFlagResult:parse_rest_resp(rest_response, user_id, debug_lvl_id)
	local out = setmetatable({}, self)
	--
	local resp = rest_response
	assert(resp, "Trace Flag query result invalid!")
	assert(resp.done == true, "Query not finished!")
	assert(resp.entityTypeName == "TraceFlag", "Unexpected query return type!")
	assert(resp.size, "No query result size given!")
	assert(resp.totalSize, "No query result total size given!")
	assert(resp.size == resp.totalSize, "Query result size and total size don't match!")
	assert(resp.records, "No query records given!")
	--
	out._payload = resp
	out._debug_lvl_id = debug_lvl_id
	out._user_id = user_id
	out._size = resp.size
	out._records = {}
	for idx, record in ipairs(resp.records) do
		out._records[idx] = {
			_id = record.Id,
			_url = record.attributes.url,
			_start_dt_str = record.StartDate,
			_exp_dt_str = record.ExpirationDate,
		}
	end
	return out
end

function GetTraceFlags:new() return setmetatable({}, self) end

function GetTraceFlags:set_target_org(target_org) self._target_org = target_org end

---@param cb? fun(result: brocade.trace-flag.GetTraceFlag.Result)
function GetTraceFlags:run_async(cb)
	self._on_result = cb or function() end
	self._logger:tell_wip("Fetching auth info...")
	local fetch_auth_info = FetchAuthInfo:new()
	if self._target_org then fetch_auth_info:set_target_org(self._target_org) end
	fetch_auth_info:run_async(function(auth_info) self:_run__fetch_user_id(auth_info) end)
end
function GetTraceFlags:_run__fetch_user_id(auth_info)
	---@cast auth_info brocade.org-session.AuthInfo
	self._auth_info = assert(auth_info)
	--
	local req = CurlReq()
	req.set_access_token(auth_info.get_access_token())
	req.set_api_version(auth_info.get_api_version())
	req.set_instance_url(auth_info.get_instance_url())
	req.set_tooling_suburl("/query")
	local username_sq_esc = sq_escape(auth_info.get_username())
	req.set_kv_data(
		"q",
		("SELECT Id FROM User WHERE Username = '%s' LIMIT 1"):format(username_sq_esc)
	)
	self._logger:tell_wip("Quering user info...")
	req.send(function(user_id_response) self:_run__fetch_debug_lvl(user_id_response) end)
end
function GetTraceFlags:_run__fetch_debug_lvl(user_id_response)
	assert(user_id_response, "User query result invalid!")
	assert(user_id_response.done == true, "Query not finished!")
	assert(user_id_response.size == 1, "Query result is not 1 record!")
	assert(user_id_response.totalSize == 1, "Query result is not 1 record total!")
	assert(user_id_response.entityTypeName == "User", "Unexpected query result entity!")
	local records = user_id_response.records
	local user_record = records[1]
	self._user_id = assert(user_record.Id)
	-- fetch debug level ID:
	local req = CurlReq()
	local auth_info = self._auth_info
	req.set_access_token(auth_info.get_access_token())
	req.set_api_version(auth_info.get_api_version())
	req.set_instance_url(auth_info.get_instance_url())
	req.set_tooling_suburl("/query")
	local debug_lvl_dev_name = "SFDC_DevConsole"
	local debug_lvl_dev_name_sq_esc = sq_escape(debug_lvl_dev_name)
	req.set_kv_data(
		"q",
		("SELECT Id FROM DebugLevel WHERE DeveloperName = '%s' LIMIT 1"):format(
			debug_lvl_dev_name_sq_esc
		)
	)
	self._logger:tell_wip("Querying debug level info...")
	req.send(function(debug_lvl_resp) self:_run__fetch_prev_trace_flag(debug_lvl_resp) end)
end
function GetTraceFlags:_run__fetch_prev_trace_flag(debug_lvl_resp)
	local resp = debug_lvl_resp
	assert(resp, "Debug Level query result invalid!")
	assert(resp.done == true, "Query not finished!")
	assert(resp.entityTypeName == "DebugLevel", "Unexpected query result entity!")
	assert(resp.size == 1, "Query result is not 1 record!")
	assert(resp.totalSize == 1, "Query result is not 1 record total!")
	local records = resp.records
	local debug_lvl_record = records[1]
	self._debug_lvl_id = assert(debug_lvl_record.Id)
	--
	local req = CurlReq()
	local auth_info = self._auth_info
	req.set_access_token(auth_info.get_access_token())
	req.set_api_version(auth_info.get_api_version())
	req.set_instance_url(auth_info.get_instance_url())
	req.set_tooling_suburl("/query")
	local debug_lvl_id = assert(self._debug_lvl_id)
	local debug_lvl_id_sq_esc = sq_escape(debug_lvl_id)
	local user_id = assert(self._user_id)
	local user_id_sq_esc = sq_escape(user_id)
	req.set_kv_data(
		"q",
		("SELECT Id, StartDate, ExpirationDate FROM TraceFlag WHERE DebugLevelId = '%s' AND TracedEntityId = '%s' LIMIT 1"):format(
			debug_lvl_id_sq_esc,
			user_id_sq_esc
		)
	)
	self._logger:tell_wip("Querying trace flag...")
	req.send(
		function(prev_trace_flag_response) self:_run__parse_prev_trace_flag(prev_trace_flag_response) end
	)
end
function GetTraceFlags:_run__parse_prev_trace_flag(prev_trace_flag_response)
	self._logger:tell_finished("Queried trace flag.")
	self._on_result(
		GetTraceFlagResult:parse_rest_resp(prev_trace_flag_response, self._user_id, self._debug_lvl_id)
	)
end

function GetTraceFlags:present_async()
	self:run_async(function(result)
		vim.schedule(function()
			local lines = {}
			for idx = 1, result:trace_flags_count() do
				local id = result:trace_flag_id_at(idx)
				local start_dt_ts = result:trace_flag_start_dt_at(idx)
				local start_dt_str = os.date("%d.%m.%Y %H:%M", start_dt_ts)
				local exp_dt_ts = result:trace_flex_exp_dt_at(idx)
				local exp_dt_str = os.date("%d.%m.%Y %H:%M", exp_dt_ts)
				lines[idx] = ("%s: %s -> %s"):format(id, start_dt_str, exp_dt_str)
			end
			vim.ui.select(lines, {}, function() end)
		end)
	end)
end

local EnableTraceFlags = {
	---@type string[]
	_target_org = nil,
	---@type brocade.logging.Logger
	_logger = Logger:get_instance(),
	---@type brocade.org-session.AuthInfo
	_auth_info = nil,
}
EnableTraceFlags.__index = EnableTraceFlags
M.Enable = EnableTraceFlags

function EnableTraceFlags:new()
	local out = setmetatable({}, self)
	return out
end

---@param target_org string
function EnableTraceFlags:set_target_org(target_org) self._target_org = target_org end

function EnableTraceFlags:run_async()
	local fetch_auth_info = FetchAuthInfo:new()
	if self._target_org then fetch_auth_info:set_target_org(self._target_org) end
	self._logger:tell_wip("Fetching auth info...")
	fetch_auth_info:run_async(function(auth_info) self:run__get_trace_flag(auth_info) end)
end
function EnableTraceFlags:run__get_trace_flag(auth_info)
	self._auth_info = auth_info
	local get_trace_flag_async = GetTraceFlags:new()
	if self._target_org then get_trace_flag_async:set_target_org(self._target_org) end
	get_trace_flag_async:run_async(
		function(prev_trace_flag_result) self:run__upsert_trace_flag(prev_trace_flag_result) end
	)
end
---@param prev_trace_flag_result brocade.trace-flag.GetTraceFlag.Result
function EnableTraceFlags:run__upsert_trace_flag(prev_trace_flag_result)
	local user_id = prev_trace_flag_result:user_id()
	local debug_lvl_id = prev_trace_flag_result:debug_level_id()
	local result = prev_trace_flag_result
	if not result then
		self._logger:tell_failed("Failed to query previous trace flag!")
		return
	end
	-- if no existing trace flag, create one; otherwise patch existing
	if result:trace_flags_count() < 1 then
		-- create
		local req = CurlReq()
		req.set_method("POST")
		req.set_access_token(self._auth_info.get_access_token())
		req.set_api_version(self._auth_info.get_api_version())
		req.set_instance_url(self._auth_info.get_instance_url())
		req.set_tooling_suburl("/sobjects/TraceFlag")
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
		self._logger:tell_wip("Creating new trace flag...")
		req.send(function(post_res)
			-- success of sobject create can be inferred from response; simply finish on any response
			if post_res then
				self._logger:tell_finished("Trace flag created.")
			else
				self._logger:tell_failed("Creating trace flag failed!")
			end
		end)
		return
	end
	-- patch existing
	assert(result:trace_flags_count() == 1, "Query result size should be 1 at this point!")
	local prev_trace_flag_url = result:trace_flag_url_at(1)
	assert(prev_trace_flag_url, "Previous Trace Flag URL invalid!")
	local req = CurlReq()
	req.set_access_token(self._auth_info.get_access_token())
	req.set_api_version(self._auth_info.get_api_version())
	req.set_instance_url(self._auth_info.get_instance_url())
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
	self._logger:tell_wip("Updating previous trace flag...")
	req.send(function(patch_res)
		if patch_res then
			self._logger:tell_finished("Trace flag updated.")
		else
			self._logger:tell_failed("Updating trace flag failed!")
		end
	end)
end

return M
