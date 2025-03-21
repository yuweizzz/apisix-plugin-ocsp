--
-- Licensed to the Apache Software Foundation (ASF) under one
-- or more contributor license agreements.  See the NOTICE file
-- distributed with this work for additional information
-- regarding copyright ownership.  The ASF licenses this file
-- to you under the Apache License, Version 2.0 (the
-- "License"); you may not use this file except in compliance
-- with the License.  You may obtain a copy of the License at
--
--   http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing,
-- software distributed under the License is distributed on an
-- "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
-- KIND, either express or implied.  See the License for the
-- specific language governing permissions and limitations
-- under the License.
--

local ngx = ngx
local require = require
local http = require("resty.http")
local ngx_ocsp = require("ngx.ocsp")
local ngx_ssl = require("ngx.ssl")
local radixtree_sni = require("apisix.ssl.router.radixtree_sni")
local core = require("apisix.core")

local plugin_name = "ocsp"
local ocsp_resp_cache = ngx.shared[plugin_name]

local plugin_schema = {
    type = "object",
    properties = {},
}

local _M = {
    name = plugin_name,
    schema = plugin_schema,
    version = 0.3,
    priority = -44,
}


function _M.check_schema(conf)
    return core.schema.check(plugin_schema, conf)
end


local function fetch_ocsp_resp(der_cert_chain, responder)
    core.log.info("fetch ocsp response from responder")

    if not responder then
        return nil, "no specified responder"
    end

    local ocsp_req, err = ngx_ocsp.create_ocsp_request(der_cert_chain)
    if not ocsp_req then
        return nil, "failed to create ocsp request: " .. err
    end

    local httpc = http.new()
    local res
    res, err = httpc:request_uri(responder, {
        method = "POST",
        headers = {
            ["Content-Type"] = "application/ocsp-request",
        },
        body = ocsp_req
    })

    if not res then
        return nil, "ocsp responder query failed: " .. err
    end

    local http_status = res.status
    if http_status ~= 200 then
        return nil, "ocsp responder returns bad http status code: "
               .. http_status
    end

    if res.body and #res.body > 0 then
        return res.body, nil
    end

    return nil, "ocsp responder returns 200 and empty response body"
end


local function set_ocsp_resp(der_cert_chain, responder, need_verify)
    local ocsp_resp = ocsp_resp_cache:get(der_cert_chain)
    if ocsp_resp == nil then
        core.log.info("ocsp response cache not found, fetch it from ocsp responder")
        local err
        ocsp_resp, err = fetch_ocsp_resp(der_cert_chain, responder)
        if ocsp_resp == nil then
            return false, err
        end
    end

    if need_verify then
        local ok, next_update_or_err = ngx_ocsp.validate_ocsp_response(ocsp_resp, der_cert_chain)
        if not ok then
            return false, "failed to validate ocsp response: " .. next_update_or_err
        end
        -- next_update present
        if next_update_or_err ~= nil then
            local ttl = next_update_or_err - ngx.time()
            ocsp_resp_cache:set(der_cert_chain, ocsp_resp, ttl)
            core.log.info("fetch ocsp response ok, cache with ttl: " .. ttl .. " seconds")
        end
    end

    -- set the OCSP stapling
    local ok, err = ngx_ocsp.set_ocsp_status_resp(ocsp_resp)
    if not ok then
        return false, "failed to set ocsp status response: " .. err
    end

    return true
end


local original_set_cert_and_key
local function set_cert_and_key(sni, value)
    if value.gm then
        -- should not run with gm plugin
        core.log.warn("gm plugin enabled, no need to run ocsp-stapling plugin")
        return original_set_cert_and_key(sni, value)
    end

    if not value.ocsp then
        core.log.info("no 'ocsp' field found, no need to run ocsp plugin")
        return original_set_cert_and_key(sni, value)
    end

    if not value.ocsp.ssl_stapling then
        return original_set_cert_and_key(sni, value)
    end

    if not ngx.ctx.tls_ext_status_req then
        core.log.info("no status request required, no need to send ocsp response")
        return original_set_cert_and_key(sni, value)
    end

    local ok, err = radixtree_sni.set_pem_ssl_key(sni, value.cert, value.key)
    if not ok then
        return false, err
    end
    local fin_pem_cert = value.cert

    -- multiple certificates support.
    if value.certs then
        for i = 1, #value.certs do
            local cert = value.certs[i]
            local key = value.keys[i]
            ok, err = radixtree_sni.set_pem_ssl_key(sni, cert, key)
            if not ok then
                return false, err
            end
            fin_pem_cert = cert
        end
    end

    local der_cert_chain
    der_cert_chain, err = ngx_ssl.cert_pem_to_der(fin_pem_cert)
    if not der_cert_chain then
        core.log.error("no ocsp response send: ", err)
        return true
    end

    local responder = value.ocsp.ssl_stapling_responder
    if responder == nil then
        -- no overrides responder, get ocsp responder from cert
        responder, err = ngx_ocsp.get_ocsp_responder_from_der_chain(der_cert_chain)
        if not responder then
            -- if cert not support ocsp, the report error is nil
            if not err then
                core.log.error("failed to get ocsp responder: " ..
                               "cert not contains authority_information_access extension")
                return true
            end
            core.log.error("failed to get ocsp responder: " .. err)
            return true
        end
    end

    ok, err = set_ocsp_resp(der_cert_chain,
                            responder,
                            value.ocsp.ssl_stapling_verify)
    if not ok then
        core.log.error("no ocsp response send: ", err)
    end

    return true
