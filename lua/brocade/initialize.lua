-- initialize.lua
--
-- SFDX project initialization utilities. Sets up autocommands to detect
-- SFDX projects and pre-cache auth info for the default target org.

local a = require("plenary.async")

local FetchAuthInfo = require("brocade.org-session").FetchAuthInfo
local Logger = require("brocade.logging").Logger

local M = {}

local ProjectInit = {
	_logger = Logger:get_instance(),
	_augroup = vim.api.nvim_create_augroup("brocade-project-init", { clear = true }),
}
ProjectInit.__index = ProjectInit
M.ProjectInit = ProjectInit

function ProjectInit:new() return setmetatable({}, self) end

---@return string? sf_config_path Path to `.sf/config.json`, or nil if not in an SFDX project
function ProjectInit:_find_sf_config()
	local cwd = vim.fn.getcwd()
	local project_root = vim.fs.root(cwd, { "sfdx-project.json", ".sf" })
	if not project_root then return nil end
	local config_path = vim.fs.joinpath(project_root, ".sf", "config.json")
	if vim.fn.filereadable(config_path) == 1 then return config_path end
	return nil
end

---@return string? target_org The default target org alias/username, or nil
function ProjectInit:_read_default_target_org()
	local config_path = self:_find_sf_config()
	if not config_path then return nil end
	local ok, lines = pcall(vim.fn.readfile, config_path)
	if not ok or not lines or #lines == 0 then return nil end
	local json_str = table.concat(lines, "\n")
	local ok2, config = pcall(vim.json.decode, json_str, { luanil = { array = true, object = true } })
	if not ok2 or not config then return nil end
	return config["target-org"]
end

---Pre-fetches and caches auth info for the project's default target org.
function ProjectInit:_prefetch_auth_info()
	local target_org = self:_read_default_target_org()
	if not target_org then return end
	-- Skip if already cached:
	local cached = vim.g.brocade_auth_infos or {}
	if cached[target_org] then return end
	self._logger:tell_wip("Caching auth info for " .. target_org .. "...")
	a.run(function()
		local fetch = FetchAuthInfo:new()
		fetch:set_target_org(target_org)
		fetch:run_async()
	end, function() self._logger:tell_finished("Auth info cached for " .. target_org .. ".") end)
end

---Register autocommands that detect SFDX projects and pre-cache auth info.
function ProjectInit:setup()
	vim.api.nvim_create_autocmd({ "VimEnter", "DirChanged" }, {
		group = self._augroup,
		callback = function() self:_prefetch_auth_info() end,
	})
end

return M
