-- Salesforce metadata deployment and retrieval through Metadata API.
local M = {}

-- CAUTION: This module is in early development stage  and may contain bugs or
-- incomplete features. Use with caution and report any issues you encounter.

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

-- IMPLEMENTATION

---@type number Metadata deployment status polling duration.
local DEPLOY_POLL_DURATION_MS = 500

-- Metadata type configuration: maps metadata type names to their directory and file patterns
local METADATA_TYPE_CONFIG = {
	ApexClass = { dir = "classes", extension = "cls", has_meta = true },
	ApexTrigger = { dir = "triggers", extension = "trigger", has_meta = true },
	ApexPage = { dir = "pages", extension = "page", has_meta = true },
	ApexComponent = { dir = "components", extension = "component", has_meta = true },
	LightningComponentBundle = { dir = "lwc", extension = nil, is_bundle = true },
	AuraDefinitionBundle = { dir = "aura", extension = nil, is_bundle = true },
	CustomObject = { dir = "objects", extension = "object-meta.xml", has_meta = false },
	CustomField = { dir = "objects", extension = "field-meta.xml", has_meta = false },
	Layout = { dir = "layouts", extension = "layout-meta.xml", has_meta = false },
	PermissionSet = { dir = "permissionsets", extension = "permissionset-meta.xml", has_meta = false },
	Profile = { dir = "profiles", extension = "profile-meta.xml", has_meta = false },
	Flow = { dir = "flows", extension = "flow-meta.xml", has_meta = false },
	StaticResource = { dir = "staticresources", extension = "resource", has_meta = true },
}

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

---Parse a file path to extract metadata type and component name
---@param file_path string Full path to the metadata file
---@return string? metadata_type
---@return string? component_name
---@return table? files List of files to include (for bundles)
local function parse_metadata_component(file_path)
	local project_root = get_project_root()
	if not project_root then return nil, nil, nil end

	-- Normalize path relative to force-app/main/default
	local rel_path = file_path:gsub("^" .. vim.pesc(project_root) .. "/", "")
	local force_app_pattern = "force%-app/main/default/([^/]+)/(.+)$"
	local dir_type, rest = rel_path:match(force_app_pattern)

	if not dir_type then return nil, nil, nil end

	-- Find matching metadata type
	for md_type, config in pairs(METADATA_TYPE_CONFIG) do
		if config.dir == dir_type then
			if config.is_bundle then
				-- Bundle types (LWC, Aura) - include entire directory
				local bundle_name = rest:match("^([^/]+)")
				if bundle_name then
					local bundle_dir =
						vim.fs.joinpath(project_root, "force-app/main/default", dir_type, bundle_name)
					local files = {}
					-- Collect all files in bundle
					for name, type in vim.fs.dir(bundle_dir) do
						if type == "file" then
							table.insert(files, vim.fs.joinpath(dir_type, bundle_name, name))
						end
					end
					return md_type, bundle_name, files
				end
			else
				-- Single file types
				local file_name = vim.fs.basename(rest)
				local component_name

				if config.has_meta then
					if vim.endswith(file_name, "-meta.xml") then
						-- If we're on a meta file, extract the base name
						component_name = file_name:sub(1, -(#"-meta.xml" + 1))
					elseif vim.endswith(file_name, config.extension) then
						-- Otherwise, extract the component name from the main file
						component_name = file_name:sub(1, -(#("." .. config.extension) + 1))
					end
				else
					-- Types where the file IS the meta file (e.g., CustomField)
					if vim.endswith(file_name, config.extension) then
						component_name = file_name:sub(1, -(#("." .. config.extension) + 1))
					end
				end

				if component_name then
					local files = {}
					table.insert(files, vim.fs.joinpath(dir_type, file_name))

					-- Add meta file if it exists separately
					if config.has_meta then
						local base_file = vim.fs.joinpath(
							project_root,
							"force-app/main/default",
							dir_type,
							component_name .. "." .. config.extension
						)
						local meta_file_path = base_file .. "-meta.xml"
						if a_fn.filereadable(meta_file_path) == 1 then
							table.insert(
								files,
								vim.fs.joinpath(dir_type, component_name .. "." .. config.extension .. "-meta.xml")
							)
						end
					end

					return md_type, component_name, files
				end
			end
		end
	end

	return nil, nil, nil
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
		status_req:set_suburl("/services/data/v" .. api_v .. "/metadata/deployRequest/" .. deploy_id)
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
		local error_details = {}
		if deploy_result.details and deploy_result.details.componentFailures then
			local failures = deploy_result.details.componentFailures
			if type(failures) ~= "table" then failures = { failures } end

			for _, failure in ipairs(failures) do
				local err_line = string.format(
					"%s: %s (line %s, col %s)",
					failure.fullName or "Unknown",
					failure.problem or "Unknown error",
					failure.lineNumber or "?",
					failure.columnNumber or "?"
				)
				table.insert(error_details, err_line)
			end
		end

		local err_msg = "Deployment failed"
		if #error_details > 0 then err_msg = err_msg .. ":\n" .. table.concat(error_details, "\n") end

		self._logger:tell_failed(err_msg)
		return { success = false, status = deploy_result, errors = error_details }
	end
end

---Deploy the current buffer's metadata component
---@async
function Deploy:run_on_this_buf_async()
	local file_path = vim.api.nvim_buf_get_name(0)
	if not file_path or file_path == "" then error("Buffer has no filename") end

	local metadata_type, component_name, files = parse_metadata_component(file_path)
	if not metadata_type then
		error("Current buffer is not a recognized Salesforce metadata component")
	end

	self:set_component(
		metadata_type,
		assert(component_name, "Component name is null!"),
		assert(files, "Files are null!")
	)
	self:run_async()
end

return M
