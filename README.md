## apisix-plugin-ocsp

[English](./en.md) | [中文](./zh.md)

## Changelog

### v0.1

import from apisix v3.9.0 release.

### v0.2

support ocsp validation of the client certificate.

### v0.3

- rename plugin from 'ocsp-stapling' to 'ocsp'.
- rename attributes, new attribute names are the same as the nginx directive.
- remove ttl settings, use nextupdate field as ttl time. This feature requires OpenResty version 1.27.1.1.

## Installation

### v0.2

Run: `cp ocsp-stapling.lua <path-to-apisix-source-code>/apisix/plugins/ocsp-stapling.lua`.

### v0.3

Run:

```
sed -i 's/ocsp-stapling/ocsp/g' <path-to-apisix-source-code>/apisix/cli/ngx_tpl.lua
cp ocsp.lua <path-to-apisix-source-code>/apisix/plugins/ocsp.lua
```

## Description

The `ocsp` Plugin dynamically sets the behavior of [OCSP stapling](https://nginx.org/en/docs/http/ngx_http_ssl_module.html#ssl_stapling) and [OCSP validation of the client certificate](https://nginx.org/en/docs/http/ngx_http_ssl_module.html#ssl_ocsp) in Nginx.

## Enable Plugin

This Plugin is disabled by default. Modify the config file to enable the plugin:

```yaml title="./conf/config.yaml"
plugins:
  - ...
  - ocsp
```

After modifying the config file, reload APISIX or send an hot-loaded HTTP request through the Admin API to take effect:

> [!TIP]
> You can fetch the `admin_key` from `config.yaml` and save to an environment variable with the following command:
>
> ```bash
> admin_key=$(yq '.deployment.admin.admin_key[0].key' conf/config.yaml | sed 's/"//g')
> curl http://127.0.0.1:9180/apisix/admin/plugins/reload -H "X-API-KEY: $admin_key" -X PUT
> ```

## Attributes

The attributes of this plugin are stored in specific field `ocsp` within SSL Resource.

| Name           | Type                 | Required | Default       | Valid values | Description                                                                                   |
|----------------|----------------------|----------|---------------|--------------|-----------------------------------------------------------------------------------------------|
| ssl_stapling   | boolean              | False    | false         |              | Like the `ssl_stapling` directive, enables or disables OCSP stapling feature.                 |
| ssl_stapling_verify    | boolean              | False    | true         |              | Like the `ssl_stapling_verify` directive, enables or disables verification of OCSP responses. |
| ssl_stapling_responder | string       | False    | ""            |"http://..."  | Like the `ssl_stapling_responder` directive, overrides the URL of the OCSP responder specified in the "Authority Information Access" certificate extension of server certificates. |
| ssl_ocsp    | string                  | False    | "off"         |["off", "leaf"]| Like the `ssl_ocsp` directive, enables or disables OCSP validation of the client certificate. |
| ssl_ocsp_responder        | string    | False    | ""            |"http://..."  | Like the `ssl_ocsp_responder` directive, overrides the URL of the OCSP responder specified in the "Authority Information Access" certificate extension for validation of client certificates.  |

> [!NOTE]
> In version v0.3, we don't need to specify TTL time anymore; use the 'next Update' field from OCSP responses as the time value.

## Example usage

You should create an SSL Resource first, and the certificate of the server certificate issuer should be known. Normally the fullchain certificate works fine.

Create an SSL Resource as such:

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

Next, establish a secure connection to the server, request the SSL/TLS session status, and display the output from the server:

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

To disable OCSP stapling feature, you can make a request as shown below:

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

## OCSP validation of the client certificate

This feature can be enabled on a specific Route, and requires that the current SSL resource has enabled mTLS mode.

Create an SSL Resource as such:

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

Enables this Plugin on the specified Route:

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

Once you have configured the Route as shown above, you can make a request as shown below:

```shell
curl --resolve "test.com:9443:127.0.0.1" https://test.com:9443/ -k --cert client.crt --key client.key
```

If the current client certificate OCSP validation passes, a normal response will be returned. If the validation fails or an error occurs during the validation process, an HTTP 400 certificate error response will be returned.

Disabling this feature only requires deleting the plugin on the corresponding route, but it should be noted that the OCSP stapling feature of the server certificate is still in effect and controlled by the corresponding SSL resource. You can set `ssl_ocsp` to `"off"` to disable all client certificate OCSP validation behavior for the current SSL resource.

```shell
# Disable client certificate OCSP validation behavior on specified Route
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

# Disable all client certificate OCSP validation behavior
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

## Delete Plugin

Make sure all your SSL Resource doesn't contains `ocsp` field anymore. To remove this field, you can make a request as shown below:

```shell
curl http://127.0.0.1:9180/apisix/admin/ssls/1 \
-H "X-API-KEY: $admin_key" -X PATCH -d '
{
    "ocsp": null
}'
```

Modify the config file `./conf/config.yaml` to disable the plugin:

```yaml title="./conf/config.yaml"
plugins:
  - ...
  # - ocsp
```

After modifying the config file, reload APISIX or send an hot-loaded HTTP request through the Admin API to take effect:

```shell
curl http://127.0.0.1:9180/apisix/admin/plugins/reload -H "X-API-KEY: $admin_key" -X PUT
```
