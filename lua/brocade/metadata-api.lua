-- Salesforce metadata deployment and retrieval through Metadata API.
local M = {}

-- CAUTION: This module is in early development stage  and may contain bugs or
-- incomplete features. Use with caution and report any issues you encounter.

-- IMPORTS
local a = require("plenary.async")
local CurlReq = require("brocade.curl-request").CurlRequest
local FetchAuthInfo = require("brocade.org-session").FetchAuthInfo
local Logger = require("brocade.logging").Logger
local buf_diagnostics = require("brocade.diagnostics")

-- helper to call Vimscript functions asynchronously:
local a_fn = setmetatable({}, {
	__index = function(_, k)
		return function(...) return a.api.nvim_call_function(k, { ... }) end
	end,
})

-- IMPLEMENTATION

---@type number Metadata deployment status polling duration.
local DEPLOY_POLL_DURATION_MS = 500

---Generate package.xml content for given metadata components
---@param metadata_type string The metadata type (e.g. "ApexClass")
---@param members table List of member names
---@param api_version string API version
---@return string package_xml The generated package.xml content
local function generate_package_xml(metadata_type, members, api_version)
	local lines = {
		'<?xml version="1.0" encoding="UTF-8"?>',
		'<Package xmlns="http://soap.sforce.com/2006/04/metadata">',
		"<types>",
	}
	for _, member in ipairs(members) do
		table.insert(lines, "<members>" .. member .. "</members>")
	end
	table.insert(lines, "<name>" .. metadata_type .. "</name>")
	table.insert(lines, "</types>")
	table.insert(lines, "<version>" .. api_version .. "</version>")
	table.insert(lines, "</Package>")
	return table.concat(lines, "\n")
end

---Create a ZIP file from source files
---@param temp_dir string Temporary directory containing files to zip
---@param zip_name string Name of the zip file to create
---@return boolean success
---@return string? error_msg
local function create_zip(temp_dir, zip_name)
	local cmd = { "zip", "-r", "-q", zip_name, "." }
	local result = vim.system(cmd, { cwd = temp_dir }):wait()
	if result.code ~= 0 then
		return false, "Failed to create ZIP: " .. (result.stderr or result.stdout or "")
	end
	return true, nil
end

---Get the project root directory
---@return string? root_dir
local function get_project_root()
	local markers = { "sfdx-project.json", ".sf", ".sfdx" }
	return vim.fs.root(0, markers)
end

---Extract metadata type from XML meta file by reading the root element tag
---@param meta_file_path string Full path to the -meta.xml file
---@return string? metadata_type The metadata type extracted from XML root element
local function _extract_metadata_type_from_xml(meta_file_path)
	if a_fn.filereadable(meta_file_path) ~= 1 then return nil end

	-- Read first few lines to find the root XML element
	local lines = a_fn.readfile(meta_file_path, "", 10)
	if not lines or #lines == 0 then return nil end

	-- Skip XML declaration and find the first opening tag
	for i = 1, #lines do
		local line = lines[i]
		-- Skip XML declarations and comments
		if not line:match("^%s*<%?xml") and not line:match("^%s*<!%-%-") then
			-- Look for opening tag: <TagName or <TagName>
			local tag_name = line:match("^%s*<([%w_]+)")
			if tag_name then return tag_name end
		end
	end

	return nil
end

---Parse a file path to extract metadata type and component name
---@param file_path string Full path to the metadata file
---@return string? metadata_type
---@return string? component_name
---@return table? files List of files to include (relative to force-app/main/default)
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

-- DEPLOY CLASS

local Deploy = {
	_logger = Logger:get_instance(),
	_target_org = nil,
	_auth_info = nil,
	_metadata_type = nil,
	_component_name = nil,
	_source_files = nil,
	_check_only = false,
	_bufnr = nil,
}
Deploy.__index = Deploy
M.Deploy = Deploy

function Deploy:new() return setmetatable({}, self) end

function Deploy:set_target_org(target_org) self._target_org = target_org end

function Deploy:set_check_only(check_only) self._check_only = check_only end

---Set metadata component to deploy
---@param metadata_type string Metadata type (e.g., "ApexClass")
---@param component_name string Component name
---@param source_files table List of file paths relative to force-app/main/default
function Deploy:set_component(metadata_type, component_name, source_files)
	self._metadata_type = metadata_type
	self._component_name = component_name
	self._source_files = source_files
end

