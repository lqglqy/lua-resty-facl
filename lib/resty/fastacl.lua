local _M = {}

local etcd_conf = {
protocol = "v3", api_prefix="/v3", ssl_verify=false, 
http_host = "http://127.0.0.1:2379", 
user = "waf", password="waf", serializer="raw"
}
local etcd_key = "/waf/service/fastacl/prd/t1"

local types_dict_name = "fastacl_types_zone"
local block_dict_name = "fastacl_block_zone"

local exiting = ngx.worker.exiting
local etcd_cli = nil
local sub_str      = string.sub
local function short_key(key, str)
    return sub_str(str, #key + 2)
end


local etcd = require "resty.etcd"
local cjson = require "cjson"
local bit = require "bit"
local xpcall = xpcall
local _init_flag_ = false
local resync_delay = 0.05


local ngx_sleep    = ngx.sleep
local prev_index = 0
local function upgrade_version(new_ver)
    new_ver = tonumber(new_ver)
    if not new_ver then
        return
    end

    local pre_index = prev_index

    if new_ver <= pre_index then
        return
    end

    prev_index = new_ver
    return
end
local function readdir(etcd_cli, key)
    if not etcd_cli then
        return nil, "not inited"
    end

    local res, err = etcd_cli:readdir(key)
    if not res then
        ngx.log(ngx.ERR,"failed to get key from etcd: ", err)
        return nil, err
    end

    if type(res.body) ~= "table" then
        return nil, "failed to read etcd dir"
    end

    return res
end

local function string_split (inputstr, sep)
        if sep == nil then
                sep = "%s"
        end
        local t={}
        for str in string.gmatch(inputstr, "([^"..sep.."]+)") do
                table.insert(t, str)
        end
        return t
end

local function block_hash_insert(key, value, block_type)
		
	local shash = ngx.shared[block_dict_name]
	local val = shash:get(value)
	if val then
		if val == value then
			ngx.log(ngx.ERR,"alread set key in dict: ", value, " value: ", val)
		else 
			ngx.log(ngx.ERR,"conflict key: ", value, " old value: ", val, " new value: ", key_mark)
		end
	else
		shash:set(value, key)
		ngx.log(ngx.ERR,"block set Key: ", value, " Val: ", key, " success!!!")
	end
	
	local thash = ngx.shared[types_dict_name]
	local tval = thash:get(block_type)
	if not tval then
		thash:set(block_type, 1)
		ngx.log(ngx.ERR,"types set Key: ", block_type)
	else 
		local nval, err = thash:incr(block_type)
		ngx.log(ngx.ERR,"types : ", blocak_type, " count: ", nval)
	end

end

local function block_hash_delete(key, value, block_type)
		
	local shash = ngx.shared[block_dict_name]
	local val = shash:get(value)
	if val then
		if val == block_type then
			shash:delete(value)
			ngx.log(ngx.ERR,"delete : ", value, " val: ", val, " success!")
		else 
			ngx.log(ngx.ERR,"conflict key: ", value, " old value: ", val, " del value: ", block_type)
		end
	else
		ngx.log(ngx.ERR,"Not found Key: ", value, " Val: ", block_type)
	end
	
	-- clean types dict zone
	local thash = ngx.shared[types_dict_name]
	local tval = thash:get(block_type)
	if tval then
		local nval, err = thash:incr(block_type, -1)
		if nval == 0 then
			thash:delete(block_type)
			ngx.log(ngx.ERR,"delete types: ", block_type)
		end
		ngx.log(ngx.ERR,"types : ", block_type, " count: ", nval)
	end

end
local function process_item(key, value, opt)
	local key_table = string_split(key, ":")
	if #key_table ~= 2 then
		ngx.log(ngx.ERR,"rule key name split failed: ", key)
		return "key split failed"
	end
	local block_type = key_table[1]
	local block_name = key_table[2]
	ngx.log(ngx.ERR, "block type: ", block_type)
	local var_table = string_split(block_type, "+")

	if opt == "add" then
		block_hash_insert(key, value, block_type)
	else 
		if opt == "del" then
			block_hash_delete(key, value)
		else 
			ngx.log(ngx.ERR, "opt ", opt, " not support")
		end
	end
end
local function init_from_etcd()
	local res, err = readdir(etcd_cli, etcd_key)
        if not res then
                ngx.log(ngx.ERR,"readdir failed: ", err)
                return false, err
        end
        local dir_res, headers = res.body or {}, res.headers
        if not dir_res then
            ngx.log(ngx.ERR,"readdir key: ", conf.key, " res type: ", type(dir_res))
            return false, err
        end

        for k, v in ipairs(dir_res) do
                ngx.log(ngx.ERR,"dir_res ", k, " ", v)
        end

        for _, item in ipairs(dir_res.kvs) do
                local key = short_key(etcd_key, item.key)
                ngx.log(ngx.ERR,"item key: ", item.key, " short key: ", key, " value: ", item.value)
		process_item(key, item.value, "add")
                upgrade_version(item.mod_revision)
        end
	if headers then
            upgrade_version(headers["X-Etcd-Index"])
        end
end
local wait_timeout = 30
local function waitdir(etcd_cli, key, modified_index, timeout)
        if not etcd_cli then
                return nil, nil, "not inited"
        end
        local opts = {}
        opts.start_revision = modified_index
        opts.timeout = timeout
        opts.need_cancel = true
	opts.prev_kv = true
        local res_func, unfc_err, http_cli = etcd_cli:watchdir(key, opts)
        if not res_func then
                return nil, func_err
        end

        -- in etcd v3, the 1st res of watch is watch info, useless to us
        -- try twice to skip create info
        local res, err = res_func()
        if not res or not res.result or not res.result.events then
                res, err = res_func()
        end

        if http_cli then
                local res_cancel, err_cancel = etcd_cli:watchcancel(http_cli)
                if res_cancel == 1 then
                        ngx.log(ngx.DEBUG, "cancel watch connection success")
                else
                        ngx.log(ngx.ERR, "cancel watch failed: ", err_cancel)
                end
        end

        return res, err
end

local function sync_data(conf)
        if not _init_flag_ then
		init_from_etcd()
		_init_flag_ = true
        end
	  local dir_res, err = waitdir(etcd_cli, etcd_key, prev_index + 1, wait_timeout)
	if err then
		ngx.log(ngx.ERR,"waitdir key: ", etcd_key, " failed: ", err)
		return false, err
	end
	ngx.log(ngx.ERR, "begin process event :dir_res type: ", type(dir_res))
	for k, v in pairs(dir_res) do
		for kk, vv in pairs(v.events) do
			if vv.kv then
				ngx.log(ngx.ERR, "key: ", vv.kv.key, " val: ", vv.kv.value)
				local key = short_key(etcd_key, vv.kv.key)
				ngx.log(ngx.ERR," short key: ", key)
				if vv.type and vv.type == "DELETE" then
					if vv.prev_kv then
						process_item(key, vv.prev_kv.value, "del")
					else
						ngx.log(ngx.ERR, "Not Found Prev KV in EVENT!!!!")
					end
				else	
					process_item(key, vv.kv.value, "add")
				end
				upgrade_version(vv.kv.mod_revision)
			end
		end
	end
end
local conf_handler
conf_handler = function (premature)
	if premature then
		return
	end

	local i = 0
	while not exiting() and i <= 32 do
		i = i + 1
		local ok, err = xpcall(function()
			if not etcd_cli then
				ngx.log(ngx.ERR,"new endpoints host: ", etcd_conf.http_host)
				local cli, err = etcd.new(etcd_conf)
				if not cli then
					ngx.log(ngx.ERR,"failed to create etcd instance: ", err)
				end
				etcd_cli = cli
			end
			local ok, err = sync_data()
			if err then 
				ngx.log(ngx.ERR,"sync data failed: ", err)
				ngx_sleep(resync_delay)
			end
		end, debug.traceback)
		if not ok then
			ngx.log(ngx.ERR,"failed to fetch data from etcd: ", err)
			ngx_sleep(resync_delay)
			break
		end
	end
	if not exiting() then
                ngx.timer.at(0, conf_handler)
        end
end

local logopts = {
	--type = "kafka",
	--server = "127.0.0.1:9092",
	--topic = "fast_acl",
	type = "file",
	filename = "/usr/local/openresty/nginx/logs/waf.log"
}

local write_log = {
	error = function(t)
		ngx.log(ngx.ERR, cjson.encode(t))
	end,
	file = function(t)
		if not logopts.filename then
			ngx.log(ngx.ERR, "Event log target path is undefined in fast acl")
			return
		end
		local f = io.open(logopts.filename, 'a')
		if not f then
			ngx.log(ngx.ERR, "Could not open" .. logopts.filename)
			return
		end
		f:write(cjson.encode(t), "\n")
                f:close()
	end,
	kafka = function(waf, t)
                local bp = producer:new(logopts.server,
                                                { producer_type = "async" })
                local ok, err = bp:send(logopts.topic,
                                        "",
                                        cjson.encode(t))
                if not ok then
                        ngx.log(ngx.ERR, "Event log send to kafka fail:", err)
                end
        end
}

local function init_log(opts)
	if opts and opts.log then
		logopts = opts.log
	end
	ngx.log(ngx.ERR, "log type:",logopts.type, " log server: ", logopts.server, " log topic: ", logopts.topic)
end

function _M.init(opts)
	init_log(opts)
	local worker = ngx.worker
	if worker.id() ~= 0 then
		ngx.log(ngx.ERR,"worker ", worker.id(), " not need init!!!")
		return
	end
	ngx.log(ngx.ERR,"start init fast acl ", worker.id())
	local ok, err = ngx.timer.at(0, conf_handler)
	if not ok then
		ngx.log(ngx.ERR, "failed create the timer: ", err)
		return
	end
	
end

function _M.new()
-- load acl from database
	ngx.log(ngx.ERR, "_init_fast_acl: ")
end

-- return a single table from multiple tables containing request data
-- note that collections that are not a table (e.g. REQUEST_BODY with
-- a non application/x-www-form-urlencoded content type) are ignored
local function common_args(collections)
        local t = {}

        for _, collection in pairs(collections) do
                if type(collection) == "table" then
                        for k, v in pairs(collection) do
                                if t[k] == nil then
                                        t[k] = v
                                else
                                        if type(t[k]) == "table" then
                                                table_insert(t[k], v)
                                        else
                                                local _v = t[k]
                                                t[k] = { _v, v }
                                        end
                                end
                        end
                end
        end

        return t
end
local function get_var_content(key, vars, request_uri_args, request_headers, request_common_args)
	local vtab = string_split(key, "-")
	if #vtab ~= 2 then
		return ""
	end
	local var_type = vtab[1]
	local var_name = vtab[2]
	if var_type == "var" then
		if var_name == "ip" then
			return vars.remote_addr
		else if var_name == "host" then
			return vars.host
		else if var_name == "path" then
			return vars.uri
		end
	else if var_type == "rh" then
		return request_headers[var_name]
	else if var_type == "rca" then
		return request_common_args[var_name]
	else if var_type == "rua" then
		return request_uri_args[var_name]
	end
	return ""
end
local function construct_serach_key(key, vars, request_uri_args, request_headers, request_common_args)
	local var_talbe = string_split(key, "+")
	local rkey = ""
	for i=1, #var_table do
		rkey = rkey .. get_var_content(var_table[i])
	end
	return rkey
		
end
local function fastacl_check()
	local var = ngx.var
	local request_uri_args    = ngx.req.get_uri_args()
	local request_headers     = ngx.req.get_headers()
	local request_common_args = common_args({ request_uri_args, request_body, request_cookies })
	--[[
	local vars = {ip = var.remote_addr, host = var.host, path = var.uri,
		      ua = request_headers["user_agent"], token = request_common_args["token"], 
			query_m = request_uri_args["_m"],
			device_id = request_common_args["device_id"],
			referer = request_headers["http_referer"]}
	--]]
	local tzone = ngx.shared[types_dict_name]
	local tys = tzone:get_keys(0)
	for i=1, #tys do
		ngx.log(ngx.ERR,"process type: ", tys[i])
		local skey = construct_serach_key(tys[i], var, request_uri_args, request_headers, request_common_args)
		if skey ~= "" then
			local szone = ngx.shared[block_dict_name]
			ngx.log(ngx.ERR,"seraching key: ", skey)
			local sval = szone:get(skey)
			if sval then
				ngx.log(ngx.ERR,"Hit key: ", skey, " val: ", sval)
				return sval
			end
		end
	end
	return nil,nil, nil
end

local random = require "resty.random"
local function random_bytes(len)
	local string = require "resty.string"
        return string.to_hex(random.bytes(len))
end

local function write_event_log(rulename, rule)
	local request_method      = ngx.req.get_method()
	local request_headers     = ngx.req.get_headers()
	local request_uri_args    = ngx.req.get_uri_args()
	local request_common_args = common_args({ request_uri_args, request_body, request_cookies })
	local var = ngx.var
	local entry = {
                timestamp = ngx.time(),
                client    = var.remote_addr,
                method    = request_method,
                uri       = var.uri,
                alerts    = {{id=rulename,msg=rule,match="fastacl"}} ,
                id        = random_bytes(10),
		ngx       = {host = var.host,
			     http_user_agent = request_headers["user_agent"], token = request_common_args["token"], 
			     query_m = request_uri_args["_m"],
			     device_id = request_common_args["device_id"],
			     http_referer = request_headers["http_referer"]}
        }
	write_log[logopts.type](entry)
end

function _M.check()
	local v = fastacl_check()
	if v then
		-- TODO waf logs
		local vtab = string_split(v, ":")
		if vtab ~= 2 then
			ngx.log(ngx.ERR, "val type error: ", v)
		else
			write_event_log(vtab[1], vtab[2])
		end
		ngx.status = ngx.HTTP_NO_CONTENT
		ngx.exit(ngx.status)
	end
	return 
end

return _M
