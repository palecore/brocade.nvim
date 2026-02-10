local Cmdline = require("brocade.cmdline")

describe("Cmdline", function()
	it("completes subcommands when no args", function()
		local c = Cmdline:new()
		c:add_subcommand({ "foo" })
		c:add_subcommand({ "bar", "baz" })
		local opts = c:complete("", "cmd", 3)
		table.sort(opts)
		assert.are.same({ "bar baz", "baz bar", "foo" }, opts)
	end)

	it("completes for a partially provided subcommand token", function()
		local c = Cmdline:new()
		c:add_subcommand({ "foo" })
		c:add_subcommand({ "bar", "baz" })
		local opts = c:complete("", "cmd bar", 7)
		assert.are.same({ "baz" }, opts)
	end)

	it("returns option completions when option key is present", function()
		local c = Cmdline:new()
		local sc = c:add_subcommand({ "sub" })
		local opt = sc:add_option("--opt")
		opt:expect_value(function() return { "val1", "val2" } end)
		local opts = c:complete("", "cmd sub --opt", 13)
		assert.are.same({ "val1", "val2" }, opts)
	end)

	it("parses options and positional args and calls callbacks", function()
		local c = Cmdline:new()
		local sc = c:add_subcommand({ "do" })
		local captured_opt_value
		local captured_pos_value
		sc:add_option("--opt"):on_value(function(v) captured_opt_value = v end)
		sc:add_positional_arg():on_value(function(v) captured_pos_value = v end)
		local parsed_called = false
		sc:on_parsed(function() parsed_called = true end)

		c:parse("do --opt value posarg")

		assert.are.equal("value", captured_opt_value)
		assert.are.equal("posarg", captured_pos_value)
		assert.is_true(parsed_called)
	end)

	it(
		"supports one positional with specific completion and any number of subsequent positional completions",
		function()
			local c = Cmdline:new()
			local sc = c:add_subcommand({ "run" })
			-- singular positional (uses on_value signature)
			sc:add_positional_arg():on_value(function(v) end)
			-- any positional args completion (not implemented yet)
			sc:add_any_positional_args(function(lead, line, pos) return { "rest1", "rest2" } end)
				:on_value(function(v) end)
			local opts1 = c:complete("", "cmd run ", 8)
			-- expect completion for the first positional (may fail)
			assert.are.same({ "rest1", "rest2" }, opts1)
		end
	)

	it("suggests option key or positional completions for finished subcommand", function()
		local c = Cmdline:new()
		local sc = c:add_subcommand({ "sub" })
		local opt = sc:add_option("--long")
		opt:expect_value(function() return { "L1" } end)
		sc:add_positional_arg():set_complete_fn(function() return { "P1" } end)
		local opts = c:complete("", "cmd sub ", 7)
		assert.are.same({ "--long", "P1" }, opts)
	end)
end)
