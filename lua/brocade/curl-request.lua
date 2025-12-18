local M = {}

local CurlRequest = {}
CurlRequest.__index = CurlRequest

function CurlRequest:new()
	local out = setmetatable({}, self)
	out.method = "GET"
	out.api_version = nil
	out.instance_url = nil
	out.access_token = nil
	out.suburl = nil
	out.tooling_suburl = nil
	out.data_key = nil
	out.data_value = nil
	out.json_data = nil
	out.is_expecting_json = true
	return out
end

function CurlRequest:set_method(m) self.method = m end
function CurlRequest:set_api_version(av) self.api_version = av end
function CurlRequest:set_instance_url(iu) self.instance_url = iu end
function CurlRequest:set_access_token(at) self.access_token = at end
function CurlRequest:set_suburl(su) self.suburl = su end
function CurlRequest:set_tooling_suburl(tsu) self.tooling_suburl = tsu end
function CurlRequest:set_json_data(jd) self.json_data = jd end
function CurlRequest:set_expect_json(is_expecting_json) self.is_expecting_json = is_expecting_json end
function CurlRequest:set_kv_data(k, v)
	self.data_key = k
	self.data_value = v
end

---@param auth_info brocade.org-session.AuthInfo
function CurlRequest:use_auth_info(auth_info)
	self:set_access_token(auth_info.get_access_token())
	self:set_api_version(auth_info.get_api_version())
	self:set_instance_url(auth_info.get_instance_url())
end

function CurlRequest:send(cb)
	-- required inputs:
	local instance_url = assert(self.instance_url)
	local api_version = assert(self.api_version)
	local access_token = assert(self.access_token)
	local method = assert(self.method)
	-- optional inputs:
	local tooling_suburl = self.tooling_suburl
	local json_data = self.json_data
	-- request building:
	local call_url = instance_url
	if self.suburl then
		call_url = call_url .. self.suburl
	elseif self.tooling_suburl then
		call_url = call_url .. "/services/data/" .. "v" .. api_version .. "/tooling" .. tooling_suburl
	else
		assert(false, "No URL of any variant given!")
	end
	local call_cmd = {
		"curl",
		"-s",
		"-H",
		"Authorization: Bearer " .. access_token,
	}
	if self.is_expecting_json then
		table.insert(call_cmd, "-H")
		table.insert(call_cmd, "Accept: application/json")
	end
	local call_stdin = nil
	if method == "GET" then
		table.insert(call_cmd, "-G")
		local data_key = self.data_key
		local data_value = self.data_value
		if data_key and data_value then
			table.insert(call_cmd, "--data-urlencode")
			table.insert(call_cmd, data_key .. "@-")
			call_stdin = data_value
		end
	elseif method == "POST" and json_data then
		table.insert(call_cmd, "-X")
		table.insert(call_cmd, "POST")
		table.insert(call_cmd, "-H")
		table.insert(call_cmd, "Content-Type: application/json")
		table.insert(call_cmd, "--data")
		table.insert(call_cmd, "@-")
		call_stdin = json_data
	elseif method == "DELETE" then
		table.insert(call_cmd, "-X")
		table.insert(call_cmd, "DELETE")
	elseif method == "PATCH" and json_data then
		table.insert(call_cmd, "-X")
		table.insert(call_cmd, "PATCH")
		table.insert(call_cmd, "-H")
		table.insert(call_cmd, "Content-Type: application/json")
		table.insert(call_cmd, "--data")
		table.insert(call_cmd, "@-")
		call_stdin = json_data
	end
	table.insert(call_cmd, call_url)
	vim.system(call_cmd, { stdin = call_stdin }, function(obj)
		if not self.is_expecting_json then
			local result = obj.stdout
			vim.notify(
				vim.inspect({ "call_cmd", call_cmd, "stdin", call_stdin, "result", result }),
				vim.log.levels.DEBUG
			)
			cb(result)
			return
		end

		local result_json = obj.stdout
		if not result_json then
			error("Response is incomplete!")
			return
		end
		local result_ok, result =
			pcall(vim.json.decode, result_json, { luanil = { array = true, object = true } })
		if not result_ok then
			error("Couldn't parse result JSON: " .. vim.inspect(result))
			return
		end
		vim.notify(
			vim.inspect({ "call_cmd", call_cmd, "stdin", call_stdin, "result", result }),
			vim.log.levels.DEBUG
		)
		cb(result)
	end)
end

M.CurlRequest = CurlRequest

return M
