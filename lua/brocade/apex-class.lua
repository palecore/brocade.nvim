local M = {}

-- IMPORTS
local FetchAuthInfo = require("brocade.org-session").FetchAuthInfo
local CurlReq = require("brocade.curl-request").CurlRequest
local Logger = require("brocade.logging").Logger

-- IMPLEMENTATION
local function sq_escape(str) return string.gsub(str, "'", "\\'") end

local Get = {
	_logger = Logger:get_instance(),
	_target_org = nil,
	_auth_info = nil,
	_class_name = nil,
}
Get.__index = Get
M.Get = Get

function Get:new() return setmetatable({}, self) end

function Get:set_target_org(target_org) self._target_org = target_org end
function Get:set_class_name(name) self._class_name = name end

function Get:run_async(cb)
	self._on_result = cb or function() end
	self._logger:tell_wip("Fetching auth info...")
	local fetch_auth_info = FetchAuthInfo:new()
	if self._target_org then fetch_auth_info:set_target_org(self._target_org) end
	fetch_auth_info:run_async(function(auth_info) self:_run__query(auth_info) end)
end

function Get:_run__query(auth_info)
	self._auth_info = assert(auth_info)
	local req = CurlReq:new()
	req:use_auth_info(auth_info)
	req:set_tooling_suburl("/query")
	assert(self._class_name, "Class name or id must be set")
	local q = ("SELECT Id, Name, Body FROM ApexClass WHERE Name = '%s' LIMIT 1"):format(
		sq_escape(self._class_name)
	)
	req:set_kv_data("q", q)
	self._logger:tell_wip("Querying ApexClass...")
	req:send(function(resp) self:_run__parse(resp) end)
end

function Get:_run__parse(resp)
	assert(resp, "ApexClass query result invalid!")
	assert(resp.done == true, "Query not finished!")
	assert(resp.size and resp.size >= 1, "No ApexClass found!")
	local record = resp.records[1]
	local class_id = record.Id
	local class_name = record.Name
	local body = record.Body
	if body and body ~= vim.NIL then
		self._on_result({ id = class_id, name = class_name, body = body })
		return
	end
	-- fallback: fetch body via attributes.url/Body
	local attrs = record.attributes or {}
	local url = attrs.url
	if not url then error("ApexClass body not present and attributes.url missing") end
	local req = CurlReq:new()
	req:use_auth_info(self._auth_info)
	req:set_suburl(url .. "/Body")
	req:set_expect_json(false)
	self._logger:tell_wip("Retrieving the Apex class...")
	req:send(
		function(body_str) self._on_result({ id = class_id, name = class_name, body = body_str }) end
	)
end

function Get:load_this_buf_async()
	local file_path = vim.api.nvim_buf_get_name(0)
	if not file_path or file_path == "" then error("Buffer has no filename") end
	local class_name = string.match(file_path, "([^/]+)%.cls$")
		or string.match(file_path, "([^/]+)%.cls%-meta%.xml$")
	if not class_name or not string.find(file_path, "force%-app/main/default/classes/") then
		error("Current buffer is not an Apex class in force-app/main/default/classes")
	end
	-- Resolve the target .cls buffer to write retrieved source into:
	local cls_path = file_path:match("%.cls%-meta%.xml$")
		and file_path:gsub("%.cls%-meta%.xml$", ".cls")
		or file_path
	self:set_class_name(class_name)
	self:run_async(vim.schedule_wrap(function(resp)
		resp = resp or {}
		local body = resp.body
		if not body then error("Apex class body missing") end
		local cls_buf = vim.fn.bufadd(cls_path)
		vim.fn.bufload(cls_buf)
		vim.api.nvim_buf_set_lines(cls_buf, 0, -1, true, vim.split(body, "\n"))
		-- SF CLI typically retrieves Apex classes without a final EOL:
		vim.api.nvim_set_option_value("endofline", false, { buf = cls_buf })
		vim.api.nvim_set_option_value("fixendofline", false, { buf = cls_buf })
		vim.api.nvim_buf_call(cls_buf, function()
			vim.api.nvim_cmd({ cmd = "write" }, {})
		end)
		self._logger:tell_finished("Retrieved the Apex class.")
	end))
end

return M
