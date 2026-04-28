-- logging.lua
--
-- An interface to log plugin messages as user notifications and/or into a
-- journal.

local M = {}

---@class brocade.logging.Logger
local Logger = {
	---@type ProgressHandle?
	_progress_handle = nil,
}
Logger.__index = Logger
M.Logger = Logger

local function make_progress_handle(msg)
	return require("fidget").progress.handle.create({
		title = "brocade.nvim",
		message = msg,
	})
end

local instance = nil
function Logger:get_instance()
	instance = instance or Logger:new()
	return instance
end

function Logger:new()
	local out = setmetatable({}, self)
	return out
end

function Logger:tell_wip(msg)
	vim.schedule(function()
		self._progress_handle = self._progress_handle or make_progress_handle(msg)
		self._progress_handle:report({ message = msg })
	end)
end

function Logger:tell_failed(msg)
	vim.schedule(function()
		self._progress_handle = self._progress_handle or make_progress_handle(msg)
		self._progress_handle.message = msg
		self._progress_handle:cancel()
		self._progress_handle = nil
		vim.notify(msg, vim.log.levels.ERROR)
	end)
end

function Logger:tell_finished(msg)
	vim.schedule(function()
		self._progress_handle = self._progress_handle or make_progress_handle(msg)
		self._progress_handle.message = msg
		self._progress_handle:finish()
		self._progress_handle = nil
		vim.notify(msg, vim.log.levels.INFO)
	end)
end

function Logger:tell_debug(msg)
	vim.schedule(function() vim.notify(msg, vim.log.levels.DEBUG) end)
end

---Runs `fn` and, if it raises a Lua error, marks any in-progress operation
---as failed with `fail_label` and emits the traceback as a debug message.
---User-presentable errors should NOT be reported via `error()`; this helper
---is a safety net for unintentional Lua errors that would otherwise leave
---the fidget progress handle spinning forever.
---@generic R
---@param fail_label string Short user-facing label, e.g. "Apex deploy".
---@param fn fun(): R
---@return boolean ok
---@return R|string result_or_error
function Logger:run_protected(fail_label, fn)
	local ok, result = xpcall(fn, debug.traceback)
	if not ok then
		self:tell_debug(
			("[%s] Unexpected Lua error:\n%s"):format(fail_label, tostring(result))
		)
		self:tell_failed(fail_label .. " failed unexpectedly. Run `:messages` for details.")
	end
	return ok, result
end

---Returns a 0-arg function that wraps `fn` with `run_protected`. Suitable
---for use as an `a.void(...)` body or a `vim.schedule(...)` callback.
---@param fail_label string
---@param fn fun()
---@return fun()
function Logger:protect(fail_label, fn)
	return function() self:run_protected(fail_label, fn) end
end

return M
