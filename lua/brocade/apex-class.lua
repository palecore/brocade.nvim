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
	-- Use composite resource to create MetadataContainer, ApexClassMember and ContainerAsyncRequest in one call
	local api_v = tostring(self._auth_info.get_api_version())
	local base_service = "/services/data/v" .. api_v .. "/tooling"
	-- NOTE: Metadata Container name can have at most 32 characters:
	local container_name = self._class_name:sub(1, 32)
	local member_body = {
		MetadataContainerId = "@{metadatacontainer_reference_id.id}",
		Body = self._class_body,
		FullName = self._class_name,
	}
	if self._existing_id then member_body.ContentEntityId = self._existing_id end
	local composite = {
		allOrNone = false,
		compositeRequest = {
			{
				method = "POST",
				body = { Name = container_name },
				url = base_service .. "/sobjects/MetadataContainer/",
				referenceId = "metadatacontainer_reference_id",
			},
			{
				method = "POST",
				body = member_body,
				url = base_service .. "/sobjects/ApexClassMember/",
				referenceId = "apexclassmember_reference_id",
			},
			{
				method = "POST",
				body = { IsCheckOnly = false, MetadataContainerId = "@{metadatacontainer_reference_id.id}" },
				url = base_service .. "/sobjects/ContainerAsyncRequest/",
				referenceId = "containerasyncrequest_reference_id",
			},
		},
	}
	local req = CurlReq:new()
	req:use_auth_info(self._auth_info)
	req:set_tooling_suburl("/composite")
	req:set_method("POST")
	req:set_json_data(vim.json.encode(composite))
	self._logger:tell_wip("Submitting deployment...")
	req:send(function(composite_resp) self:_run__start_polling_car(composite_resp) end)
end

function Deploy:_run__start_polling_car(composite_resp)
	assert(composite_resp and composite_resp.compositeResponse, "Composite response invalid")
	-- parse compositeResponse entries to extract created ids
	for _, entry in ipairs(composite_resp.compositeResponse) do
		if entry.referenceId == "metadatacontainer_reference_id" then
			if entry.body and entry.body.id then self._container_id = entry.body.id end
		end
		if entry.referenceId == "apexclassmember_reference_id" then
			if entry.body and entry.body.id then self._member_id = entry.body.id end
		end
		if entry.referenceId == "containerasyncrequest_reference_id" then
			if entry.body and entry.body.id then self._car_id = entry.body.id end
		end
	end
	if not self._car_id then
		local errors = {}
		for _, entry in ipairs(composite_resp.compositeResponse) do
			if type(entry.body) == "table" then
				for _, err in ipairs(entry.body) do
					if err and err.message then
						table.insert(errors, (err.errorCode or "") .. ": " .. err.message)
					end
				end
			end
		end
		if #errors > 0 then
			self._logger:tell_failed("There were compilation failures: " .. table.concat(errors, "\n"))
		end
		local container_name = self._class_name and self._class_name:sub(1, 32) or nil
		if container_name then
			self:_cleanup_metadata_container_and_retry(container_name)
		else
			self._logger:tell_failed(
				"Deployment aborted: ContainerAsyncRequest could not be created and container name is unknown!"
			)
		end
		return
	end
	self._logger:tell_wip("Polling deployment status...")
	self:_run__poll_car()
end

-- Internal: Clean up MetadataContainer by name and retry deployment
function Deploy:_cleanup_metadata_container_and_retry(container_name)
	local api_v = tostring(self._auth_info.get_api_version())
	local base_service = "/services/data/v" .. api_v .. "/tooling"
	local q = ("SELECT Id FROM MetadataContainer WHERE Name = '%s' LIMIT 1"):format(
		sq_escape(container_name)
	)
	local composite = {
		allOrNone = false,
		compositeRequest = {
			{
				method = "GET",
				url = base_service .. "/query/?q=" .. q,
				referenceId = "query_metadatacontainer_reference_id",
			},
		},
	}
	local req = CurlReq:new()
	req:use_auth_info(self._auth_info)
	req:set_tooling_suburl("/composite")
	req:set_method("POST")
	req:set_json_data(vim.json.encode(composite))
	self._logger:tell_wip("Querying for existing MetadataContainer to clean up...")
	req:send(
		function(resp) self:_handle_metadata_container_query_and_delete(resp, container_name) end
	)
