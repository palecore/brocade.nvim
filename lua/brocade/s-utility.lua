-- s.lua
--
-- Universal "facade" user command

local ManageTgtOrgCfg = require("brocade.manage-target-org-config")

local M = {}

---@type fun(lead: string, line: string, pos: number): string[]
local function complete_fn(lead, line, pos)
	local out = {}
	line = vim.trim(line)
	if vim.endswith(line, "target org") then
		pos = pos + #("target org")
		line = string.sub(line, #("target org") + 1)
		return ManageTgtOrgCfg.complete_fn(lead, line, pos)
	elseif vim.endswith(line, "org target") then
		pos = pos + #("org target")
		line = string.sub(line, #("org target") + 1)
		return ManageTgtOrgCfg.complete_fn(lead, line, pos)
	elseif vim.endswith(line, "org") then
		table.insert(out, "target")
	elseif vim.endswith(line, "target") then
		table.insert(out, "org")
	else
		table.insert(out, "org target")
		table.insert(out, "target org")
		table.insert(out, "target")
	end

	return out
end

function M.SUserCommand()
	local self = {}

	function self.create()
		vim.api.nvim_create_user_command("S", function (params)
			local fargs = params.fargs or {}
			if (
				fargs[1] == "target" and fargs[2] == "org"
				or (fargs[1] == "org" and fargs[2] == "target")
			) then
				table.remove(fargs, 1)
				table.remove(fargs, 1)
				ManageTgtOrgCfg.ManageTargetOrg().run(fargs)
			end
		end, {
				force = true,
				nargs = "*",
				complete = complete_fn,
			})
	end

	return self
end

return M
