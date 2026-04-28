-- user-info.lua
--
-- Locally cached lookup of Salesforce User records (currently the User Id
-- belonging to the authenticated principal).
--
-- Many flows need the User Id of the authenticated user to set up TraceFlag
-- records.  Looking it up costs an HTTP round trip, so we cache the result
-- by (instance_url, username) for the lifetime of the Neovim session.
--
-- Cache invalidation is not yet implemented; the underlying data is rarely
-- volatile (User Ids do not change) so a session-long cache is appropriate.
--
-- Both a callback-style and a plenary-async-style API are exposed so this
-- module can be used from older callback-chaining sites as well as from new
-- async-context sites.

local M = {}

local a = require("plenary.async")

local CurlReq = require("brocade.curl-request").CurlRequest

---@type table<string, string> Maps "<instance_url>|<username>" -> User Id.
local _cache = {}

local function _cache_key(instance_url, username)
	return string.format("%s|%s", instance_url, username)
end

local function _sq_escape(str) return string.gsub(str, "'", "\\'") end

---Internal: runs the SOQL query and returns the Id from the parsed response.
---Exposed only for testing via dependency injection of `req_factory`.
---@param auth_info brocade.org-session.AuthInfo
---@param callback fun(user_id: string)
---@param req_factory? fun(): table Optional curl request factory (for tests).
local function _query_user_id(auth_info, callback, req_factory)
	local req = (req_factory or function() return CurlReq:new() end)()
	req:use_auth_info(auth_info)
	req:set_tooling_suburl("/query")
	local username_sq_esc = _sq_escape(auth_info.get_username())
	req:set_kv_data(
		"q",
		("SELECT Id FROM User WHERE Username = '%s' LIMIT 1"):format(username_sq_esc)
	)
	req:send(function(result)
		assert(result, "User query result invalid!")
		assert(result.done == true, "Query not finished!")
		assert(result.size == 1, "Query result is not 1 record!")
		assert(result.totalSize == 1, "Query result is not 1 record total!")
		assert(result.entityTypeName == "User", "Unexpected query result entity!")
		local user_record = result.records[1]
		local user_id = assert(user_record.Id)
		callback(user_id)
	end)
end

---Fetches the authenticated user's Id, hitting the cache where possible.
---Callback-style API for use from legacy callback-chaining sites.
---@param auth_info brocade.org-session.AuthInfo
---@param callback fun(user_id: string)
function M.fetch_user_id(auth_info, callback)
	local key = _cache_key(auth_info.get_instance_url(), auth_info.get_username())
	local cached = _cache[key]
	if cached then return callback(cached) end
	_query_user_id(auth_info, function(user_id)
		_cache[key] = user_id
		callback(user_id)
	end)
end

---Async wrapper around `fetch_user_id`.
---@async
---@param auth_info brocade.org-session.AuthInfo
---@return string user_id
function M.fetch_user_id_async(auth_info)
	return a.wrap(function(cb) M.fetch_user_id(auth_info, cb) end, 1)()
end

---Test helper: clears the in-memory cache.
function M._reset_cache_for_tests() _cache = {} end

---Test helper: pre-seeds an entry in the cache.
---@param instance_url string
---@param username string
---@param user_id string
function M._seed_cache_for_tests(instance_url, username, user_id)
	_cache[_cache_key(instance_url, username)] = user_id
end

---Test helper: exposes the internal query function so tests can supply a
---fake curl-request factory and verify the query/parsing contract.
M._query_user_id_for_tests = _query_user_id

return M
