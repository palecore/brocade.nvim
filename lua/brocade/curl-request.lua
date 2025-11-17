local M = {}

function M.CurlRequest()
	local self = {}
	local _self = {
		method = "GET",
		api_version = nil,
		instance_url = nil,
		access_token = nil,
		suburl = nil,
		tooling_suburl = nil,
		data_key = nil,
		data_value = nil,
		json_data = nil,
		is_expecting_json = true,
	}
	function self.set_method(m) _self.method = m end
	function self.set_api_version(av) _self.api_version = av end
	function self.set_instance_url(iu) _self.instance_url = iu end
	function self.set_access_token(at) _self.access_token = at end
	function self.set_suburl(su) _self.suburl = su end
	function self.set_tooling_suburl(tsu) _self.tooling_suburl = tsu end
	function self.set_json_data(jd) _self.json_data = jd end
	function self.set_expect_json(is_expecting_json) _self.is_expecting_json = is_expecting_json end
	function self.set_kv_data(k, v)
		_self.data_key = k
		_self.data_value = v
	end

	function self.send(cb)
		-- required inputs:
		local instance_url = assert(_self.instance_url)
		local api_version = assert(_self.api_version)
		local access_token = assert(_self.access_token)
		local method = assert(_self.method)
		-- optional inputs:
		local tooling_suburl = _self.tooling_suburl
		local json_data = _self.json_data
		-- request building:
		local call_url = instance_url
		if _self.suburl then
			call_url = call_url .. _self.suburl
		elseif _self.tooling_suburl then
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
		if _self.is_expecting_json then
			table.insert(call_cmd, "-H")
			table.insert(call_cmd, "Accept: application/json")
		end
		local call_stdin = nil
		if method == "GET" then
			table.insert(call_cmd, "-G")
			local data_key = _self.data_key
			local data_value = _self.data_value
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
			if not _self.is_expecting_json then
				local result = obj.stdout
				vim.notify(
					vim.inspect({ "call_cmd", call_cmd, "stdin", call_stdin, "result", result }),
					vim.log.levels.DEBUG
				)
				cb(result)
				return
			end
			--
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

	return self
end

return M
