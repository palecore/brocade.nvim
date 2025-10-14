-- init.lua
--
-- Main entry point to the brocade.nvim plugin.

-- DEPENDENCIES

local SUtility = require("brocade.s-utility")

-- MODULE

local M = {}

---@class brocade.opts {}

---@param opts brocade.opts
function M.setup(opts)
	opts = opts or {}
	-- commands:
	-- * "S" facade command:
	SUtility.SUserCommand().create()
	-- key mappings:
	-- quickly open the "S" facade command:
	vim.keymap.set("n", "<leader>s", ":S<space>", {})
end

return M
