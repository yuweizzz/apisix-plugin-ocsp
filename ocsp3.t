#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#
use t::APISIX 'no_plan';

repeat_each(1);
log_level('info');
no_root_location();
no_shuffle();

my $openssl_bin = $ENV{OPENSSL_BIN};
if (! -x $openssl_bin) {
    $ENV{OPENSSL_BIN} = '/usr/bin/openssl';
    if (! -x $ENV{OPENSSL_BIN}) {
        plan(skip_all => "openssl3 not installed");
    }
}

add_block_preprocessor(sub {
    my ($block) = @_;

    # setup default conf.yaml
    my $extra_yaml_config = $block->extra_yaml_config // <<_EOC_;
plugins:
    - ocsp
_EOC_

    $block->set_value("extra_yaml_config", $extra_yaml_config);

    if (!$block->request) {
        $block->set_value("request", "GET /t");
    }
});

run_tests;

__DATA__

=== TEST 1: cert with ocsp supported and good status when enabled ocsp plugin
--- config
location /t {
    content_by_lua_block {
        local core = require("apisix.core")
        local t = require("lib.test_admin")

        local ssl_cert = t.read_file("t/apisix-plugin-ocsp/rsa_good.crt")
        local ssl_key =  t.read_file("t/apisix-plugin-ocsp/rsa_good.key")

        local data = {
            cert = ssl_cert,
            key = ssl_key,
            sni = "ocsp.test.com",
            ocsp = {
                ssl_stapling = true
            }
        }

        local code, body = t.test('/apisix/admin/ssls/1',
            ngx.HTTP_PUT,
            core.json.encode(data)
        )

        if code >= 300 then
            ngx.status = code
            ngx.say(body)
            return
        end

        ngx.say(body)
    }
}
--- response_body
passed



=== TEST 2: run ocsp responder, return without nextupdate
--- config
location /t {
    content_by_lua_block {
        local shell = require("resty.shell")
        local cmd = [[ /usr/bin/openssl ocsp -index t/apisix-plugin-ocsp/index.txt -port 11451 -rsigner t/apisix-plugin-ocsp/signer.crt -rkey t/apisix-plugin-ocsp/signer.key -CA t/apisix-plugin-ocsp/apisix.crt -nrequest 2 2>&1 1>/dev/null & ]]
        local ok, stdout, stderr, reason, status = shell.run(cmd, nil, 1000, 8096)
        if not ok then
            ngx.log(ngx.WARN, "failed to execute the script with status: " .. status .. ", reason: " .. reason .. ", stderr: " .. stderr)
            return
        end
        ngx.print(stderr)
    }
}



=== TEST 3: hit, handshake ok, no nextupdate, no need to cache response:1
--- exec
echo -n "Q" | $OPENSSL_BIN s_client -status -connect localhost:1994 -servername ocsp.test.com 2>&1 | cat
--- max_size: 16096
--- response_body eval
qr/CONNECTED/
--- no_error_log
fetch ocsp response ok, cache with ttl



=== TEST 4: hit, get ocsp response and status is good, no nextupdate, no need to cache response:2
--- exec
echo -n "Q" | $OPENSSL_BIN s_client -status -connect localhost:1994 -servername ocsp.test.com 2>&1 | cat
--- max_size: 16096
--- response_body eval
qr/Cert Status: good/
--- no_error_log
fetch ocsp response ok, cache with ttl



=== TEST 5: run ocsp responder, return with nextupdate
--- config
location /t {
    content_by_lua_block {
        local shell = require("resty.shell")
        local cmd = [[ /usr/bin/openssl ocsp -index t/apisix-plugin-ocsp/index.txt -port 11451 -rsigner t/apisix-plugin-ocsp/signer.crt -rkey t/apisix-plugin-ocsp/signer.key -CA t/apisix-plugin-ocsp/apisix.crt -nmin +10 -nrequest 2 2>&1 1>/dev/null & ]]
        local ok, stdout, stderr, reason, status = shell.run(cmd, nil, 1000, 8096)
        if not ok then
            ngx.log(ngx.WARN, "failed to execute the script with status: " .. status .. ", reason: " .. reason .. ", stderr: " .. stderr)
            return
        end
        ngx.print(stderr)
    }
}



=== TEST 6: hit, handshake ok, will cache ocsp response:1
--- exec
echo -n "Q" | $OPENSSL_BIN s_client -status -connect localhost:1994 -servername ocsp.test.com 2>&1 | cat
--- max_size: 16096
--- response_body eval
qr/CONNECTED/
--- error_log
fetch ocsp response ok, cache with ttl: 600 seconds



=== TEST 7: hit, get ocsp response and status is good, will cache ocsp response:2
--- exec
echo -n "Q" | $OPENSSL_BIN s_client -status -connect localhost:1994 -servername ocsp.test.com 2>&1 | cat
--- max_size: 16096
--- response_body eval
qr/Cert Status: good/
--- error_log
fetch ocsp response ok, cache with ttl: 600 seconds



