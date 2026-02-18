-- Shared buffer diagnostics utilities.
local M = {}

---@class brocade.Diagnostic
---@field lnum number Zero-based line number
---@field col number Zero-based column number
---@field message string Diagnostic message
---@field severity? vim.diagnostic.Severity Defaults to ERROR
---@field source? string Source identifier

---Set diagnostics on a buffer and auto-clear them on next BufRead/BufWrite.
---Must be called from the main thread (or wrapped in vim.schedule).
---@param ns number Namespace id from vim.api.nvim_create_namespace
---@param bufnr number Buffer number
---@param diagnostics brocade.Diagnostic[]
function M._set(ns, bufnr, diagnostics)
	if not diagnostics or #diagnostics == 0 then return end

	for _, d in ipairs(diagnostics) do
		d.severity = d.severity or vim.diagnostic.severity.ERROR
	end

	vim.diagnostic.set(ns, bufnr, diagnostics)

	vim.api.nvim_create_autocmd({ "BufRead", "BufWrite" }, {
		buffer = bufnr,
		once = true,
		callback = function() vim.diagnostic.reset(ns, bufnr) end,
	})
end

return M
