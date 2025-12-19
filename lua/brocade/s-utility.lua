-- s.lua
--
-- Universal "facade" user command

local Cmdline = require("brocade.cmdline")
local ManageTgtOrgCfg = require("brocade.manage-target-org-config")
local RunAnonApex = require("brocade.run-anon-apex")
local GetApexLogs = require("brocade.debug-logs").Get
local ApexClass = require("brocade.apex-class")
local TraceFlag = require("brocade.trace-flag")

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
	-- TARGET ORG
	local target_org_sub = cmdline:add_subcommand({ "target", "org" })
	local target_org_inputs = { { target_org = nil } }
	-- 1st arg: target org
	local tgt_org_sub_1 = target_org_sub:add_positional_arg()
	tgt_org_sub_1:set_complete_fn(function(lead, line, pos) return org_aliases(line) end)
	tgt_org_sub_1:on_value(function(target_org) target_org_inputs[1].target_org = target_org end)
	-- entrypoint
	target_org_sub:on_parsed(function()
		local target_org = target_org_inputs[1].target_org
		local manage_tgt_org_cfg = ManageTgtOrgCfg.ManageTargetOrg()
		manage_tgt_org_cfg.run({ target_org })
	end)

	-- RUN THIS APEX
	local run_apex_sub = cmdline:add_subcommand({ "run", "this", "apex" })
	local run_apex_inputs = { { target_org = nil } }
	-- option: target-org
	local target_org_opt = run_apex_sub:add_option("--target-org")
	target_org_opt:expect_value(function(lead, line, pos) return org_aliases(line) end)
	target_org_opt:on_value(function(target_org)
		run_apex_inputs[1] = run_apex_inputs[1] or {}
		run_apex_inputs[1].target_org = target_org
	end)
	-- option: o
	local o_opt = run_apex_sub:add_option("-o")
	target_org_opt:on_value(function(target_org)
		run_apex_inputs[1] = run_apex_inputs[1] or {}
		run_apex_inputs[1].target_org = target_org
	end)
	o_opt:expect_value(function(lead, line, pos) return org_aliases(line) end)
	-- entrypoint
	run_apex_sub:on_parsed(function()
		--
		local target_org = run_apex_inputs[1].target_org
		run_apex_inputs[1] = {} -- clean before future invocations
		--
		local run_anon_apex = RunAnonApex.RunAnonApex()
		if target_org then run_anon_apex.set_target_org(target_org) end
		run_anon_apex.run_this_buf()
	end)

	-- TRACE FLAG ENABLE
	local trace_flag_enable_sub = cmdline:add_subcommand({ "trace", "flag", "enable" })
	local trace_flag_enable_inputs = { { target_org = nil } }
	local tfe_target_org_opt = trace_flag_enable_sub:add_option("--target-org")
	tfe_target_org_opt:expect_value(function(lead, line, pos) return org_aliases(line) end)
	tfe_target_org_opt:on_value(function(target_org)
		trace_flag_enable_inputs[1] = trace_flag_enable_inputs[1] or {}
		trace_flag_enable_inputs[1].target_org = target_org
	end)
	trace_flag_enable_sub:on_parsed(function()
		local enable = TraceFlag.Enable:new()
		if trace_flag_enable_inputs[1].target_org then
			enable:set_target_org(trace_flag_enable_inputs[1].target_org)
		end
		vim.schedule(function() enable:run_async() end)
	end)

	-- TRACE FLAG GET
	local trace_flag_get_sub = cmdline:add_subcommand({ "trace", "flag", "get" })
	local trace_flag_get_inputs = { { target_org = nil, debug_level = nil } }
	local tfg_target_org_opt = trace_flag_get_sub:add_option("--target-org")
	tfg_target_org_opt:expect_value(function(lead, line, pos) return org_aliases(line) end)
	tfg_target_org_opt:on_value(function(target_org)
		trace_flag_get_inputs[1] = trace_flag_get_inputs[1] or {}
		trace_flag_get_inputs[1].target_org = target_org
	end)
	local tfg_debug_level_opt = trace_flag_get_sub:add_option("--debug-level")
	tfg_debug_level_opt:expect_value(
		function(lead, line, pos) return { "SFDC_DevConsole", "ReplayDebuggerLevels" } end
	)
	tfg_debug_level_opt:on_value(function(debug_level)
		trace_flag_get_inputs[1] = trace_flag_get_inputs[1] or {}
		trace_flag_get_inputs[1].debug_level = debug_level
	end)
	trace_flag_get_sub:on_parsed(function()
		local get = TraceFlag.Get:new()
		if trace_flag_get_inputs[1].target_org then
			get:set_target_org(trace_flag_get_inputs[1].target_org)
		end
		local dbg = trace_flag_get_inputs[1].debug_level or "SFDC_DevConsole"
		get:set_debug_level_name(dbg)
		vim.schedule(function() get:present_async() end)
	end)

	-- GET DEBUG LOGS
	local debug_logs_sub = cmdline:add_subcommand({ "get", "debug", "logs" })
	local debug_logs_inputs = { { target_org = nil, limit = nil } }
	local dlg_target_org_opt = debug_logs_sub:add_option("--target-org")
	dlg_target_org_opt:expect_value(function(lead, line, pos) return org_aliases(line) end)
	dlg_target_org_opt:on_value(function(target_org)
		debug_logs_inputs[1] = debug_logs_inputs[1] or {}
		debug_logs_inputs[1].target_org = target_org
	end)
	local limit_opt = debug_logs_sub:add_option("--limit")
	limit_opt:expect_value(function() return { "10", "20", "5" } end)
	limit_opt:on_value(function(limit)
		debug_logs_inputs[1] = debug_logs_inputs[1] or {}
		debug_logs_inputs[1].limit = tonumber(limit)
	end)
	debug_logs_sub:on_parsed(function()
		local get = GetApexLogs:new()
		if debug_logs_inputs[1].target_org then get:set_target_org(debug_logs_inputs[1].target_org) end
		if debug_logs_inputs[1].limit then get:set_limit(debug_logs_inputs[1].limit) end
		vim.schedule(function() get:present_async() end)
	end)

	-- APEX RETRIEVE (this buffer)
	local apex_retrieve_sub = cmdline:add_subcommand({ "apex", "retrieve" })
	local apex_retrieve_inputs = { { target_org = nil } }
	-- option: target-org
	local ar_target_org_opt = apex_retrieve_sub:add_option("--target-org")
	ar_target_org_opt:expect_value(function(lead, line, pos) return org_aliases(line) end)
	ar_target_org_opt:on_value(function(target_org)
		apex_retrieve_inputs[1] = apex_retrieve_inputs[1] or {}
		apex_retrieve_inputs[1].target_org = target_org
	end)
	-- entrypoint
	apex_retrieve_sub:on_parsed(function()
		local get = ApexClass.Get:new()
		if apex_retrieve_inputs[1].target_org then
			get:set_target_org(apex_retrieve_inputs[1].target_org)
		end
		get:load_this_buf_async()
	end)
end

---@type fun(lead: string, line: string, pos: number): string[]
local function complete_fn(lead, line, pos) return cmdline:complete(lead, line, pos) end

function M.SUserCommand()
	local self = {}

	function self.create()
		vim.api.nvim_create_user_command("S", function(params) cmdline:parse(params.args) end, {
			force = true,
			nargs = "*",
			complete = function(lead, line, pos) return cmdline:complete(lead, line, pos) end,
		})
	end

	return self
end

return M
