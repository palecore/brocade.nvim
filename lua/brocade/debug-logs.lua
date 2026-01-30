local M = {}

-- IMPORTS
local a = require("plenary.async")

-- helper to call Vimscript functions asynchronously:
local a_fn = setmetatable({}, {
	__index = function(_, k)
		return function(...) return a.api.nvim_call_function(k, { ... }) end
	end,
})

local FetchAuthInfo = require("brocade.org-session").FetchAuthInfo
local CurlReq = require("brocade.curl-request").CurlRequest
local Logger = require("brocade.logging").Logger

-- IMPLEMENTATION

local GetApexLogs = {
	_logger = Logger:get_instance(),
	_target_org = nil,
	_auth_info = nil,
	_limit = 10,
}
GetApexLogs.__index = GetApexLogs
M.Get = GetApexLogs

local LogsResult = {
	_payload = nil,
	_size = nil,
	_records = nil,
}
LogsResult.__index = LogsResult
GetApexLogs.Result = LogsResult

function LogsResult:count() return self._size end
function LogsResult:id_at(idx)
	local r = self._records[idx]
	if not r then return nil end
	return r._id
end
function LogsResult:url_at(idx)
	local r = self._records[idx]
	if not r then return nil end
	return r._url
end
function LogsResult:start_dt_at(idx)
	local r = self._records[idx]
	if not r then return nil end
	return vim.fn.strptime("%Y-%m-%dT%X.%S%Z", r._start_dt_str)
end
---@async
function LogsResult:start_dt_at_async(idx)
	local r = self._records[idx]
	if not r then return nil end
	return a_fn.strptime("%Y-%m-%dT%X.%S%Z", r._start_dt_str)
end
function LogsResult:operation_at(idx)
	local r = self._records[idx]
	if not r then return nil end
	return r._operation
end
function LogsResult:status_at(idx)
	local r = self._records[idx]
	if not r then return nil end
	return r._status
end
function LogsResult:user_at(idx)
	local r = self._records[idx]
	if not r then return nil end
	return r._user_name
end

function LogsResult:parse_rest_resp(rest_response)
	local out = setmetatable({}, self)
	local resp = rest_response
	assert(resp, "ApexLog query result invalid!")
	assert(resp.done == true, "Query not finished!")
	assert(resp.entityTypeName == "ApexLog", "Unexpected query return type!")
	assert(resp.size ~= nil, "No query result size given!")
	assert(resp.records, "No query records given!")
	out._payload = resp
	out._size = resp.size
	out._records = {}
	for idx, record in ipairs(resp.records) do
		out._records[idx] = {
			_id = record.Id,
			_url = record.attributes and record.attributes.url or ("/sobjects/ApexLog/" .. record.Id),
			_start_dt_str = record.StartTime,
			_operation = record.Operation,
			_status = record.Status,
			_user_name = (record.LogUser and record.LogUser.Name) or nil,
		}
	end
	return out
end

function GetApexLogs:new() return setmetatable({}, self) end

function GetApexLogs:set_target_org(target_org) self._target_org = target_org end
function GetApexLogs:set_limit(n) self._limit = n end

---@async if `cb` is not provided
---@param cb? function Deprecated. If not provided, this is run in plenary async context.
function GetApexLogs:run_async(cb)
	-- handle legacy callback-style invocation;
	if cb then
		return a.run(function() return self:run_async() end, cb)
	end
	-- the rest runs in plenary async context

	self._logger:tell_wip("Fetching auth info...")
	local fetch_auth_info = FetchAuthInfo:new()
	if self._target_org then fetch_auth_info:set_target_org(self._target_org) end
	self._auth_info = fetch_auth_info:run_async()

	local req = CurlReq:new()
	req:use_auth_info(self._auth_info)
	req:set_tooling_suburl("/query")
	local limit = assert(self._limit)
	local q = table
		.concat({
			"SELECT",
			"Id, LogLength, Location, Operation, StartTime, Status, LogUser.Name",
			"FROM ApexLog",
			"ORDER BY StartTime DESC",
			"LIMIT %d",
		}, " ")
		:format(limit)
	req:set_kv_data("q", q)
	self._logger:tell_wip("Querying ApexLog entries...")
	local resp = req:send_async()
	self._logger:tell_finished("Queried ApexLog entries.")
	return LogsResult:parse_rest_resp(resp)
end

---@async Optionally - will step into plenary async context if called outside it.
function GetApexLogs:present_async()
	-- handle legacy fire-and-forget invocation in sync context:
	if not coroutine.running() then
		return a.void(function() return self:present_async() end)()
	end
	-- the rest runs in plenary async context:
	local result = assert(self:run_async())
	local lines = {}
	for idx = 1, result:count() do
		local id = result:id_at(idx)
		local start_ts = result:start_dt_at_async(idx)
		local start_str = start_ts and os.date("%d.%m.%Y %H:%M", start_ts) or "?"
		local op = result:operation_at(idx) or "?"
		local status = result:status_at(idx) or "?"
		local user = result:user_at(idx) or "?"
		lines[idx] = ("%s\t%s\t%s\t%s\t%s"):format(id, status, start_str, op, user)
	end

	local selection = a.wrap(function(_cb)
		vim.ui.select(
			lines,
			{ prompt = "Select Apex log:" },
			function(item, idx) _cb({ item = item, idx = idx }) end
		)
	end, 1)()
	if not selection or not selection.idx then return end

	local idx = selection.idx
	local url = result:url_at(idx)
	local log_id = result:id_at(idx)
	if not url then
		self._logger:tell_failed("The selected log has no URL!")
		return
	end

	local req = CurlReq:new()
	req:use_auth_info(self._auth_info)
	req:set_suburl(url .. "/Body")
	req:set_expect_json(false)
	self._logger:tell_wip("Fetching log body...")
	local body = req:send_async()

	local project_root_dir = vim.fs.root(".", { "sfdx-project.json", ".sf", ".sfdx" })
	local log_dir = vim.fs.joinpath(project_root_dir, ".sfdx", "tools", "debug", "logs")
	local log_path = vim.fs.joinpath(log_dir, (log_id or "") .. ".log")
	local body_lines = vim.split(body or "", "\n")
	assert(a_fn.mkdir(log_dir, "p") ~= 0, "Creating log dir failed!")
	assert(a_fn.writefile(body_lines, log_path, "s") == 0, "Writing log file failed!")
	a.api.nvim_cmd({ cmd = "split", args = { log_path } }, {})
	a.api.nvim_set_option_value("filetype", "sflog", { buf = 0 })
	self._logger:tell_finished("Fetched log " .. (log_id or ""))
end

return M
