local M = {}

-- IMPORTS
local a = require("plenary.async")

-- IMPLEMENTATION

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

local function AuthInfo(access_token, instance_url, api_version, username, alias)
	---@class brocade.org-session.AuthInfo
	local self = {}
	local _self = {
		access_token = assert(access_token),
		instance_url = assert(instance_url),
		api_version = assert(api_version),
		username = assert(username),
		alias = assert(alias),
	}

	function self.get_access_token() return _self.access_token end
	function self.get_instance_url() return _self.instance_url end
	function self.get_api_version() return _self.api_version end
	function self.get_username() return _self.username end
	function self.get_alias() return _self.alias end

	return self
end

local function fetch_auth_info(target_org, callback)
	-- if target org is not given, use project-default one:
	if not target_org then target_org = read_project_config().sf_target_org end
	--
	local auth_infos = vim.g.brocade_auth_infos or {}
	-- in case this org's info has been already cached - return it:
	if auth_infos[target_org] then
		callback(auth_infos[target_org])
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
		local auth_info = AuthInfo(
			assert(response["result"]["accessToken"]),
			assert(response["result"]["instanceUrl"]),
			assert(response["result"]["apiVersion"]),
			assert(response["result"]["username"]),
			assert(response["result"]["alias"])
		)
		auth_infos[auth_info.get_username()] = auth_info
		auth_infos[auth_info.get_alias()] = auth_info
		vim.g.brocade_auth_infos = auth_infos
		callback(auth_info)
	end)
end

---@async
---@param target_org string
---@return brocade.org-session.AuthInfo
local function fetch_auth_info_async(target_org)
	return a.wrap(function(cb) fetch_auth_info(target_org, cb) end, 1)()
end

local FetchAuthInfo = {
	_target_org = nil,
}
FetchAuthInfo.__index = FetchAuthInfo
M.FetchAuthInfo = FetchAuthInfo

function FetchAuthInfo:new() return setmetatable({}, self) end

function FetchAuthInfo:set_target_org(target_org) self._target_org = target_org end

---@async If `cb` is not provided.
---@param cb? fun(auth_info: brocade.org-session.AuthInfo) Deprecated. If not provided, this is run in plenary async context.
---@return brocade.org-session.AuthInfo
function FetchAuthInfo:run_async(cb)
	-- handle legacy callback-style invocation:
	if not coroutine.running() then
		cb = cb or function() end
		-- we can ignore type mismatch here, as in this callback-style branch we're
		-- returning via callback, not directly, so return type is effectively void.
		---@diagnostic disable-next-line: return-type-mismatch
		return a.run(function() return self:run_async() end, cb)
	end
	-- the rest runs in plenary async context:
	local out = fetch_auth_info_async(self._target_org)
	if cb then cb(out) end
	return out
end

return M