=== TEST 8: cert with ocsp supported and revoked status when enabled ocsp plugin
--- config
location /t {
    content_by_lua_block {
        local core = require("apisix.core")
        local t = require("lib.test_admin")

        local ssl_cert = t.read_file("t/apisix-plugin-ocsp/rsa_revoked.crt")
        local ssl_key =  t.read_file("t/apisix-plugin-ocsp/rsa_revoked.key")

        local data = {
            cert = ssl_cert,
            key = ssl_key,
            sni = "ocsp-revoked.test.com",
            ocsp = {
                ssl_stapling = true,
            }
        }

        local code, body = t.test('/apisix/admin/ssls/1',
            ngx.HTTP_PUT,
            core.json.encode(data)
        )

        if code >= 300 then
            ngx.status = code
            ngx.say(body)
            return
        end

        ngx.say(body)
    }
}
--- response_body
passed



=== TEST 9: run ocsp responder, return with nextupdate
--- config
location /t {
    content_by_lua_block {
        local shell = require("resty.shell")
        local cmd = [[ /usr/bin/openssl ocsp -index t/apisix-plugin-ocsp/index.txt -port 11451 -rsigner t/apisix-plugin-ocsp/signer.crt -rkey t/apisix-plugin-ocsp/signer.key -CA t/apisix-plugin-ocsp/apisix.crt -nrequest 2 -nmin +10 2>&1 1>/dev/null & ]]
        local ok, stdout, stderr, reason, status = shell.run(cmd, nil, 1000, 8096)
        if not ok then
            ngx.log(ngx.WARN, "failed to execute the script with status: " .. status .. ", reason: " .. reason .. ", stderr: " .. stderr)
            return
        end
        ngx.print(stderr)
    }
}



=== TEST 10: hit revoked rsa cert, handshake ok, invalid status will not cache response:1
--- exec
echo -n "Q" | $OPENSSL_BIN s_client -status -connect localhost:1994 -servername ocsp-revoked.test.com 2>&1 | cat
--- response_body eval
qr/CONNECTED/
--- error_log
no ocsp response send: failed to validate ocsp response: certificate status "revoked" in the OCSP response
--- no_error_log
fetch ocsp response ok, cache with ttl



=== TEST 11: hit revoked rsa cert, no ocsp response send, invalid status will not cache response:2
--- exec
echo -n "Q" | $OPENSSL_BIN s_client -status -connect localhost:1994 -servername ocsp-revoked.test.com 2>&1 | cat
--- response_body eval
qr/OCSP response: no response sent/
--- error_log
no ocsp response send: failed to validate ocsp response: certificate status "revoked" in the OCSP response
--- no_error_log
fetch ocsp response ok, cache with ttl



=== TEST 12: enable mtls and ocsp plugin in route, enable client cert ocsp verify
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin")
            local json = require("toolkit.json")
            local ssl_ca_cert = t.read_file("t/apisix-plugin-ocsp/apisix.crt")
            local ssl_cert = t.read_file("t/apisix-plugin-ocsp/mtls_server.crt")
            local ssl_key  = t.read_file("t/apisix-plugin-ocsp/mtls_server.key")
            local data = {
                plugins = {
                    ["ocsp"] = {},
                },
                upstream = {
                    type = "roundrobin",
                    nodes = {
                        ["127.0.0.1:1980"] = 1,
                    },
                },
                uri = "/hello"
            }
            assert(t.test('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                json.encode(data)
            ))

            local data = {
                cert = ssl_cert,
                key = ssl_key,
                sni = "admin.apisix.dev",
                client = {
                    ca = ssl_ca_cert,
                },
                ocsp = {
                    ssl_ocsp = "leaf",
                }
            }
            local code, body = t.test('/apisix/admin/ssls/1',
                ngx.HTTP_PUT,
                json.encode(data)
            )

            if code >= 300 then
                ngx.status = code
            end
            ngx.print(body)
        }
    }
--- request
GET /t



=== TEST 13: run ocsp responder, return without nextupdate
--- config
location /t {
    content_by_lua_block {
        local shell = require("resty.shell")
        local cmd = [[ /usr/bin/openssl ocsp -index t/apisix-plugin-ocsp/index.txt -port 11451 -rsigner t/apisix-plugin-ocsp/signer.crt -rkey t/apisix-plugin-ocsp/signer.key -CA t/apisix-plugin-ocsp/apisix.crt -nrequest 3 2>&1 1>/dev/null & ]]
        local ok, stdout, stderr, reason, status = shell.run(cmd, nil, 1000, 8096)
        if not ok then
            ngx.log(ngx.WARN, "failed to execute the script with status: " .. status or "nil" .. ", reason: " .. reason .. ", stderr: " .. stderr)
            return
        end
        ngx.print(stderr)
    }
}



