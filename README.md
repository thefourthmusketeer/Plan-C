# Plan C

VLESS + WebSocket + TLS through AWS CloudFront using a custom alias domain as SNI.

**راهنمای فارسی را در [اینجا](README.fa.md) ببنید**

**Ask your questions [here on telegram](https://t.me/The_Plan_C)**

---
## Prerequisites

- Domain managed in Cloudflare — [create an API token](https://dash.cloudflare.com/profile/api-tokens) with `Zone:DNS:Edit` permission
- AWS account
- VPS

---

## Option 1 — Automated Script

Run `setup.sh` directly on the VPS. It handles everything: DNS records, ACM certificate, CloudFront distribution, TLS cert via acme.sh, and the x-ui inbound.

### 1. Fill in `.env`

```bash
cp .env.example .env
nano .env   # fill in the values below
```

| Variable | Description |
|---|---|
| `CF_TOKEN` | Cloudflare API token with `Zone:DNS:Edit` — [create one](https://dash.cloudflare.com/profile/api-tokens) |
| `CF_ZONE_ID` | Cloudflare zone ID for your domain |
| `ROOT_DOMAIN` | Root domain, e.g. `yourdomain.com` |
| `CDN_SUBDOMAIN` | CDN subdomain, e.g. `cdn` → results in `cdn.yourdomain.com` |
| `WS_PATH` | WebSocket path; default: `/videos/watch` |
| `INBOUND_PORT` | Inbound port; default: `443` |
| `VLESS_UUID` | Optional — auto-generated if left blank |

### 2. Run the script

```bash
chmod +x setup.sh
./setup.sh
```

The script will install missing dependencies (curl, jq, unzip, AWS CLI) automatically. If the AWS CLI is not already installed, it will also run `aws login --remote` — this prints a URL and a one-time code in the terminal. Open that URL on any device (laptop, phone), sign in to the AWS console, and enter the code. The script continues automatically once authenticated.

---

## Option 2 — Manual Setup

### Step 1 — Cloudflare DNS

Add two records, both **not proxied** (grey cloud):

| Name | Type | Value |
|---|---|---|
| `yourdomain.com` | A | VPS IP |
| `cdn.yourdomain.com` | CNAME | *(CloudFront domain from Step 3)* |

The root A record is the CloudFront origin. The `cdn` CNAME is what clients put in the SNI —
it must not go through Cloudflare proxy because CloudFront terminates TLS for it.

---

### Step 2 — ACM Certificate

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

### Step 3 — CloudFront Distribution

Create a distribution in the AWS console and fill the fields like this:

#### Base fields

| Console field | Value |
|---|---|
| Distribution name | Optional; any name you want, for example `vless-ws-cf` |
| Description | Optional; leave blank or add a note like `VLESS WS TLS via CloudFront` |
| Distribution type | `Single website or app` |
| Route 53 managed domain | Skip / leave empty |
| Tags | Optional |
| Origin type | `Other` |
| Origin | `yourdomain.com` |
| Origin path | Leave empty |
| Allow private S3 bucket access to CloudFront | Not applicable; leave disabled |
| Origin settings | `Customize origin settings` |
| Cache settings | `Customize cache settings` |
| WAF | Optional; leave default / off unless you specifically want it |

#### Customize origin settings

| Console field | Value |
|---|---|
| Enable origin mutual TLS | Disabled |
| Add custom header | Leave empty |
| Origin Shield | Disabled |
| Protocol | `HTTPS only` |
| HTTPS port | `443` |
| Minimum origin SSL protocol | `TLSv1.2` |
| Connection attempts | `3` |
| Connection timeout | `10` seconds |
| Response timeout | `60` seconds |
| Keep-alive timeout | `60` seconds |
| Response completion timeout | Disabled |
| Origin IP address type | `IPv4-only` |

#### Customize cache settings

| Console field | Value |
|---|---|
| Viewer protocol policy | `HTTPS only` |
| Allowed HTTP methods | `GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE` |
| Cache HTTP methods | `GET and HEAD` |
| Allow gRPC requests over HTTP/2 | Disabled |
| Cache policy | `CachingDisabled` |
| Origin request policy | `AllViewerExceptHostHeader` |
| Response headers policy | Leave empty / none |

Notes:

- `Origin` must be the root domain `yourdomain.com`, not `cdn.yourdomain.com`.
- `Origin type` should be `Other` because the VPS is a custom HTTPS origin, not S3, ELB, or API Gateway.
- `HTTP version` is not in the first form shown above. After the distribution is created, set it to `HTTP/1.1` only. `HTTP/2` silently breaks WebSocket upgrades through CloudFront.
- Also make sure the distribution has the alternate domain `cdn.yourdomain.com` and uses the ACM certificate from Step 2.

After creation, copy the distribution domain (`xxxx.cloudfront.net`) and update the
`cdn.yourdomain.com` CNAME in Cloudflare to point to it.

#### CloudFront pricing

CloudFront pay-as-you-go has a **permanent free tier** (not a 12-month trial):
- 1 TB data transfer out per month
- 10 million HTTP/HTTPS requests per month

For a personal VPN this is unlikely to be exceeded.

The **price class** controls which edge locations are used, which affects the per-GB rate *if* you
go over the free tier:

| Price Class | Edge locations included | Per-GB rate after free tier |
|---|---|---|
| `PriceClass_100` | US, Mexico, Canada, Europe, Israel, Türkiye | $0.085/GB |
| `PriceClass_200` | Above + Japan, Asia, India, Middle East | Medium |
| `PriceClass_All` | Every region (adds South America, Australia/NZ) | Highest |

`setup.sh` uses `PriceClass_100`. Clients outside these regions will still connect — CloudFront
routes them through the nearest edge location *within* the price class rather than the globally
closest one, so latency may be slightly higher. Change the price class in `setup.sh` if you need
full global coverage.

---

### Step 4 — TLS Cert on VPS

This cert is for the **CloudFront → VPS** connection (the origin leg). CloudFront connects to
`yourdomain.com:443` over HTTPS and validates the cert against trusted CAs — so it must be a
real publicly trusted cert (Let's Encrypt). A self-signed cert will be rejected by CloudFront.

The cert must cover both `yourdomain.com` (CloudFront connects using this as SNI) and
`cdn.yourdomain.com` (referenced in the xray inbound `serverName`).

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

### Step 5 — xray Inbound (3x-ui)

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
| Path | `/videos/watch` |
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

To add the inbound via the 3x-ui panel, go to **Inbounds → Add** and paste this JSON (replace `yourdomain.com` and the UUID):

```json
{
  "remark": "vless-ws-tls-cf",
  "port": 443,
  "protocol": "vless",
  "settings": {
    "clients": [{
      "id": "<generate-a-uuid>",
      "email": "user",
      "enable": true,
      "flow": "",
      "limitIp": 0,
      "totalGB": 0,
      "expiryTime": 0
    }],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "ws",
    "security": "tls",
    "tlsSettings": {
      "serverName": "cdn.yourdomain.com",
      "alpn": ["http/1.1"],
      "minVersion": "1.2",
      "maxVersion": "1.3",
      "certificates": [{
        "certificateFile": "/root/cert/domain/fullchain.pem",
        "keyFile": "/root/cert/domain/privkey.pem"
      }]
    },
    "wsSettings": {
      "path": "/videos/watch",
      "headers": {}
    }
  },
  "sniffing": {
    "enabled": false,
    "destOverride": ["http","tls","quic","fakedns"]
  }
}
```

Then restart x-ui: `systemctl restart x-ui`.

Verify:
```bash
curl -sk --http1.1 \
  -H "Upgrade: websocket" -H "Connection: Upgrade" \
  -H "Host: cdn.yourdomain.com" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  -H "Sec-WebSocket-Version: 13" \
  -o /dev/null -w "%{http_code}" \
  https://yourdomain.com/videos/watch
# Expected: 101
```

---

### Step 6 — Client Config

```
vless://<UUID>@WhiteListedIp:443?type=ws&path=%2Fvideos%2Fwatch&security=tls&sni=WhiteListedIp&host=cdn.yourdomain.com&alpn=http%2F1.1&fp=random&encryption=none#CloudFront-WS
```

> IMPORTANT: this method only works with whitelisted ips. You can scan for ips using this scanner:
> **[https://github.com/thefourthmusketeer/cloudfront-scanner](https://github.com/thefourthmusketeer/cloudfront-scanner)**


Import into v2rayN, v2rayNG, Hiddify, Nekoray, or any VLESS-compatible client.

---

> **Educational purposes only.** This project is provided for learning and research.