---@async
function Deploy:run_async()
	self._logger:tell_wip("Fetching auth info...")
	local fetch_auth_info = FetchAuthInfo:new()
	if self._target_org then fetch_auth_info:set_target_org(self._target_org) end
	local auth_info = fetch_auth_info:run_async()

	assert(self._metadata_type, "Metadata type must be set")
	assert(self._component_name, "Component name must be set")
	assert(self._source_files and #self._source_files > 0, "Source files must be set")

	-- Create temporary directory structure
	local temp_dir = a_fn.tempname()
	a_fn.mkdir(temp_dir, "p")
	self._temp_dir = temp_dir

	local project_root = assert(get_project_root(), "Not in an SFDX project")

	-- Copy source files to temp directory
	self._logger:tell_wip("Preparing deployment package...")
	for _, rel_file in ipairs(self._source_files) do
		local src_path = vim.fs.joinpath(project_root, "force-app/main/default", rel_file)
		local dst_path = vim.fs.joinpath(temp_dir, rel_file)
		local dst_dir = vim.fs.dirname(dst_path)
		a_fn.mkdir(dst_dir, "p")

		if a_fn.filereadable(src_path) == 1 then
			local copy_result = a_fn.filecopy(src_path, dst_path)
			if copy_result == 0 then error("Failed to copy " .. src_path .. " to " .. dst_path) end
		else
			self._logger:tell_failed("Source file not found: " .. src_path)
			error("Source file not found: " .. src_path)
		end
	end

	-- Generate and write package.xml
	local api_version = tostring(auth_info.get_api_version())
	local package_xml =
		generate_package_xml(self._metadata_type, { self._component_name }, api_version)
	local package_xml_path = vim.fs.joinpath(temp_dir, "package.xml")
	a_fn.writefile(vim.split(package_xml, "\n"), package_xml_path)

	-- Create ZIP file
	local success, err = create_zip(temp_dir, "deploy.zip")
	if not success then
		a_fn.delete(temp_dir, "rf")
		error(err)
	end

	local zip_path = vim.fs.joinpath(temp_dir, "deploy.zip")

	-- Prepare deployment using multipart/form-data (required by Metadata API)
	self._logger:tell_wip("Submitting deployment...")

	local api_v = tostring(auth_info.get_api_version())
	local deploy_url = auth_info.get_instance_url()
		.. "/services/data/v"
		.. api_v
		.. "/metadata/deployRequest"

	-- Create JSON for deploy options
	local deploy_options_json = vim.json.encode({
		deployOptions = {
			checkOnly = self._check_only,
			rollbackOnError = true,
			singlePackage = true,
		},
	})

	-- Build curl command for multipart/form-data upload
	local curl_cmd = {
		"curl",
		"-s",
		"-X",
		"POST",
		"-H",
		"Authorization: Bearer " .. auth_info.get_access_token(),
		"-H",
		"Accept: application/json",
		"-F",
		"file=@" .. zip_path .. ";type=application/zip",
		"-F",
		"json=" .. deploy_options_json .. ";type=application/json",
		deploy_url,
	}

	local deploy_submit_proc = vim.system(curl_cmd):wait()
	if deploy_submit_proc.code ~= 0 then
		a_fn.delete(self._temp_dir, "rf")
		self._logger:tell_failed("Deployment submission failed!")
		return
	end

	local resp_ok, resp =
		pcall(vim.json.decode, deploy_submit_proc.stdout, { luanil = { array = true, object = true } })
	if not resp_ok then
		a_fn.delete(self._temp_dir, "rf")
		self._logger:tell_failed("Failed to parse deployment response!")
		self._logger:tell_debug("Failed to parse deployment response: " .. deploy_submit_proc.stdout)
		return
	end

	-- Clean up temp files
	if self._temp_dir then a_fn.delete(self._temp_dir, "rf") end

	if not resp or not resp.id then
		local err_msg = "Deployment submission failed"
		if resp and resp.message then err_msg = err_msg .. ": " .. resp.message end
		self._logger:tell_failed(err_msg)
		error(err_msg)
	end

	local deploy_id = resp.id
	local poll_attempt = 1

	local done = false
	local deploy_resp = nil
	while not done do
		self._logger:tell_wip(
			("Deployment submitted, polling status (attempt %d)..."):format(poll_attempt)
		)
		local status_req = CurlReq:new()
		status_req:use_auth_info(auth_info)
		status_req:set_suburl(
			"/services/data/v"
				.. api_v
				.. "/metadata/deployRequest/"
				.. deploy_id
				.. "?includeDetails=true"
		)
		deploy_resp = status_req:send_async()
		if not deploy_resp then
			self._logger:tell_failed("Failed to get deployment status")
			error("Failed to get deployment status")
		end
		done = ((deploy_resp or {}).deployResult or {}).done or false
		if not done then a.util.sleep(DEPLOY_POLL_DURATION_MS) end
		poll_attempt = poll_attempt + 1
	end

	local deploy_result = (deploy_resp or {}).deployResult or {}
	if deploy_result.success then
		local msg = self._check_only and "Validation successful" or "Deployment successful"
		self._logger:tell_finished(msg)
		return { success = true, status = deploy_result }
	else
		-- Handle deployment failure
		local diagnostics = {}
		if deploy_result.details and deploy_result.details.componentFailures then
			local failures = deploy_result.details.componentFailures
			if type(failures) ~= "table" then failures = { failures } end

			for _, failure in ipairs(failures) do
				local lnum = tonumber(failure.lineNumber)
				local col = tonumber(failure.columnNumber)
				table.insert(diagnostics, {
					lnum = lnum and (lnum - 1) or 0,
					col = col and (col - 1) or 0,
					message = failure.problem or "Unknown error",
					source = "metadata-deploy",
				})
			end
		end

		if #diagnostics > 0 and self._bufnr then
			vim.schedule(function()
				local ns = vim.api.nvim_create_namespace("brocade-metadata-deploy")
				vim.diagnostic.reset(ns, self._bufnr)
				buf_diagnostics._set(ns, self._bufnr, diagnostics)
			end)
		end

		local err_msg = ("Deployment failed with %d error(s)"):format(#diagnostics)
		self._logger:tell_failed(err_msg)
		return { success = false, status = deploy_result, errors = diagnostics }
	end
end

---Deploy the current buffer's metadata component
---@async
function Deploy:run_on_this_buf_async()
	local bufnr = vim.api.nvim_get_current_buf()
	local file_path = vim.api.nvim_buf_get_name(bufnr)
	if not file_path or file_path == "" then error("Buffer has no filename") end

	local metadata_type, component_name, files = parse_metadata_component(file_path)
	if not metadata_type then
		error("Current buffer is not a recognized Salesforce metadata component")
	end

	self._bufnr = bufnr
	self:set_component(
		metadata_type,
		assert(component_name, "Component name is null!"),
		assert(files, "Files are null!")
	)
	self:run_async()
end

return M
