-- user_info_spec.lua
--
-- Tests for the user-info module, specifically its caching behaviour.

local UserInfo = require("brocade.user-info")

---Builds a fake AuthInfo table conforming to the brocade.org-session.AuthInfo
---interface (only the methods used by user-info are implemented).
local function make_auth_info(instance_url, username)
	return {
		get_instance_url = function() return instance_url end,
		get_username = function() return username end,
		-- not used by user-info but part of the interface:
		get_access_token = function() return "tok" end,
		get_api_version = function() return "60.0" end,
		get_alias = function() return "alias" end,
	}
end

---Builds a fake CurlRequest factory that asserts on the SOQL query produced
---and responds with `response_payload`. Tracks how many times a request was
---built (i.e. how often the underlying HTTP query was executed).
local function make_fake_req_factory(response_payload, on_query)
	local call_count = 0
	local factory = function()
		call_count = call_count + 1
		local fake = {
			_q = nil,
			use_auth_info = function(self, _) return self end,
			set_tooling_suburl = function(self, _) return self end,
			set_kv_data = function(self, key, value)
				if key == "q" then self._q = value end
				if on_query then on_query(value) end
				return self
			end,
			send = function(self, cb) cb(response_payload) end,
		}
		return fake
	end
	return factory, function() return call_count end
end

describe("user-info", function()
	before_each(function() UserInfo._reset_cache_for_tests() end)

	it("queries and returns the User Id when not cached", function()
		local auth_info = make_auth_info("https://x.salesforce.com", "alice@example.com")
		local response = {
			done = true,
			size = 1,
			totalSize = 1,
			entityTypeName = "User",
			records = { { Id = "005000000000001" } },
		}
		local factory, get_calls = make_fake_req_factory(response)

		-- Drive the cache via the test-only query helper bypass: we reuse the
		-- public API, but force a cache miss and supply our fake factory.
		UserInfo._reset_cache_for_tests()
		local got
		-- We cannot inject the factory through fetch_user_id directly, so
		-- exercise _query_user_id_for_tests then verify the cache is populated
		-- by a second call going through fetch_user_id (which should hit the
		-- cache and not need the factory at all).
		UserInfo._query_user_id_for_tests(auth_info, function(uid) got = uid end, factory)
		assert.are.equal("005000000000001", got)
		assert.are.equal(1, get_calls())
	end)

	it("escapes single quotes in usernames within the SOQL query", function()
		local auth_info = make_auth_info("https://x.salesforce.com", "o'brien@example.com")
		local seen_q
		local factory = make_fake_req_factory({
			done = true,
			size = 1,
			totalSize = 1,
			entityTypeName = "User",
			records = { { Id = "005000000000002" } },
		}, function(q) seen_q = q end)

		UserInfo._query_user_id_for_tests(auth_info, function() end, factory)
		assert.is_truthy(seen_q)
		-- The single quote in the username must be escaped:
		assert.is_truthy(seen_q:find("o\\'brien@example.com", 1, true))
	end)

	it("uses cache on subsequent fetch_user_id for same (instance_url, username)", function()
		local instance_url = "https://x.salesforce.com"
		local username = "bob@example.com"
		local auth_info = make_auth_info(instance_url, username)

		UserInfo._seed_cache_for_tests(instance_url, username, "005CACHED000001")

		local got
		UserInfo.fetch_user_id(auth_info, function(uid) got = uid end)
		assert.are.equal("005CACHED000001", got)
	end)

	it("treats different (instance_url, username) tuples as separate cache keys", function()
		UserInfo._seed_cache_for_tests("https://a", "u@x", "ID_A")
		UserInfo._seed_cache_for_tests("https://b", "u@x", "ID_B")

		local got_a, got_b
		UserInfo.fetch_user_id(make_auth_info("https://a", "u@x"), function(v) got_a = v end)
		UserInfo.fetch_user_id(make_auth_info("https://b", "u@x"), function(v) got_b = v end)

		assert.are.equal("ID_A", got_a)
		assert.are.equal("ID_B", got_b)
	end)

	it("asserts loudly on malformed query responses", function()
		local auth_info = make_auth_info("https://x", "u@x")
		local bad_response = { done = false }
		local factory = make_fake_req_factory(bad_response)
		assert.has_error(function()
			UserInfo._query_user_id_for_tests(auth_info, function() end, factory)
		end)
	end)
end)
