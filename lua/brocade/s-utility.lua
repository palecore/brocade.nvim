-- s.lua
--
-- Universal "facade" user command

local Cmdline = require("brocade.cmdline")
local ManageTgtOrgCfg = require("brocade.manage-target-org-config")
local RunAnonApex = require("brocade.run-anon-apex")

local M = {}

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

local function org_aliases(line)
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

local cmdline = Cmdline:new()
do
	cmdline:add_subcommand({ "target", "org" })
	local run_apex_sub = cmdline:add_subcommand({ "run", "this", "apex" })
	local target_org_opt = run_apex_sub:add_option("--target-org")
	target_org_opt:expect_value(function(lead, line, pos) return org_aliases(line) end)
	local o_opt = run_apex_sub:add_option("-o")
	o_opt:expect_value(function(lead, line, pos) return org_aliases(line) end)
end

---@type fun(lead: string, line: string, pos: number): string[]
local function complete_fn(lead, line, pos) return cmdline:complete(lead, line, pos) end

function M.SUserCommand()
	local self = {}

	function self.create()
		vim.api.nvim_create_user_command("S", function(params)
			local fargs = params.fargs or {}
			local is_subcmd_matched
			local new_fargs
			-- CMD: target org:
			is_subcmd_matched, new_fargs = matches_subcommand(fargs, { "target", "org" })
			if is_subcmd_matched and new_fargs then ManageTgtOrgCfg.ManageTargetOrg().run(new_fargs) end
			-- CMD: run this apex:
			is_subcmd_matched, new_fargs = matches_subcommand(fargs, { "run", "this", "apex" })
			if is_subcmd_matched and new_fargs then
				local run_anon_apex = RunAnonApex.RunAnonApex()
				-- parse optional target org argument:
				local target_org = nil
				if new_fargs[1] == "-o" and new_fargs[2] then
					target_org = new_fargs[2]
				elseif new_fargs[1] == "--target-org" and new_fargs[2] then
					target_org = new_fargs[2]
				end
				if target_org then run_anon_apex.set_target_org(target_org) end
				-- execute the command:
				run_anon_apex.run_this_buf()
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
