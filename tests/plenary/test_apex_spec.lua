-- test_apex_spec.lua
--
-- Tests for static helpers exported by brocade.test-apex. The HTTP-driven
-- run_async / run_on_this_buf_async paths are out of scope here.

local TestApex = require("brocade.test-apex")

describe("TestApex.find_test_methods", function()
	it("finds an @isTest annotated method on the next line", function()
		local lines = {
			"public class FooTest {",
			"    @isTest",
			"    static void shouldDoX() {",
			"    }",
			"}",
		}
		assert.are.same({ "shouldDoX" }, TestApex.find_test_methods(lines))
	end)

	it("supports the @IsTest spelling case-insensitively", function()
		local lines = {
			"@IsTest",
			"static void Beta() {",
		}
		assert.are.same({ "Beta" }, TestApex.find_test_methods(lines))
	end)

	it("supports @isTest with arguments like (SeeAllData=true)", function()
		local lines = {
			"@isTest(SeeAllData=true)",
			"static void seeingAll() {",
		}
		assert.are.same({ "seeingAll" }, TestApex.find_test_methods(lines))
	end)

	it("recognises legacy testMethod modifier", function()
		local lines = {
			"public class Legacy {",
			"    static testMethod void legacyOne() {}",
			"    public static testMethod void legacyTwo() {}",
			"}",
		}
		assert.are.same({ "legacyOne", "legacyTwo" }, TestApex.find_test_methods(lines))
	end)

	it("ignores non-test methods even when they sit inside a test class", function()
		local lines = {
			"@isTest",
			"public class FooTest {",
			"    static void helper() {}",
			"    @isTest",
			"    static void realTest() {}",
			"}",
		}
		-- Class-level @isTest must not bleed onto subsequent methods. Only the
		-- explicit @isTest right above realTest should count.
		assert.are.same({ "realTest" }, TestApex.find_test_methods(lines))
	end)

	it("does not double-count duplicate detections", function()
		local lines = {
			"@isTest",
			"@isTest",
			"static void onlyOnce() {}",
		}
		assert.are.same({ "onlyOnce" }, TestApex.find_test_methods(lines))
	end)

	it("ignores @isTest annotations sitting in line comments", function()
		local lines = {
			"// @isTest -- documenting the convention",
			"static void notATest() {}",
		}
		assert.are.same({}, TestApex.find_test_methods(lines))
	end)

	it("returns an empty list when there are no test methods", function()
		local lines = {
			"public class Foo {",
			"    public static void bar() {}",
			"}",
		}
		assert.are.same({}, TestApex.find_test_methods(lines))
	end)
end)

describe("TestApex.Run:set_test_methods", function()
	it("treats nil and empty list as 'run all methods'", function()
		local run = TestApex.Run:new()
		run:set_test_methods(nil)
		assert.is_nil(run._test_methods)
		run:set_test_methods({})
		assert.is_nil(run._test_methods)
	end)

	it("stores the list when given non-empty methods", function()
		local run = TestApex.Run:new()
		run:set_test_methods({ "a", "b" })
		assert.are.same({ "a", "b" }, run._test_methods)
	end)
end)
