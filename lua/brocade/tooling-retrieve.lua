--- Salesforce metadata retrieval through Tooling API.
local M = {}

-- IMPORTS
local a = require("plenary.async")
local CurlReq = require("brocade.curl-request").CurlRequest
local FetchAuthInfo = require("brocade.org-session").FetchAuthInfo
local Logger = require("brocade.logging").Logger

-- helper to call Vimscript functions asynchronously:
local a_fn = setmetatable({}, {
	__index = function(_, k)
		return function(...) return a.api.nvim_call_function(k, { ... }) end
	end,
})

local function _extract_metadata_type_from_xml(meta_file_path)
	if a_fn.filereadable(meta_file_path) ~= 1 then
		return nil
	end

	-- Read first few lines to find the root XML element
	local lines = a_fn.readfile(meta_file_path, "", 10)
	if not lines or #lines == 0 then
		return nil
	end

	-- Skip XML declaration and find the first opening tag
	for i = 1, #lines do
		local line = lines[i]
		-- Skip XML declarations and comments
		if not line:match("^%s*<%?xml") and not line:match("^%s*<!%-%-") then
			-- Look for opening tag: <TagName or <TagName>
			local tag_name = line:match("^%s*<([%w_]+)")
			if tag_name then
				return tag_name
			end
		end
	end

	return nil
end

---Get the project root directory
---@return string? root_dir
local function get_project_root()
	local markers = { "sfdx-project.json", ".sf", ".sfdx" }
	return vim.fs.root(0, markers)
end

