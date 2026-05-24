# cloudfront-sni-alias

VLESS + WebSocket + TLS through AWS CloudFront using a custom alias domain as SNI.
Run `setup.sh` directly on the VPS to do everything automatically, or follow the steps below manually.

---

## Prerequisites

- Domain managed in Cloudflare
- AWS account with CLI configured (`aws configure`) — run on the VPS
- VPS on a non-blocked IP range (avoid Hetzner Helsinki, OVH, etc.)
- Dependencies handled automatically by `setup.sh` (curl, jq, unzip, AWS CLI)

---

## Step 1 — Cloudflare DNS

Add two records, both **not proxied** (grey cloud):

| Name | Type | Value |
|---|---|---|
| `yourdomain.com` | A | VPS IP |
| `cdn.yourdomain.com` | CNAME | *(CloudFront domain from Step 3)* |

The root A record is the CloudFront origin. The `cdn` CNAME is what clients put in the SNI —
it must not go through Cloudflare proxy because CloudFront terminates TLS for it.

---

## Step 2 — ACM Certificate

CloudFront requires its cert in **us-east-1** (N. Virginia).

```bash
aws acm request-certificate \
  --region us-east-1 \
  --domain-name cdn.yourdomain.com \
  --validation-method DNS
```

ACM returns a CNAME record. Add it to Cloudflare DNS (not proxied), then wait for status `ISSUED`:

```bash
aws acm describe-certificate --region us-east-1 \
  --certificate-arn <arn> \
  --query 'Certificate.Status'
```

---

## Step 3 — CloudFront Distribution

Create a distribution with these settings:

**Origin:**
- Domain: `yourdomain.com` (the root A record, not the cdn subdomain)
- Protocol: HTTPS only, port 443, TLSv1.2
- Read timeout: 60 s, keepalive timeout: 60 s

**Cache behavior:**
- Cache policy: `CachingDisabled`
- Origin request policy: `AllViewerExceptHostHeader`
- Allowed methods: all 7 (GET HEAD OPTIONS PUT POST PATCH DELETE)
- Viewer protocol: HTTPS only

**Distribution settings:**
- Alternate domain (CNAME): `cdn.yourdomain.com`
- ACM certificate: the one from Step 2
- **HTTP version: `http1.1` only** — required for WebSocket; `http2` silently breaks WS upgrades
- IPv6: enabled
- Price class: All edge locations

After creation, copy the distribution domain (`xxxx.cloudfront.net`) and update the
`cdn.yourdomain.com` CNAME in Cloudflare to point to it.

---

## Step 4 — TLS Cert on VPS

This cert is for the **CloudFront → VPS** connection (the origin leg). CloudFront connects to
`yourdomain.com:443` over HTTPS and validates the cert against trusted CAs — so it must be a
real publicly trusted cert (Let's Encrypt). A self-signed cert will be rejected by CloudFront.

The cert must cover both `yourdomain.com` (CloudFront connects using this as SNI) and
`cdn.yourdomain.com` (referenced in the xray inbound `serverName`).

The script handles this automatically. To do it manually:

```bash
curl -s https://get.acme.sh | sh
export CF_Token="<cloudflare-token-with-Zone:DNS:Edit>"
~/.acme.sh/acme.sh --issue --dns dns_cf \
  -d yourdomain.com -d cdn.yourdomain.com \
  --fullchain-file /root/cert/domain/fullchain.pem \
  --key-file /root/cert/domain/privkey.pem \
  --reloadcmd 'systemctl restart x-ui'
```

---

## Step 5 — xray Inbound (3x-ui)

Install 3x-ui if not already present:

```bash
bash -c "$(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/main/install.sh)"
```

Create a VLESS inbound with these settings:

| Setting | Value |
|---|---|
| Protocol | VLESS |
| Port | 443 |
| Transport | WebSocket |
| Path | `/api/v1/chat` |
| TLS | enabled |
| `serverName` | `cdn.yourdomain.com` |
| ALPN | `http/1.1` only |
| Certificate | `/root/cert/domain/fullchain.pem` |
| Key | `/root/cert/domain/privkey.pem` |
| `rejectUnknownSni` | false |
| Fingerprint | `random` |
| ECH | disabled / empty |

**ALPN must be `http/1.1` only.** Adding `h2` causes CloudFront and xray to negotiate HTTP/2,
which does not support WebSocket upgrades.

To create the inbound directly via SQLite (if the panel HTTP API is unavailable):

```bash
# Generate a UUID
UUID=$(/usr/local/x-ui/bin/xray uuid)

sqlite3 /etc/x-ui/x-ui.db "
INSERT INTO inbounds
  (user_id, up, down, total, all_time, remark, enable, expiry_time,
   traffic_reset, last_traffic_reset_time, listen, port, protocol,
   settings, stream_settings, tag, sniffing)
VALUES (
  1, 0, 0, 0, 0, 'vless-ws-tls-cf', 1, 0, 'never', 0,
  '0.0.0.0', 443, 'vless',
  '{\"clients\":[{\"comment\":\"\",\"created_at\":0,\"email\":\"user\",\"enable\":true,\"expiryTime\":0,\"flow\":\"\",\"id\":\"'$UUID'\",\"limitIp\":0,\"reset\":0,\"subId\":\"\",\"tgId\":0,\"totalGB\":0,\"updated_at\":0}],\"decryption\":\"none\",\"encryption\":\"none\"}',
  '{\"network\":\"ws\",\"security\":\"tls\",\"externalProxy\":[],\"tlsSettings\":{\"serverName\":\"cdn.yourdomain.com\",\"minVersion\":\"1.2\",\"maxVersion\":\"1.3\",\"cipherSuites\":\"\",\"rejectUnknownSni\":false,\"disableSystemRoot\":false,\"enableSessionResumption\":false,\"certificates\":[{\"certificateFile\":\"/root/cert/domain/fullchain.pem\",\"keyFile\":\"/root/cert/domain/privkey.pem\",\"oneTimeLoading\":false,\"usage\":\"encipherment\",\"buildChain\":false}],\"alpn\":[\"http/1.1\"],\"echServerKeys\":\"\",\"echForceQuery\":\"none\",\"settings\":{\"fingerprint\":\"random\",\"echConfigList\":\"\"}}',\"wsSettings\":{\"acceptProxyProtocol\":false,\"path\":\"/api/v1/chat\",\"host\":\"\",\"headers\":{},\"heartbeatPeriod\":0}}',
  'inbound-443',
  '{\"enabled\":false,\"destOverride\":[\"http\",\"tls\",\"quic\",\"fakedns\"],\"metadataOnly\":false,\"routeOnly\":false}'
);"

systemctl restart x-ui
```

Verify:
```bash
curl -sk --http1.1 \
  -H "Upgrade: websocket" -H "Connection: Upgrade" \
  -H "Host: cdn.yourdomain.com" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  -H "Sec-WebSocket-Version: 13" \
  -o /dev/null -w "%{http_code}" \
  https://yourdomain.com/api/v1/chat
# Expected: 101
```

---

## Step 6 — Client Config

```
vless://<UUID>@<CloudFront-PoP-IP>:443?type=ws&path=%2Fapi%2Fv1%2Fchat&security=tls&sni=cdn.yourdomain.com&host=cdn.yourdomain.com&alpn=http%2F1.1&fp=random&encryption=none#CloudFront-WS
```

Get the CloudFront PoP IP:
```bash
nslookup cdn.yourdomain.com
```

You can also use `cdn.yourdomain.com` directly as the address instead of a raw IP — both work.

Import into v2rayN, v2rayNG, Hiddify, Nekoray, or any VLESS-compatible client.
