-- curl_request_spec.lua
--
-- Tests for the pure-Lua helpers exported by curl-request. Anything that
-- touches `vim.system` or the network is excluded — those are integration
-- concerns, not unit-test territory.

local CurlRequest = require("brocade.curl-request").CurlRequest

describe("CurlRequest._split_status_sentinel", function()
	local SENTINEL = "\n___BROCADE_HTTP_STATUS___"

	it("splits a body and a trailing 3-digit HTTP status", function()
		local raw = '{"ok":true}' .. SENTINEL .. "200"
		local body, status = CurlRequest._split_status_sentinel(raw)
		assert.are.equal('{"ok":true}', body)
		assert.are.equal(200, status)
	end)

	it("recognises a 431 status correctly", function()
		local raw = "<html>431</html>" .. SENTINEL .. "431"
		local body, status = CurlRequest._split_status_sentinel(raw)
		assert.are.equal("<html>431</html>", body)
		assert.are.equal(431, status)
	end)

	it("returns nil status when sentinel is absent (legacy responses)", function()
		local raw = '{"ok":true}'
		local body, status = CurlRequest._split_status_sentinel(raw)
		assert.are.equal('{"ok":true}', body)
		assert.is_nil(status)
	end)

	it("preserves an empty body when status is the only output", function()
		local raw = SENTINEL .. "414"
		local body, status = CurlRequest._split_status_sentinel(raw)
		assert.are.equal("", body)
		assert.are.equal(414, status)
	end)

	it("returns input unchanged when given non-string input", function()
		local body, status = CurlRequest._split_status_sentinel(nil)
		assert.is_nil(body)
		assert.is_nil(status)
	end)
end)

describe("CurlRequest:set_capture_http_status", function()
	it("toggles a flag that is false/nil by default", function()
		local req = CurlRequest:new()
		assert.is_falsy(req.capture_http_status)
		req:set_capture_http_status(true)
		assert.is_true(req.capture_http_status)
		req:set_capture_http_status(false)
		assert.is_false(req.capture_http_status)
	end)
end)