local function parse_metadata_component(file_path)
	local project_root = get_project_root()
	if not project_root then return nil, nil, nil end

	-- Normalize path relative to force-app/main/default
	-- TODO returns objects/ for a field (should be objects/*/fields/)
	local rel_path = file_path:gsub("^" .. vim.pesc(project_root) .. "/", "")
	local force_app_pattern = "force%-app/main/default/([^/]+)/(.+)$"
	local dir_type, rest = rel_path:match(force_app_pattern)

	if not dir_type then return nil, nil, nil end

	local file_name = vim.fs.basename(file_path)
	local meta_file_path
	local payload_file_path
	local component_name

	-- Check if current file ends with -meta.xml
	if vim.endswith(file_name, "-meta.xml") then
		-- This IS the meta file
		meta_file_path = file_path
		-- Extract component name (remove -meta.xml suffix)
		component_name = file_name:sub(1, -(#"-meta.xml" + 1))

		-- Check if there's a payload file (component_name without any extension)
		-- Try to find a file with the same base name but different extension
		local dir_path = vim.fs.dirname(file_path)
		local base_name_pattern = "^" .. vim.pesc(component_name) .. "$"

		-- Check if payload exists by trying common pattern: removing everything after first dot
		local base_without_ext = component_name:match("^([^%.]+)")
		if base_without_ext then
			local potential_payload = vim.fs.joinpath(dir_path, base_without_ext)
			-- Look for files starting with base name
			for name, type in vim.fs.dir(dir_path) do
				if type == "file" and name ~= file_name then
					-- Check if this file matches the base pattern (e.g., MyClass.cls for MyClass.cls-meta.xml)
					if name == component_name then
						payload_file_path = vim.fs.joinpath(dir_path, name)
						break
					end
				end
			end
		end
	else
		-- This is NOT a meta file, check if there's a neighboring -meta.xml file
		meta_file_path = file_path .. "-meta.xml"

		if a_fn.filereadable(meta_file_path) ~= 1 then
			-- No meta file found
			return nil, nil, nil
		end

		-- This is the payload file
		payload_file_path = file_path
		-- Component name is the full filename
		component_name = file_name
	end

	-- Extract metadata type from the meta XML file
	local metadata_type = _extract_metadata_type_from_xml(meta_file_path)
	if not metadata_type then return nil, nil, nil end

	-- Build the list of files to include in deployment
	local files = {}

	-- Always include the meta file
	local meta_rel_path = vim.fs.joinpath(dir_type, vim.fs.basename(meta_file_path))
	table.insert(files, meta_rel_path)

	-- Include payload file if it exists
	if payload_file_path then
		local payload_rel_path = vim.fs.joinpath(dir_type, vim.fs.basename(payload_file_path))
		table.insert(files, payload_rel_path)
	end

	-- component name is the base name without extension:
	if component_name:find("%.") then component_name = component_name:match("^([^%.]+)") end

	return metadata_type, component_name, files
end

---@class ToolingRetrieve
local Retrieve = {
	_logger = Logger:get_instance(),
	_target_org = nil,
	_auth_info = nil,
	_metadata_type = nil,
	_component_name = nil,
}
Retrieve.__index = Retrieve
M.Retrieve = Retrieve

function Retrieve:new() return setmetatable({}, self) end

function Retrieve:set_target_org(target_org) self._target_org = target_org end

function Retrieve:set_component(metadata_type, component_name)
	self._metadata_type = metadata_type
	self._component_name = component_name
end

---@async
function Retrieve:run_async()
	self._logger:tell_wip("Fetching auth info...")
	local fetch_auth_info = FetchAuthInfo:new()
	if self._target_org then fetch_auth_info:set_target_org(self._target_org) end
	---@type brocade.org-session.AuthInfo
	self._auth_info = fetch_auth_info:run_async()
	assert(self._auth_info)

	assert(self._metadata_type, "Metadata type must be set")
	assert(self._component_name, "Component name must be set")

	self._logger:tell_wip("Querying for " .. self._component_name .. "...")

	-- local q = ("SELECT Id FROM %s WHERE DeveloperName = '%s' OR Name = '%s' LIMIT 1"):format(
	local q = ("SELECT Id FROM %s WHERE Name = '%s' LIMIT 1"):format(
		self._metadata_type,
		self._component_name,
		self._component_name
	)

	local query_req = CurlReq:new()
	query_req:use_auth_info(self._auth_info)
	query_req:set_tooling_suburl("/query")
	query_req:set_kv_data("q", q)

	local resp = query_req:send_async()
	assert(resp, "SOQL query for component failed")
	assert(resp.records and #resp.records > 0, "Component not found in target org")

	local component_id = resp.records[1].Id
	local api_v = tostring(self._auth_info.get_api_version())
	local suburl = ("/services/data/v%s/tooling/sobjects/%s/%s"):format(
		api_v,
		self._metadata_type,
		component_id
	)

	self._logger:tell_wip("Retrieving component definition...")
	local body_req = CurlReq:new()
	body_req:use_auth_info(self._auth_info)
	body_req:set_suburl(suburl)
	body_req:with_expecting_xml_response()

	local body = body_req:send_async()
	assert(body, "Failed to retrieve component definition")

	return {
		id = component_id,
		name = self._component_name,
		body = body,
	}
end

---@async
function Retrieve:run_on_this_buf_async()
	local file_path = vim.api.nvim_buf_get_name(0)
	if not file_path or file_path == "" then error("Buffer has no filename") end

	local metadata_type, component_name, _ = parse_metadata_component(file_path)
	if not metadata_type then
		error("Current buffer is not a recognized Salesforce metadata component")
	end

	self:set_component(metadata_type, assert(component_name, "Component name is null!"))

	local result = self:run_async()

	if result and result.body then
		vim.schedule(function()
			vim.api.nvim_buf_set_lines(0, 0, -1, true, vim.split(result.body, "\n"))
			vim.api.nvim_set_option_value("endofline", false, { buf = 0 })
			vim.api.nvim_set_option_value("fixendofline", false, { buf = 0 })
			vim.api.nvim_cmd({ cmd = "write" }, {})
			self._logger:tell_finished("Retrieved " .. component_name)
		end)
	else
		self._logger:tell_failed("Failed to retrieve component.")
	end
end

return M
