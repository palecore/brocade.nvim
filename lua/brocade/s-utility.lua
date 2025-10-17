-- s.lua
--
-- Universal "facade" user command

local ManageTgtOrgCfg = require("brocade.manage-target-org-config")

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

---@param args string[]
---@param subcommand_words string[]
---@return boolean is_matching if at least one subcommand word matches
---@return string[]? new_args after cutting out subcommand args
local function partially_matches_subcommand(args, subcommand_words)
	if #args < 1 then return false, nil end
	--
	local subcmd_words_set = {}
	local subcmd_words_count = 0
	for _, subcmd_word in ipairs(subcommand_words) do
		subcmd_words_set[subcmd_word] = true
		subcmd_words_count = subcmd_words_count + 1
	end
	--
	local new_args = vim.tbl_extend("error", args, {})
	local sth_matched = false
	while #new_args + subcmd_words_count > 0 do
		local arg = new_args[1]
		if subcmd_words_set[arg] then
			sth_matched = true
			subcmd_words_set[arg] = nil
			subcmd_words_count = subcmd_words_count - 1
			table.remove(new_args, 1)
		else
			break
		end
	end
	return sth_matched, sth_matched and new_args or nil
end

---@param args string[]
---@param subcmds string[][]
---@return integer[] matched_subcmd_idxs
---@return string[][] matched_subcmds
---@return string[][] new_args_per_subcmd
local function partially_matches_any_subcmds(args, subcmds)
	local idxs = {}
	local p_matched_subcmds = {}
	local new_args_per_subcmd = {}
	for idx, subcmd_words in ipairs(subcmds) do
		local is_match, new_args = partially_matches_subcommand(args, subcmd_words)
		if is_match then
			table.insert(idxs, idx)
			table.insert(p_matched_subcmds, subcmd_words)
			table.insert(new_args_per_subcmd, new_args)
		end
	end
	return idxs, p_matched_subcmds, new_args_per_subcmd
end

---@param args string[]
---@param subcommands string[][]
---@return string[] options
local function complete_subcmd(args, subcommands)
	local idxs, matched_subcmds, _ = partially_matches_any_subcmds(args, subcommands)
	-- if at least one match - complete only for those matched (otherwise -
	-- complete for all):
	if #idxs > 0 then subcommands = matched_subcmds end
	local options = {}
	for _, subcmd_words in ipairs(subcommands) do
		local subcmd_words_set = {}
		local subcmd_words_count = 0
		for _, subcmd_word in ipairs(subcmd_words) do
			subcmd_words_set[subcmd_word] = true
			subcmd_words_count = subcmd_words_count + 1
		end
		local treshold = math.min(#args, subcmd_words_count)
		for _ = 1, treshold do
			local line_word = table.remove(args, 1)
			subcmd_words_set[line_word] = nil
		end
		local function build_permut_tree(option_set)
			local tree = {}
			for opt, _ in pairs(option_set) do
				local rest = vim.tbl_extend("error", option_set, {})
				rest[opt] = nil
				tree[opt] = build_permut_tree(rest)
			end
			return tree
		end
		---@return string[] results
		local function flatten_permut_tree(tree)
			local results = {}
			for prefix, subtree in pairs(tree) do
				local subresult_count = 0
				for _, subresult in ipairs(flatten_permut_tree(subtree)) do
					table.insert(results, prefix .. " " .. subresult)
					subresult_count = subresult_count + 1
				end
				if subresult_count == 0 then table.insert(results, prefix) end
			end
			return results
		end
		local permut_tree = build_permut_tree(subcmd_words_set)
		for _, subcmd_option in ipairs(flatten_permut_tree(permut_tree)) do
			table.insert(options, subcmd_option)
		end
	end
	table.sort(options)
	return options
end

---@type fun(lead: string, line: string, pos: number): string[]
local function complete_fn(lead, line, pos)
	-- define fixed, supported subcommands:
	local subcmds = {
		{ "target", "org" },
	}
	--
	local subline = string.sub(line, #"S " + 1)
	local args = vim.split(subline, "[ \t\r\n]+", { trimempty = true })
	if matches_subcommand(args, subcmds[1]) then
		return ManageTgtOrgCfg.complete_fn(lead, line, pos)
	end
	local subcmd_out = complete_subcmd(args, subcmds)
	return subcmd_out
end

function M.SUserCommand()
	local self = {}

	function self.create()
		vim.api.nvim_create_user_command("S", function(params)
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
