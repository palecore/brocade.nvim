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
	-- must be a .cls file inside force-app/main/default/classes
	local class_name = string.match(file_path, "([^/]+)%.cls$")
	if not class_name or not string.find(file_path, "force%-app/main/default/classes/") then
		error("Current buffer is not an Apex class in force-app/main/default/classes")
	end
	self:set_class_name(class_name)
	self:run_async(vim.schedule_wrap(function(resp)
		resp = resp or {}
		local body = resp.body
		if not body then error("Apex class body missing") end
		--
		vim.api.nvim_buf_set_lines(0, 0, -1, true, vim.split(body, "\n"))
		-- SF CLI typically retrieves Apex classes without a final EOL:
		vim.api.nvim_set_option_value("endofline", false, { buf = 0 })
		vim.api.nvim_set_option_value("fixendofline", false, { buf = 0 })
		-- save the buffer:
		vim.api.nvim_cmd({ cmd = "write" }, {})
		--
		self._logger:tell_finished("Retrieved the Apex class.")
	end))
end

---@type number ContainerAsyncRequest status polling duration.
local CAR_POLL_DURATION_MS = 250

local Deploy = {
	_logger = Logger:get_instance(),
	_target_org = nil,
	_auth_info = nil,
	_class_name = nil,
	_class_body = nil,
}
Deploy.__index = Deploy
M.Deploy = Deploy

function Deploy:new() return setmetatable({}, self) end
function Deploy:set_target_org(target_org) self._target_org = target_org end
function Deploy:set_class_name(name) self._class_name = name end
function Deploy:set_class_body(body) self._class_body = body end

function Deploy:run_async(cb)
	self._on_result = cb or function() end
	self._logger:tell_wip("Fetching auth info...")
	local fetch_auth_info = FetchAuthInfo:new()
	if self._target_org then fetch_auth_info:set_target_org(self._target_org) end
	fetch_auth_info:run_async(function(auth_info) self:_run__query(auth_info) end)
end

function Deploy:_run__query(auth_info)
	self._auth_info = assert(auth_info)
	local req = CurlReq:new()
	req:use_auth_info(auth_info)
	req:set_tooling_suburl("/query")
	assert(self._class_name, "Class name must be set")
	local q = ("SELECT Id FROM ApexClass WHERE Name = '%s' LIMIT 1"):format(
		sq_escape(self._class_name)
	)
	req:set_kv_data("q", q)
	self._logger:tell_wip("Querying the Apex class...")
	req:send(function(resp) self:_run__post_or_put_class(resp) end)
end

function Deploy:_run__post_or_put_class(resp)
	self._existing_id = nil
	assert(resp, "ApexClass query result invalid!")
	assert(resp.done == true, "Query not finished!")
	local exists = resp.size and resp.size >= 1
	if exists then
		local record = resp.records[1]
		self._existing_id = record.Id
	end
	assert(self._class_body ~= nil, "Class body must be set for deploy")
	-- 1) create MetadataContainer
	local req = CurlReq:new()
	req:use_auth_info(self._auth_info)
	req:set_tooling_suburl("/sobjects/MetadataContainer")
	req:set_method("POST")
	-- NOTE: Metadata Container name can have at most 32 characters:
	local container_name = self._class_name:sub(1, 32)
	req:set_json_data(vim.json.encode({ Name = container_name }))
	self._logger:tell_wip("Preparing deployment...")
	req:send(function(container) self:_run__container_created(container) end)
end

function Deploy:_run__container_created(container)
	assert(container and container.id, "MetadataContainer creation failed")
	self._container_id = container.id
	-- 2) create ApexClassMember
	local member_req = CurlReq:new()
	member_req:use_auth_info(self._auth_info)
	member_req:set_tooling_suburl("/sobjects/ApexClassMember")
	member_req:set_method("POST")
	local member_body = {
		MetadataContainerId = self._container_id,
		Body = self._class_body,
		FullName = self._class_name,
	}
	if self._existing_id then member_body.ContentEntityId = self._existing_id end
	member_req:set_json_data(vim.json.encode(member_body))
	self._logger:tell_wip("Attaching Apex class to the deployment...")
	member_req:send(function(member) self:_run__member_created(member) end)
end

function Deploy:_run__member_created(member)
	assert(member and member.id, "ApexClassMember creation failed")
	self._member_id = member.id
	-- 3) submit ContainerAsyncRequest
	local car_req = CurlReq:new()
	car_req:use_auth_info(self._auth_info)
	car_req:set_tooling_suburl("/sobjects/ContainerAsyncRequest")
	car_req:set_method("POST")
	car_req:set_json_data(
		vim.json.encode({ IsCheckOnly = false, MetadataContainerId = self._container_id })
	)
	self._logger:tell_wip("Submitting deployment...")
	car_req:send(function(car) self:_run__car_created(car) end)
end

function Deploy:_run__car_created(car)
	assert(car and car.id, "ContainerAsyncRequest creation failed")
	self._car_id = car.id
	self._logger:tell_wip("Polling deployment status...")
	self:_run__poll()
end

function Deploy:_run__poll()
	local status_req = CurlReq:new()
	status_req:use_auth_info(self._auth_info)
	status_req:set_tooling_suburl("/sobjects/ContainerAsyncRequest/" .. self._car_id)
	status_req:send(function(status) self:_run__handle_status(status) end)
end

function Deploy:_run__handle_status(status)
	local state = status and status.State
	if state == "Queued" or state == "InProgress" then
		vim.defer_fn(function() self:_run__poll() end, CAR_POLL_DURATION_MS)
		return
	end
	local function do_cleanup(cb)
		local del = CurlReq:new()
		del:use_auth_info(self._auth_info)
		del:set_tooling_suburl("/sobjects/MetadataContainer/" .. self._container_id)
		del:set_method("DELETE")
		del:set_expect_json(false)
		self._logger:tell_wip("Cleaning up deployment...")
		del:send(cb)
	end
	if state == "Failed" then
		do_cleanup(function() self._logger:tell_failed(status.ErrorMsg or "Deployment failed!") end)
		return
	end
	if state == "Completed" then
		do_cleanup(function()
			self._logger:tell_finished("Apex class deployed.")
			self._on_result({
				action = self._existing_id and "update" or "create",
				id = self._existing_id or self._member_id,
				result = status,
			})
		end)
		return
	end
end

function Deploy:run_on_this_buf_async()
	local file_path = vim.api.nvim_buf_get_name(0)
	if not file_path or file_path == "" then error("Buffer has no filename") end
	-- must be a .cls file inside force-app/main/default/classes
	local class_name = string.match(file_path, "([^/]+)%.cls$")
	if not class_name or not string.find(file_path, "force%-app/main/default/classes/") then
		error("Current buffer is not an Apex class in force-app/main/default/classes")
	end
	self:set_class_name(class_name)
	local lines
	if vim.fn.filereadable(file_path) == 1 then
		lines = vim.fn.readfile(file_path)
	else
		lines = vim.api.nvim_buf_get_lines(0, 0, -1, true)
	end
	-- TODO respect fileformat and thus EOL characters
	local body = table.concat(lines, "\n")
	self:set_class_body(body)
	self:run_async()
end

return M
