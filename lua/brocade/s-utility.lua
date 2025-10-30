-- s.lua
--
-- Universal "facade" user command

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

---@param args string[]
---@param subcommand_words string[]
---@return boolean is_matching if args so far match the subcommand words
local function partially_matches_subcommand(args, subcommand_words)
	if #args < 1 then return false end
	--
	local subcmd_words_set = {}
	local subcmd_words_count = 0
	for _, subcmd_word in ipairs(subcommand_words) do
		subcmd_words_set[subcmd_word] = true
		subcmd_words_count = subcmd_words_count + 1
	end
	--
	if #args > subcmd_words_count then return false end
	--
	for _, arg in ipairs(args) do
		if not subcmd_words_set[arg] then return false end
		subcmd_words_set[arg] = nil
		subcmd_words_count = subcmd_words_count - 1
	end
	return true
end

---@param args string[]
---@param subcmds string[][]
---@return integer[] matched_subcmd_idxs
---@return string[][] matched_subcmds
local function partially_matches_any_subcmds(args, subcmds)
	local idxs = {}
	local p_matched_subcmds = {}
	for idx, subcmd_words in ipairs(subcmds) do
		local is_match = partially_matches_subcommand(args, subcmd_words)
		if is_match then
			table.insert(idxs, idx)
			table.insert(p_matched_subcmds, subcmd_words)
		end
	end
	return idxs, p_matched_subcmds
end

---@param args string[]
---@param subcommands string[][]
---@return string[] options
local function complete_subcmd(args, subcommands)
	local idxs, matched_subcmds = partially_matches_any_subcmds(args, subcommands)
	-- if at least one match - complete only for those matched:
	if #idxs > 0 then
		subcommands = matched_subcmds
	elseif #args > 0 then
		-- if there are already some args but no partial matches - no compl opts:
		return {}
	end
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

---@type fun(lead: string, line: string, pos: number): string[]
local function complete_fn(lead, line, pos)
	-- define fixed, supported subcommands:
	local subcmds = {
		{ "target", "org" },
		{ "run", "this", "apex" },
	}
	--
	local subline = string.sub(line, #"S " + 1)
	local args = vim.split(subline, "[ \t\r\n]+", { trimempty = true })
	if matches_subcommand(args, subcmds[1]) then
		return ManageTgtOrgCfg.complete_fn(lead, line, pos)
	elseif matches_subcommand(args, subcmds[2]) then
		local avails = { "-o", "--target-org" }
		local opt_args = {}
		for i = 4, #args do
			local opt_arg = args[i]
			opt_args[#opt_args + 1] = opt_arg
			if opt_arg == "-o" or opt_arg == "--target-org" then
				avails = {}
			end
		end
		if opt_args[#opt_args] == "-o" or opt_args[#opt_args] == "--target-org" then
			return org_aliases(opt_args[#opt_args] or "")
		else
			return avails
		end
	end
	local subcmd_out = complete_subcmd(args, subcmds)
	return subcmd_out
end

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
