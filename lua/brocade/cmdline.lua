local Cmdline = {
	---@type brocade.cmdline.Subcmd[]
	_subcommands = {},
}
Cmdline.__index = Cmdline

---@class brocade.cmdline.Subcmd
local Subcmd = {
	---@type string[]
	_tokens = {},
	---@type brocade.cmdline.Option[]
	_options = {},
	---@type fun()
	_on_parsed_fn = function() end,
	---@type brocade.cmdline.PosArg[]
	_pos_args = {},
}
Subcmd.__index = Subcmd

---@class brocade.cmdline.Option
local Option = {
	---@type string
	_key = "",
	---@type fun(lead: string, line: string, pos: number): string[]
	_complete_fn = function(_, _, _) return {} end,
	---@type fun(value: string)
	_on_value_fn = function(_) end,
}
Option.__index = Option

---@class brocade.cmdline.PosArg
local PosArg = {
	---@type fun(lead: string, line: string, pos: number): string[]
	_complete_fn = function(_, _, _) return {} end,
	---@type fun(value: string)
	_on_value_fn = function(_) end,
}
PosArg.__index = PosArg

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

function Cmdline:new()
	local out = setmetatable({}, self)
	out._subcommands = {}
	return out
end

---@param tokens string[]
function Cmdline:add_subcommand(tokens)
	local subcmds = self._subcommands
	local subcmd = Subcmd:new(tokens)
	subcmds[#subcmds + 1] = subcmd
	return subcmd
end

---@param lead string
---@param line string
---@param pos number
---@return string[] suggestions
function Cmdline:complete(lead, line, pos)
	local tokens = vim.split(line, "[ \t\r\n]+", { trimempty = true })
	pos = pos - #table.remove(tokens, 1) -- remove the first token - Vim command
	---@type string[][]
	local subcommands_tokens = {}
	for _, subcmd in ipairs(self._subcommands) do
		subcommands_tokens[#subcommands_tokens + 1] = subcmd._tokens
		local is_matching = matches_subcommand(tokens, subcmd._tokens)
		if is_matching then
			local opts_keys = {}
			for _, opt in ipairs(subcmd._options) do
				opts_keys[#opts_keys + 1] = opt._key
				if tokens[#tokens] == opt._key then return opt._complete_fn(lead, line, pos) end
			end
			for _, arg in ipairs(subcmd._pos_args) do
				return arg._complete_fn(lead, line, pos)
			end
			return opts_keys
		end
	end
	return complete_subcmd(tokens, subcommands_tokens)
end

function Cmdline:parse(cmdline)
	local fargs = vim.split(cmdline, "[ \t\r\n]+", { trimempty = true })
	for _, subcmd in ipairs(self._subcommands) do
		local is_matching, new_fargs = matches_subcommand(fargs, subcmd._tokens)
		if is_matching and new_fargs then
			if #new_fargs > 1 then
				for _, option in ipairs(subcmd._options) do
					if new_fargs[1] == option._key then
						option._on_value_fn(new_fargs[2])
						table.remove(new_fargs, 1)
						table.remove(new_fargs, 1)
					end
					if #new_fargs < 2 then break end
				end
			end
			if #new_fargs == 1 and #subcmd._pos_args == 1 then
				subcmd._pos_args[1]._on_value_fn(new_fargs[1])
				table.remove(new_fargs, 1)
			end
			subcmd._on_parsed_fn()
			return
		end
	end
end

---@param tokens string[]
function Subcmd:new(tokens)
	local out = setmetatable({}, self)
	out._options = {}
	out._pos_args = {}
	out._tokens = tokens
	return out
end

---@param fn fun()
function Subcmd:on_parsed(fn) self._on_parsed_fn = fn end

function Subcmd:add_positional_arg()
	local pos_arg = PosArg:new()
	self._pos_args[#self._pos_args + 1] = pos_arg
	return pos_arg
end

---@param key string
---@return brocade.cmdline.Option
function Subcmd:add_option(key)
	local option = Option:new(key)
	self._options[#self._options + 1] = option
	return option
end

---@param key string
---@return brocade.cmdline.Option
function Option:new(key)
	local out = setmetatable({}, self)
	out._key = key
	return out
end

---@param complete_fn? fun(lead: string, line: string, pos: number): string[]
function Option:expect_value(complete_fn)
	if complete_fn then self._complete_fn = complete_fn end
end

---@param on_value_fn fun(value: string)
function Option:on_value(on_value_fn) self._on_value_fn = on_value_fn end

function PosArg:new()
	local out = setmetatable({}, self)
	return out
end

---@param complete_fn fun(lead: string, line: string, pos: number): string[]
function PosArg:set_complete_fn(complete_fn) self._complete_fn = complete_fn end

---@param on_value_fn fun(value: string)
function PosArg:on_value(on_value_fn) self._on_value_fn = on_value_fn end

return Cmdline
