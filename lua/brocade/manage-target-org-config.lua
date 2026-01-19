-- manage-target-org-config.lua
--
-- Manage "target-org" configuration variable
--
local M = {}


---Gets path to the project-local SF CLI configuration or nil if none exists.
---Traverses up the directory tree from the current working directory.
---@return string?
local function sf_config_path()
	local sf_dotdir_path = vim.fs.root(vim.fn.getcwd(), ".sf/config.json")
	-- We don't want to use the global one:
	if sf_dotdir_path == vim.fs.joinpath(vim.env.HOME, ".sf") then
		return nil
	end
	if not sf_dotdir_path then
		return nil
	end
	return vim.fs.joinpath(sf_dotdir_path, "config.json")
end

local function read_project_config()
	local sf_config_lines = vim.fn.readfile(assert(sf_config_path()))
	local sf_config_json = table.concat(sf_config_lines, "\n")
	local sf_config = vim.json.decode(sf_config_json, { luanil = { array = true, object = true } })
	--
	return {
		sf_target_org = sf_config["target-org"],
		sf_config = sf_config,
	}
end

local function change_project_config(new_target_org)
	local cfg = read_project_config().sf_config
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
			print(read_project_config().sf_target_org)
		end
	end

	return self
end

return M