end

function Deploy:_handle_metadata_container_query_and_delete(resp, container_name)
	if not resp or not resp.compositeResponse then
		self._logger:tell_failed("Failed to query for MetadataContainer during cleanup!")
		return
	end
	local query_entry = nil
	for _, entry in ipairs(resp.compositeResponse) do
		if entry.referenceId == "query_metadatacontainer_reference_id" then
			query_entry = entry
			break
		end
	end
	if
		not query_entry
		or not query_entry.body
		or not query_entry.body.records
		or #query_entry.body.records == 0
	then
		self._logger:tell_failed("No MetadataContainer found to clean up for name: " .. container_name)
		return
	end
	local container_id = query_entry.body.records[1].Id
	if not container_id then
		self._logger:tell_failed("MetadataContainer ID missing in query result!")
		return
	end
	local del = CurlReq:new()
	del:use_auth_info(self._auth_info)
	del:set_tooling_suburl("/sobjects/MetadataContainer/" .. container_id)
	del:set_method("DELETE")
	del:set_expect_json(false)
	self._logger:tell_wip("Deleting MetadataContainer " .. container_id .. "...")
	del:send(function(delete_resp)
		if delete_resp == nil or delete_resp == "" then
			self._logger:tell_finished("MetadataContainer cleaned up. Retrying deployment...")
			self:_run__post_or_put_class({
				done = true,
				size = self._existing_id and 1 or 0,
				records = self._existing_id and { { Id = self._existing_id } } or {},
			})
		else
			self._logger:tell_failed("Failed to delete MetadataContainer: " .. tostring(delete_resp))
		end
	end)
end

function Deploy:_run__poll_car()
	local status_req = CurlReq:new()
	status_req:use_auth_info(self._auth_info)
	status_req:set_tooling_suburl("/sobjects/ContainerAsyncRequest/" .. self._car_id)
	status_req:send(function(status) self:_run__handle_status(status) end)
end

function Deploy:_run__handle_status(status)
	local state = status and status.State
	if state == "Queued" or state == "InProgress" then
		vim.defer_fn(function() self:_run__poll_car() end, CAR_POLL_DURATION_MS)
		return
	end

	local function show_component_failures()
		local failures = status and status.DeployDetails and status.DeployDetails.componentFailures
		if not failures or type(failures) ~= "table" then return end
		local class_name = self._class_name
		if not class_name then return end
		-- Find buffer for this class
		local match_buf = nil
		local match_file = nil
		for _, buf in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_loaded(buf) then
				local name = vim.api.nvim_buf_get_name(buf)
				local fname = name:match("([^/]+)%.cls$")
				if fname and fname == class_name then
					match_buf = buf
					match_file = name
					break
				end
			end
		end
		if not match_buf then return end
		local diagnostics = {}
		for _, failure in ipairs(failures) do
			local fileName = failure.fileName or ""
			local fname = fileName:match("([^/]+)%.cls$")
			if fname == class_name then
				local lnum = (failure.lineNumber or 1) - 1
				local col = (failure.columnNumber or 1) - 1
				local msg = failure.problem or "Deployment error"
				table.insert(diagnostics, {
					lnum = lnum,
					col = col,
					message = msg,
					severity = vim.diagnostic.severity.ERROR,
				})
			end
		end
		if #diagnostics > 0 then
			local ns = vim.api.nvim_create_namespace("brocade-apex-deploy")
			vim.diagnostic.set(ns, match_buf, diagnostics)
			vim.api.nvim_create_autocmd({ "BufRead", "BufWrite" }, {
				buffer = match_buf,
				once = true,
				callback = function() vim.diagnostic.reset(ns, match_buf) end,
			})
		end
	end

	if state == "Failed" then
		self:_run__cleanup(vim.schedule_wrap(function()
			show_component_failures()
			self._logger:tell_failed(status.ErrorMsg or "Deployment failed!")
		end))
		return
	end
	if state == "Completed" then
		self:_run__cleanup(function()
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

function Deploy:_run__cleanup(cb)
	local del = CurlReq:new()
	del:use_auth_info(self._auth_info)
	del:set_tooling_suburl("/sobjects/MetadataContainer/" .. self._container_id)
	del:set_method("DELETE")
	del:set_expect_json(false)
	self._logger:tell_wip("Cleaning up deployment...")
	del:send(cb)
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
