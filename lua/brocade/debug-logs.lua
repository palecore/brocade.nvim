local M = {}

-- IMPORTS
local FetchAuthInfo = require("brocade.org-session").FetchAuthInfo
local CurlReq = require("brocade.curl-request").CurlRequest
local Logger = require("brocade.logging").Logger

-- IMPLEMENTATION
local function sq_escape(str) return string.gsub(str, "'", "\\'") end

local GetApexLogs = {
	_logger = Logger:get_instance(),
	_target_org = nil,
	_auth_info = nil,
	_limit = 10,
}
GetApexLogs.__index = GetApexLogs
M.Get = GetApexLogs

local function parse_sf_datetime(dt_str)
	-- NOTE: Needs vim.fn.schedule() if used from async callbacks
	return vim.fn.strptime("%Y-%m-%dT%X.%S%Z", dt_str)
end

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
	return parse_sf_datetime(r._start_dt_str)
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

function GetApexLogs:run_async(cb)
	self._on_result = cb or function() end
	self._logger:tell_wip("Fetching auth info...")
	local fetch_auth_info = FetchAuthInfo:new()
	if self._target_org then fetch_auth_info:set_target_org(self._target_org) end
	fetch_auth_info:run_async(function(auth_info) self:_run__query_logs(auth_info) end)
end

function GetApexLogs:_run__query_logs(auth_info)
	self._auth_info = assert(auth_info)
	local req = CurlReq:new()
	req:use_auth_info(auth_info)
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
	req:send(function(resp) self:_run__parse_logs(resp) end)
end

function GetApexLogs:_run__parse_logs(resp)
	self._logger:tell_finished("Queried ApexLog entries.")
	self._on_result(LogsResult:parse_rest_resp(resp))
end

function GetApexLogs:present_async()
	self:run_async(function(result)
		vim.schedule(function()
			local lines = {}
			for idx = 1, result:count() do
				local id = result:id_at(idx)
				local start_ts = result:start_dt_at(idx)
				local start_str = start_ts and os.date("%d.%m.%Y %H:%M", start_ts) or "?"
				local op = result:operation_at(idx) or "?"
				local status = result:status_at(idx) or "?"
				local user = result:user_at(idx) or "?"
				lines[idx] = ("%s\t%s\t%s\t%s\t%s"):format(id, status, start_str, op, user)
			end
			vim.ui.select(lines, { prompt = "Select Apex log:" }, function(_, idx)
				if not idx then return end
				local url = result:url_at(idx)
				local log_id = result:id_at(idx)
				if not url then
					vim.notify("Selected log has no URL", vim.log.levels.ERROR)
					return
				end
				-- fetch body
				local req = CurlReq:new()
				req:use_auth_info(self._auth_info)
				-- attributes.url typically is something like
				-- /services/data/vXX.X/tooling/sobjects/ApexLog/<Id> append /Body to
				-- get raw log text
				req:set_suburl(url .. "/Body")
				req:set_expect_json(false)
				self._logger:tell_wip("Fetching log body...")
				req:send(function(body)
					vim.schedule(function()
						-- write the full log to the project .sfdx/tools/debug/logs
						-- directory using the log ID as basename:
						local project_root_dir = vim.fs.root(".", { "sfdx-project.json", ".sf", ".sfdx" })
						local log_dir = vim.fs.joinpath(project_root_dir, ".sfdx", "tools", "debug", "logs")
						local log_path = vim.fs.joinpath(log_dir, (log_id or "") .. ".log")
						local body_lines = vim.split(body or "", "\n")
						assert(vim.fn.mkdir(log_dir, "p") ~= 0, "Creating log dir failed!")
						assert(vim.fn.writefile(body_lines, log_path, "s") == 0)
						-- open the log file:
						vim.api.nvim_cmd({ cmd = "split", args = { log_path } }, {})
						vim.api.nvim_set_option_value("filetype", "sflog", { buf = 0 })
						self._logger:tell_finished("Fetched log " .. (log_id or ""))
					end)
				end)
			end)
		end)
	end)
end

return M
