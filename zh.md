<!--
#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
-->

## 描述

`ocsp-stapling` 插件可以动态地设置 Nginx 中 [OCSP stapling](https://nginx.org/en/docs/http/ngx_http_ssl_module.html#ssl_stapling) 和 [客户端证书 OCSP 验证](https://nginx.org/en/docs/http/ngx_http_ssl_module.html#ssl_ocsp) 的相关行为。

## 启用插件

这个插件是默认禁用的，通过修改配置文件 `./conf/config.yaml` 来启用它：

```yaml
plugins:
  - ...
  - ocsp
```

修改配置文件之后，重启 APISIX 或者通过插件热加载接口来使配置生效：

> [!TIP]
> 您可以这样从 `config.yaml` 中获取 `admin_key` 并存入环境变量：
>
> ```bash
> admin_key=$(yq '.deployment.admin.admin_key[0].key' conf/config.yaml | sed 's/"//g')
> curl http://127.0.0.1:9180/apisix/admin/plugins/reload -H "X-API-KEY: $admin_key" -X PUT
> ```

## 属性

插件属性存储在 SSL 资源的 `ocsp_stapling` 字段中。

| 名称           | 类型                 | 必选项   | 默认值          | 有效值       | 描述                                                                  |
|----------------|----------------------|----------|---------------|--------------|-----------------------------------------------------------------------|
| ssl_stapling        | boolean              | False    | false         |              | 与 `ssl_stapling` 指令类似，用于启用或禁用 OCSP stapling 特性            |
| ssl_stapling_verify    | boolean              | False    | true         |              | 与 `ssl_stapling_verify` 指令类似，用于启用或禁用对于 OCSP 响应结果的校验 |
| ssl_stapling_responder | string       | False    | ""            |"http://..."  | 与 `ssl_stapling_responder` 指令类似，用于覆写服务端证书中的 OCSP 响应器 url 地址 |
| ssl_ocsp    | string                  | False    | "off"         |["off", "leaf"]| 与 `ssl_ocsp` 指令类似，用于启用或禁用对于客户端证书的 OCSP 验证 |
| ssl_ocsp_responder        | string    | False    | ""            |"http://..."  | 与 `ssl_ocsp_responder` 指令类似，用于覆写客户端证书中的 OCSP 响应器 url 地址  |

> [!NOTE]
> 升级到 v0.3 版本之后, 不再需要手动指定缓存时间，插件会使用 OCSP 响应中的 `next Update` 字段作为缓存时间值。

## 使用示例

首先您应该创建一个 SSL 资源，并且证书资源中应该包含颁发者的证书。通常情况下，全链路证书就可以正常工作。

如下示例中，生成相关的 SSL 资源：

```shell
curl http://127.0.0.1:9180/apisix/admin/ssls/1 \
-H "X-API-KEY: $admin_key" -X PUT -d '
{
    "cert" : "'"$(cat server.crt)"'",
    "key": "'"$(cat server.key)"'",
    "snis": ["test.com"],
    "ocsp": {
        "ssl_stapling": true
    }
}'
```

通过上述命令生成 SSL 资源后，可以通过以下方法测试：

```shell
echo -n "Q" | openssl s_client -status -connect localhost:9443 -servername test.com 2>&1 | cat
```

```
...
CONNECTED(00000003)
OCSP response:
======================================
OCSP Response Data:
    OCSP Response Status: successful (0x0)
...
```

可以通过以下方法禁用插件：

```shell
curl http://127.0.0.1:9180/apisix/admin/ssls/1 \
-H "X-API-KEY: $admin_key" -X PUT -d '
{
    "cert" : "'"$(cat server.crt)"'",
    "key": "'"$(cat server.key)"'",
    "snis": ["test.com"],
    "ocsp": {
        "ssl_stapling": false
    }
}'
```

## 客户端证书 OCSP 验证

客户端证书 OCSP 验证功能是基于路由运行的，并且需要当前的 SSL 资源已经开启了 mTLS 模式。

如下示例中，在 SSL 资源中配置相关的部分：

```shell
curl http://127.0.0.1:9180/apisix/admin/ssls/1 \
-H "X-API-KEY: $admin_key" -X PUT -d '
{
    "cert" : "'"$(cat server.crt)"'",
    "key": "'"$(cat server.key)"'",
    "snis": ["test.com"],
    "client": {
        "ca": "'"$(cat ca.crt)"'"
    },
    "ocsp": {
        "ssl_ocsp": "leaf"
    }
}'
```

配置需要进行客户端证书 OCSP 验证的路由资源：

```shell
curl -i http://127.0.0.1:9180/apisix/admin/routes/1 \
-H "X-API-KEY: $admin_key" -X PUT -d '
{
    "uri": "/",
    "plugins": {
        "ocsp": {}
    },
    "upstream": {
        "type": "roundrobin",
        "nodes": {
            "httpbin.org": 1
        }
    }
}'
```

通过上述命令完成更新后，可以通过以下方法测试：

```shell
curl --resolve "test.com:9443:127.0.0.1" https://test.com:9443/ -k --cert client.crt --key client.key
```

如果当前客户端证书 OCSP 验证通过，将会返回正常响应，验证失败或者验证过程中发生错误都会返回 HTTP 400 的证书错误响应。

因为这个功能是基于路由运行的，所以禁用这个功能只需要在对应路由上删除插件即可，但是需要注意此时服务端证书的 OCSP stapling 特性依然生效并且由对应的 SSL 资源控制。可以将 `ssl_ocsp` 设置为 `"off"` 来禁用当前 SSL 资源所有的客户端证书 OCSP 验证行为。

```shell
# 在当前路由上禁用客户端证书 OCSP 验证
curl -i http://127.0.0.1:9180/apisix/admin/routes/1 \
-H "X-API-KEY: $admin_key" -X PUT -d '
{
    "uri": "/",
    "upstream": {
        "type": "roundrobin",
        "nodes": {
            "httpbin.org": 1
        }
    }
}'

# 禁用所有客户端证书 OCSP 验证行为
curl http://127.0.0.1:9180/apisix/admin/ssls/1 \
-H "X-API-KEY: $admin_key" -X PUT -d '
{
    "cert" : "'"$(cat server.crt)"'",
    "key": "'"$(cat server.key)"'",
    "snis": ["test.com"],
    "client": {
        "ca": "'"$(cat ca.crt)"'"
    },
    "ocsp": {
        "ssl_ocsp": "off"
    }
}'
```

## 删除插件

在删除插件之前，需要确保所有的 SSL 资源都已经移除 `ocsp` 字段，可以通过以下命令实现对单个 SSL 资源的对应字段移除：

```shell
curl http://127.0.0.1:9180/apisix/admin/ssls/1 \
-H "X-API-KEY: $admin_key" -X PATCH -d '
{
    "ocsp": null
}'
```

通过修改配置文件 `./conf/config.yaml` 来禁用它：

```yaml
plugins:
  - ...
  # - ocsp
```

修改配置文件之后，重启 APISIX 或者通过插件热加载接口来使配置生效：

```shell
curl http://127.0.0.1:9180/apisix/admin/plugins/reload -H "X-API-KEY: $admin_key" -X PUT
```