=== TEST 14: enabled client cert ocsp verify, mtls passed when client cert is good status, not cache response
--- exec
curl -i -v https://admin.apisix.dev:1994/hello --resolv admin.apisix.dev:1994:127.0.0.1 --cacert t/apisix-plugin-ocsp/mtls_ca.crt --cert t/apisix-plugin-ocsp/rsa_good.crt --key t/apisix-plugin-ocsp/rsa_good.key 2>&1 | cat
--- response_body eval
qr/hello world/
--- error_log
validate client cert ocsp response ok
--- no_error_log
fetch ocsp response ok, cache with ttl



=== TEST 15: enabled client cert ocsp verify, mtls failed when client cert is unknown status, not cache response
--- exec
curl -i -v https://admin.apisix.dev:1994/hello --resolv admin.apisix.dev:1994:127.0.0.1 --cacert t/apisix-plugin-ocsp/mtls_ca.crt --cert t/apisix-plugin-ocsp/rsa_unknown.crt --key t/apisix-plugin-ocsp/rsa_unknown.key 2>&1 | cat
--- response_body eval
qr/400 Bad Request/
--- error_log
failed to validate ocsp response: certificate status "unknown" in the OCSP response
--- no_error_log
fetch ocsp response ok, cache with ttl



=== TEST 16: enabled client cert ocsp verify, mtls failed when client cert is revoked status, not cache response
--- exec
curl -i -v https://admin.apisix.dev:1994/hello --resolv admin.apisix.dev:1994:127.0.0.1 --cacert t/apisix-plugin-ocsp/mtls_ca.crt --cert t/apisix-plugin-ocsp/rsa_revoked.crt --key t/apisix-plugin-ocsp/rsa_revoked.key 2>&1 | cat
--- response_body eval
qr/400 Bad Request/
--- error_log
failed to validate ocsp response: certificate status "revoked" in the OCSP response
--- no_error_log
fetch ocsp response ok, cache with ttl



=== TEST 17: run ocsp responder, return with nextupdate
--- config
location /t {
    content_by_lua_block {
        local shell = require("resty.shell")
        local cmd = [[ /usr/bin/openssl ocsp -index t/apisix-plugin-ocsp/index.txt -port 11451 -rsigner t/apisix-plugin-ocsp/signer.crt -rkey t/apisix-plugin-ocsp/signer.key -CA t/apisix-plugin-ocsp/apisix.crt -nmin +10 -nrequest 3 2>&1 1>/dev/null & ]]
        local ok, stdout, stderr, reason, status = shell.run(cmd, nil, 1000, 8096)
        if not ok then
            ngx.log(ngx.WARN, "failed to execute the script with status: " .. status or "nil" .. ", reason: " .. reason .. ", stderr: " .. stderr)
            return
        end
        ngx.print(stderr)
    }
}



=== TEST 18: enabled client cert ocsp verify, mtls passed when client cert is good status, will cache response
--- exec
curl -i -v https://admin.apisix.dev:1994/hello --resolv admin.apisix.dev:1994:127.0.0.1 --cacert t/apisix-plugin-ocsp/mtls_ca.crt --cert t/apisix-plugin-ocsp/rsa_good.crt --key t/apisix-plugin-ocsp/rsa_good.key 2>&1 | cat
--- response_body eval
qr/hello world/
--- error_log
fetch ocsp response ok, cache with ttl: 600 seconds
validate client cert ocsp response ok



=== TEST 19: enabled client cert ocsp verify, mtls passed when client cert is good status, will cache response
--- exec
curl -i -v https://admin.apisix.dev:1994/hello --resolv admin.apisix.dev:1994:127.0.0.1 --cacert t/apisix-plugin-ocsp/mtls_ca.crt --cert t/apisix-plugin-ocsp/ecc_good.crt --key t/apisix-plugin-ocsp/ecc_good.key 2>&1 | cat
--- response_body eval
qr/hello world/
--- error_log
fetch ocsp response ok, cache with ttl: 600 seconds
validate client cert ocsp response ok



=== TEST 20: enabled client cert ocsp verify, mtls failed when client cert is unknown status, invalid status will not cache response
--- exec
curl -i -v https://admin.apisix.dev:1994/hello --resolv admin.apisix.dev:1994:127.0.0.1 --cacert t/apisix-plugin-ocsp/mtls_ca.crt --cert t/apisix-plugin-ocsp/rsa_unknown.crt --key t/apisix-plugin-ocsp/rsa_unknown.key 2>&1 | cat
--- response_body eval
qr/400 Bad Request/
--- error_log
failed to validate ocsp response: certificate status "unknown" in the OCSP response



=== TEST 21: enabled client cert ocsp verify, mtls failed when client cert is revoked status, invalid status will not cache response
--- exec
curl -i -v https://admin.apisix.dev:1994/hello --resolv admin.apisix.dev:1994:127.0.0.1 --cacert t/apisix-plugin-ocsp/mtls_ca.crt --cert t/apisix-plugin-ocsp/rsa_revoked.crt --key t/apisix-plugin-ocsp/rsa_revoked.key 2>&1 | cat
--- response_body eval
qr/400 Bad Request/
--- error_log
failed to validate ocsp response: certificate status "revoked" in the OCSP response
