-- manage-target-org-config.lua
--
-- Manage "target-org" configuration variable
--
local M = {}

local OrgSession = require("brocade.org-session")

---Gets path to the project-local SF CLI config file using the canonical
---resolution logic from org-session (including git-worktree support).
---@return string
local function sf_config_path() return OrgSession.sf_config_path() end

---@return { sf_target_org: string?, sf_config: table }?
local function read_project_config() return OrgSession.read_project_config() end

local function change_project_config(new_target_org)
	local project_config = read_project_config()
	assert(project_config, "No SF CLI project configuration found!")
	local cfg = project_config.sf_config
	cfg["target-org"] = new_target_org
	local cfg_json = vim.json.encode(cfg, {})

	vim.fn.writefile({ cfg_json }, assert(sf_config_path()), "bs")
	return {
		ok = true,
	}
end

---@type fun(lead: string, line: string, pos: number): string[]
function M.complete_fn(lead, line, pos)
	local out = {}
	local function read_org_aliases()
		local aliases_path = vim.fn.glob("~/.sfdx/alias.json")
		local aliases_json = table.concat(vim.fn.readfile(aliases_path), "\n")
		local aliases_obj = vim.json.decode(aliases_json, { luanil = { array = true, object = true } })
		return aliases_obj
	end
	line = vim.trim(line)
	local aliases_obj = read_org_aliases()
	for alias, _ in pairs(aliases_obj.orgs) do
		table.insert(out, alias)
	end
	return out
end

function M.ManageTargetOrg()
	local self = {}

	---@param fargs string[]
	function self.run(fargs)
		if #fargs > 0 and #fargs[1] > 0 then
			-- set to a given alias (& print it afterwards):
			if change_project_config(fargs[1]).ok then
				print(fargs[1])
			end
		else
			-- print current configuration value:
			local cfg = read_project_config()
			if cfg and cfg.sf_target_org then
				print(cfg.sf_target_org)
			else
				print("(no target org set)")
			end
		end
	end

	return self
end

return M
