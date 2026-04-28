-- logging_spec.lua
--
-- Tests for the Logger error-protection helpers. The fidget-backed UI side
-- effects are exercised indirectly: we stub `tell_failed`/`tell_debug` to
-- capture invocations rather than driving the real progress UI.

local Logger = require("brocade.logging").Logger

---Builds a fresh Logger with `tell_failed` and `tell_debug` stubbed out so
---the test can assert on what it was told without scheduling work onto the
---neovim event loop.
local function make_capturing_logger()
	local self = Logger:new()
	local captured = { failed = {}, debug = {} }
	function self:tell_failed(msg) table.insert(captured.failed, msg) end
	function self:tell_debug(msg) table.insert(captured.debug, msg) end
	return self, captured
end

describe("Logger:run_protected", function()
	it("returns ok=true and forwards the result on success", function()
		local logger, captured = make_capturing_logger()
		local ok, value = logger:run_protected("Op", function() return 42 end)
		assert.is_true(ok)
		assert.are.equal(42, value)
		assert.are.same({}, captured.failed)
		assert.are.same({}, captured.debug)
	end)

	it("catches a Lua error, calls tell_failed and emits a debug traceback", function()
		local logger, captured = make_capturing_logger()
		local ok = logger:run_protected("Op", function() error("boom") end)
		assert.is_false(ok)
		assert.are.equal(1, #captured.failed)
		assert.is_truthy(captured.failed[1]:find("Op", 1, true))
		assert.is_truthy(captured.failed[1]:lower():find("failed", 1, true))
		assert.are.equal(1, #captured.debug)
		assert.is_truthy(captured.debug[1]:find("boom", 1, true))
		-- The debug message should include a traceback (xpcall + debug.traceback):
		assert.is_truthy(captured.debug[1]:find("stack traceback:", 1, true))
	end)

	it("propagates assertion errors as 'failed' too", function()
		local logger, captured = make_capturing_logger()
		local ok = logger:run_protected("Op", function() assert(false, "nope") end)
		assert.is_false(ok)
		assert.are.equal(1, #captured.failed)
		assert.is_truthy(captured.debug[1]:find("nope", 1, true))
	end)
end)

describe("Logger:protect", function()
	it("wraps a function such that calling it triggers run_protected", function()
		local logger, captured = make_capturing_logger()
		local invoked = false
		local wrapped = logger:protect("Wrapped", function()
			invoked = true
			error("kaboom")
		end)
		wrapped()
		assert.is_true(invoked)
		assert.are.equal(1, #captured.failed)
		assert.is_truthy(captured.failed[1]:find("Wrapped", 1, true))
	end)

	it("does not invoke the failure path on a clean run", function()
		local logger, captured = make_capturing_logger()
		local wrapped = logger:protect("Clean", function() return "ok" end)
		wrapped()
		assert.are.same({}, captured.failed)
		assert.are.same({}, captured.debug)
	end)
end)
