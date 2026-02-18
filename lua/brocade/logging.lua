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

return M
