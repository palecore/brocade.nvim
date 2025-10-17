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

---@param args string[]
---@param subcommand_words string[]
---@return boolean is_matching
---@return string[]? new_args after cutting out subcommand args
local function matches_subcommand(args, subcommand_words)
	--
	local subcmd_words_set = {}
	local subcmd_words_count = 0
	for _, subcmd_word in ipairs(subcommand_words) do
		subcmd_words_set[subcmd_word] = true
		subcmd_words_count = subcmd_words_count + 1
	end
	--
	local new_args = vim.tbl_extend("error", args, {})
	if #new_args < subcmd_words_count then return false, nil end
	for _ = 1, subcmd_words_count do
		local arg_word = table.remove(new_args, 1)
		subcmd_words_set[arg_word] = nil
	end
	-- if there is any subcmd word left in the set, the subcmd doesn't match:
	for _, _ in pairs(subcmd_words_set) do
		return false, nil
	end
	return true, new_args
end

function M.SUserCommand()
	local self = {}

	function self.create()
		vim.api.nvim_create_user_command("S", function (params)
			local fargs = params.fargs or {}
			local is_tgt_org_subcmd, new_fargs = matches_subcommand(fargs, { "target", "org" })
			if is_tgt_org_subcmd and new_fargs then ManageTgtOrgCfg.ManageTargetOrg().run(new_fargs) end
		end, {
				force = true,
				nargs = "*",
				complete = complete_fn,
			})
	end

	return self
end

return M