end


function _M.rewrite(conf, ctx)
    local scheme = ctx.var.scheme
    if scheme ~= "https" then
        return
    end

    local matched_ssl = ctx.matched_ssl
    if not matched_ssl.value.client then
        return
    end

    local ssl_ocsp = matched_ssl.value.ocsp.ssl_ocsp
    local client_verify_res = ctx.var.ssl_client_verify
    -- only client verify ok and ssl_ocsp is "leaf" need to validate ocsp response
    if ssl_ocsp == "leaf" and client_verify_res == "SUCCESS" then
        -- ssl_client_raw_cert will return client cert only, need to combine ca cert
        local full_chain_pem_cert = ctx.var.ssl_client_raw_cert .. matched_ssl.value.client.ca
        local der_cert_chain, err = ngx_ssl.cert_pem_to_der(full_chain_pem_cert)
        if not der_cert_chain then
            core.log.error("failed to convert client certificate from PEM to DER: ", err)
            -- return NGX_HTTPS_CERT_ERROR
            return 495
        end

        local ocsp_resp = ocsp_resp_cache:get(der_cert_chain)
        if ocsp_resp == nil then
            core.log.info("not ocsp resp cache found, fetch from ocsp responder")
            local responder = matched_ssl.value.ocsp.ssl_ocsp_responder
            if responder == nil then
                -- no overrides responder, get ocsp responder from cert
                responder, err = ngx_ocsp.get_ocsp_responder_from_der_chain(der_cert_chain)
                if not responder then
                    -- if cert not support ocsp, the report error is nil
                    if not err then
                        core.log.error("failed to get ocsp responder: " ..
                                       "cert not contains authority_information_access extension")
                        return 495
                    end
                    core.log.error("failed to get ocsp responder: " .. err)
                    return 495
                end
            end
            ocsp_resp, err = fetch_ocsp_resp(der_cert_chain, responder)
            if ocsp_resp == nil then
                core.log.error("failed to get ocsp respone: ", err)
                return 495
            end
        end

        local ocsp_ok, next_update_or_err = ngx_ocsp.validate_ocsp_response(ocsp_resp, der_cert_chain)
        if not ocsp_ok then
            core.log.error("failed to validate ocsp response: ", next_update_or_err)
            return 495
        end
        -- next_update present
        if next_update_or_err ~= nil then
            local ttl = next_update_or_err - ngx.time()
            ocsp_resp_cache:set(der_cert_chain, ocsp_resp, ttl)
            core.log.info("fetch ocsp response ok, cache with ttl: " .. ttl .. " seconds")
        end
        core.log.info("validate client cert ocsp response ok")
        return
    end
    core.log.info("no client cert ocsp verify required")
    return
end


function _M.init()
    if core.schema.ssl.properties.gm ~= nil then
        core.log.error("ocsp-stapling plugin should not run with gm plugin")
    end

    original_set_cert_and_key = radixtree_sni.set_cert_and_key
    radixtree_sni.set_cert_and_key = set_cert_and_key

    if core.schema.ssl.properties.ocsp ~= nil then
        core.log.error("Field 'ocsp' is occupied")
    end

    core.schema.ssl.properties.ocsp = {
        type = "object",
        properties = {
            ssl_stapling = {
                type = "boolean",
                default = false,
            },
            ssl_stapling_verify = {
                type = "boolean",
                default = true,
            },
            ssl_stapling_responder = {
                type = "string",
                pattern = [[^http://]],
            },
            ssl_ocsp = {
                type = "string",
                default = "off",
                enum = {"off", "leaf"},
            },
            ssl_ocsp_responder = {
                type = "string",
                pattern = [[^http://]],
            },
        }
    }

end


function _M.destroy()
    radixtree_sni.set_cert_and_key = original_set_cert_and_key
    core.schema.ssl.properties.ocsp = nil
    ocsp_resp_cache:flush_all()
end


return _M
