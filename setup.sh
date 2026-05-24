#!/usr/bin/env bash
# =============================================================================
# setup.sh — CloudFront SNI-alias bypass setup
#
# Run this script directly on the VPS.
#
# Automates:
#   1. Detect public IP of this machine; ask user to confirm
#   2. Cloudflare DNS records (root A + cdn CNAME stub)
#   3. ACM certificate request + DNS validation (us-east-1)
#   4. CloudFront distribution creation
#   5. Cloudflare DNS CNAME updated to point to the distribution
#   6. Install 3x-ui if absent, install acme.sh + issue cert
#   7. Upsert the VLESS/WS/TLS inbound in x-ui via SQLite
#   8. Print the final VLESS URI
#
# Dependencies (auto-installed if missing):
#   aws cli v2, curl, jq, openssl, unzip
#
# Usage:
#   cp .env.example .env   # fill in values
#   chmod +x setup.sh
#   ./setup.sh
# =============================================================================

set -euo pipefail

# ─── colour helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}══════════════════════════════════════════${RESET}"; \
            echo -e "${BOLD}  $*${RESET}"; \
            echo -e "${BOLD}══════════════════════════════════════════${RESET}"; }

# ─── load .env ───────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

[[ -f "$ENV_FILE" ]] || die ".env not found at $ENV_FILE — copy .env.example and fill in values"

# shellcheck disable=SC1090
set -o allexport; source "$ENV_FILE"; set +o allexport

# ─── required variables ───────────────────────────────────────────────────────
: "${CF_TOKEN:?CF_TOKEN is required (Cloudflare API token with Zone:DNS:Edit)}"
: "${CF_ZONE_ID:?CF_ZONE_ID is required (Cloudflare zone ID)}"
: "${ROOT_DOMAIN:?ROOT_DOMAIN is required (e.g. yourdomain.com)}"
: "${CDN_SUBDOMAIN:?CDN_SUBDOMAIN is required (e.g. cdn — results in cdn.yourdomain.com)}"
: "${WS_PATH:=${WS_PATH:-/api/v1/chat}}"
: "${INBOUND_PORT:=${INBOUND_PORT:-443}}"
: "${X_UI_REMARK:=${X_UI_REMARK:-vless-ws-tls-cf}}"

# Cert dir is always fixed — Let's Encrypt certs issued by acme.sh go here.
# CloudFront validates the origin cert (OriginProtocolPolicy: https-only), so it must be
# a publicly trusted cert (Let's Encrypt). Self-signed certs will be rejected by CloudFront.
CERT_DIR="/root/cert/domain"

CDN_DOMAIN="${CDN_SUBDOMAIN}.${ROOT_DOMAIN}"

# optional — leave blank to auto-generate
VLESS_UUID="${VLESS_UUID:-}"

# ─── dependency checks ────────────────────────────────────────────────────────
header "Checking dependencies"

MISSING_APT=()
for cmd in curl jq openssl; do
  command -v "$cmd" &>/dev/null && ok "$cmd found" || MISSING_APT+=("$cmd")
done

if [[ ${#MISSING_APT[@]} -gt 0 ]]; then
  info "Installing missing apt packages: ${MISSING_APT[*]}"
  apt update -qq && apt install -y "${MISSING_APT[@]}" || die "Failed to install ${MISSING_APT[*]}"
  ok "Installed: ${MISSING_APT[*]}"
fi

command -v unzip &>/dev/null || { info "unzip not found — installing"; apt install -y unzip; }

if command -v aws &>/dev/null; then
  ok "aws found"
else
  info "AWS CLI not found — downloading and installing..."
  curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp/ || die "Failed to unzip AWS CLI"
  /tmp/aws/install --update || die "AWS CLI install failed"
  rm -rf /tmp/aws /tmp/awscliv2.zip
  ok "AWS CLI installed"
fi

AWS_IDENTITY=$(aws sts get-caller-identity 2>/dev/null) \
  || die "AWS credentials not configured — run 'aws configure'"
ok "AWS identity: $(echo "$AWS_IDENTITY" | jq -r '.Arn')"

# ─── Step 1: detect and confirm public IP ────────────────────────────────────
header "Step 1 — Detect public IP"

# Try several sources in order
VPS_IP=""
for url in \
  "https://checkip.amazonaws.com" \
  "https://api.ipify.org" \
  "https://ifconfig.me/ip" \
  "https://icanhazip.com"
do
  VPS_IP=$(curl -s --max-time 5 "$url" | tr -d '[:space:]') && [[ -n "$VPS_IP" ]] && break
done

[[ -n "$VPS_IP" ]] || die "Could not detect public IP — set VPS_IP manually in .env"

echo ""
echo -e "  Detected public IP: ${BOLD}${VPS_IP}${RESET}"
echo -n "  Is this correct? [Y/n] "
read -r CONFIRM
CONFIRM="${CONFIRM:-y}"
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo -n "  Enter correct IP: "
  read -r VPS_IP
  [[ -n "$VPS_IP" ]] || die "No IP provided"
fi
ok "Using VPS IP: ${VPS_IP}"

# ─── Step 2: Cloudflare DNS — root A record ───────────────────────────────────
header "Step 2 — Cloudflare DNS: root A record"

CF_API="https://api.cloudflare.com/client/v4"
CF_HDR=(-H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json")

EXISTING_A=$(curl -s "${CF_API}/zones/${CF_ZONE_ID}/dns_records?type=A&name=${ROOT_DOMAIN}" \
  "${CF_HDR[@]}" | jq -r '.result[0].id // empty')

if [[ -n "$EXISTING_A" ]]; then
  RESP=$(curl -s -X PUT "${CF_API}/zones/${CF_ZONE_ID}/dns_records/${EXISTING_A}" \
    "${CF_HDR[@]}" \
    -d "{\"type\":\"A\",\"name\":\"${ROOT_DOMAIN}\",\"content\":\"${VPS_IP}\",\"ttl\":60,\"proxied\":false}")
  echo "$RESP" | jq -e '.success' >/dev/null || die "Failed to update A record: $RESP"
  ok "Updated A record: ${ROOT_DOMAIN} → ${VPS_IP} (not proxied)"
else
  RESP=$(curl -s -X POST "${CF_API}/zones/${CF_ZONE_ID}/dns_records" \
    "${CF_HDR[@]}" \
    -d "{\"type\":\"A\",\"name\":\"${ROOT_DOMAIN}\",\"content\":\"${VPS_IP}\",\"ttl\":60,\"proxied\":false}")
  echo "$RESP" | jq -e '.success' >/dev/null || die "Failed to create A record: $RESP"
  ok "Created A record: ${ROOT_DOMAIN} → ${VPS_IP} (not proxied)"
fi

# ─── Step 3: ACM certificate (us-east-1) ─────────────────────────────────────
header "Step 3 — ACM certificate (us-east-1)"

EXISTING_CERT_ARN=$(aws acm list-certificates \
  --region us-east-1 \
  --certificate-statuses ISSUED PENDING_VALIDATION \
  --query "CertificateSummaryList[?DomainName=='${CDN_DOMAIN}'].CertificateArn | [0]" \
  --output text 2>/dev/null)

if [[ "$EXISTING_CERT_ARN" != "None" && -n "$EXISTING_CERT_ARN" ]]; then
  CERT_STATUS=$(aws acm describe-certificate --region us-east-1 \
    --certificate-arn "$EXISTING_CERT_ARN" \
    --query 'Certificate.Status' --output text)
  ok "Found existing ACM cert ${EXISTING_CERT_ARN} (status: ${CERT_STATUS})"
  ACM_CERT_ARN="$EXISTING_CERT_ARN"
else
  info "Requesting new ACM certificate for ${CDN_DOMAIN}..."
  ACM_CERT_ARN=$(aws acm request-certificate \
    --region us-east-1 \
    --domain-name "$CDN_DOMAIN" \
    --validation-method DNS \
    --query 'CertificateArn' --output text)
  ok "Requested ACM cert: ${ACM_CERT_ARN}"
fi

# Wait for ACM to populate the DNS validation record
info "Waiting for ACM to provide DNS validation record..."
VAL_NAME=""; VAL_VALUE=""
for i in $(seq 1 20); do
  VALIDATION_RECORD=$(aws acm describe-certificate \
    --region us-east-1 \
    --certificate-arn "$ACM_CERT_ARN" \
    --query 'Certificate.DomainValidationOptions[0].ResourceRecord' \
    --output json 2>/dev/null)
  VAL_NAME=$(echo "$VALIDATION_RECORD" | jq -r '.Name // empty')
  VAL_VALUE=$(echo "$VALIDATION_RECORD" | jq -r '.Value // empty')
  [[ -n "$VAL_NAME" && -n "$VAL_VALUE" ]] && break
  sleep 3
done

[[ -n "$VAL_NAME" ]] || die "ACM did not provide validation DNS record after 60s"
info "ACM validation record: ${VAL_NAME} CNAME → ${VAL_VALUE}"

VAL_NAME_SHORT="${VAL_NAME%.}"

EXISTING_VAL=$(curl -s "${CF_API}/zones/${CF_ZONE_ID}/dns_records?type=CNAME&name=${VAL_NAME_SHORT}" \
  "${CF_HDR[@]}" | jq -r '.result[0].id // empty')

if [[ -n "$EXISTING_VAL" ]]; then
  ok "ACM validation CNAME already exists in Cloudflare"
else
  RESP=$(curl -s -X POST "${CF_API}/zones/${CF_ZONE_ID}/dns_records" \
    "${CF_HDR[@]}" \
    -d "{\"type\":\"CNAME\",\"name\":\"${VAL_NAME_SHORT}\",\"content\":\"${VAL_VALUE}\",\"ttl\":60,\"proxied\":false}")
  echo "$RESP" | jq -e '.success' >/dev/null || die "Failed to create ACM validation CNAME: $RESP"
  ok "Created ACM validation CNAME in Cloudflare"
fi

info "Waiting for ACM certificate to be issued (DNS propagation may take a few minutes)..."
CERT_STATUS="PENDING_VALIDATION"
for i in $(seq 1 40); do
  CERT_STATUS=$(aws acm describe-certificate \
    --region us-east-1 \
    --certificate-arn "$ACM_CERT_ARN" \
    --query 'Certificate.Status' --output text)
  [[ "$CERT_STATUS" == "ISSUED" ]] && break
  printf "  [%d/40] status: %s\r" "$i" "$CERT_STATUS"
  sleep 15
done
echo ""

[[ "$CERT_STATUS" == "ISSUED" ]] || {
  warn "ACM cert not yet ISSUED (status: ${CERT_STATUS})"
  warn "DNS propagation can take up to 30 minutes. Re-run the script once issued."
  warn "Check: aws acm describe-certificate --region us-east-1 --certificate-arn ${ACM_CERT_ARN} --query 'Certificate.Status'"
  die "Aborting — cert not issued"
}
ok "ACM certificate issued: ${ACM_CERT_ARN}"

# ─── Step 4: CloudFront distribution ─────────────────────────────────────────
header "Step 4 — CloudFront distribution"

EXISTING_DIST=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Aliases.Items[?contains(@,'${CDN_DOMAIN}')]].{Id:Id,Domain:DomainName}" \
  --output json 2>/dev/null | jq -r '.[0] // empty')

if [[ -n "$EXISTING_DIST" && "$EXISTING_DIST" != "null" ]]; then
  CF_DIST_ID=$(echo "$EXISTING_DIST" | jq -r '.Id')
  CF_DIST_DOMAIN=$(echo "$EXISTING_DIST" | jq -r '.Domain')
  ok "Found existing CloudFront distribution: ${CF_DIST_ID} → ${CF_DIST_DOMAIN}"
else
  info "Creating CloudFront distribution..."

  # Managed policy IDs (stable AWS-published values, confirmed against live distribution)
  CACHING_DISABLED_ID="4135ea2d-6df8-44a3-9df3-4b5a84be39ad"      # CachingDisabled
  ALL_VIEWER_EXCEPT_HOST_ID="b689b0a8-53d0-40ab-baf2-68738e2966ac" # AllViewerExceptHostHeader

  CALLER_REF="setup-sh-$(date +%s)"

  DIST_CONFIG=$(cat <<EOF
{
  "CallerReference": "${CALLER_REF}",
  "Aliases": {
    "Quantity": 1,
    "Items": ["${CDN_DOMAIN}"]
  },
  "DefaultRootObject": "",
  "Origins": {
    "Quantity": 1,
    "Items": [
      {
        "Id": "vps-origin",
        "DomainName": "${ROOT_DOMAIN}",
        "OriginPath": "",
        "CustomHeaders": { "Quantity": 0 },
        "CustomOriginConfig": {
          "HTTPPort": 80,
          "HTTPSPort": ${INBOUND_PORT},
          "OriginProtocolPolicy": "https-only",
          "OriginSslProtocols": {
            "Quantity": 1,
            "Items": ["TLSv1.2"]
          },
          "OriginReadTimeout": 60,
          "OriginKeepaliveTimeout": 60
        },
        "ConnectionAttempts": 3,
        "ConnectionTimeout": 10
      }
    ]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "vps-origin",
    "ViewerProtocolPolicy": "https-only",
    "AllowedMethods": {
      "Quantity": 7,
      "Items": ["HEAD","DELETE","POST","GET","OPTIONS","PUT","PATCH"],
      "CachedMethods": {
        "Quantity": 2,
        "Items": ["HEAD","GET"]
      }
    },
    "CachePolicyId": "${CACHING_DISABLED_ID}",
    "OriginRequestPolicyId": "${ALL_VIEWER_EXCEPT_HOST_ID}",
    "Compress": false,
    "SmoothStreaming": false
  },
  "Comment": "cloudfront-sni-alias bypass — ${CDN_DOMAIN}",
  "Enabled": true,
  "HttpVersion": "http1.1",
  "IsIPV6Enabled": true,
  "ViewerCertificate": {
    "ACMCertificateArn": "${ACM_CERT_ARN}",
    "SSLSupportMethod": "sni-only",
    "MinimumProtocolVersion": "TLSv1.2_2021"
  },
  "PriceClass": "PriceClass_All"
}
EOF
)

  CREATE_RESULT=$(aws cloudfront create-distribution \
    --distribution-config "$DIST_CONFIG" \
    --query '{Id:Distribution.Id,Domain:Distribution.DomainName,Status:Distribution.Status}' \
    --output json)

  CF_DIST_ID=$(echo "$CREATE_RESULT" | jq -r '.Id')
  CF_DIST_DOMAIN=$(echo "$CREATE_RESULT" | jq -r '.Domain')
  CF_DIST_STATUS=$(echo "$CREATE_RESULT" | jq -r '.Status')
  ok "Created CloudFront distribution: ${CF_DIST_ID}"
  ok "  Domain: ${CF_DIST_DOMAIN}"
  ok "  Status: ${CF_DIST_STATUS} (may take 5-15 min to deploy)"
fi

# ─── Step 5: Cloudflare CNAME cdn → CloudFront ───────────────────────────────
header "Step 5 — Cloudflare CNAME: ${CDN_DOMAIN} → ${CF_DIST_DOMAIN}"

EXISTING_CDN=$(curl -s "${CF_API}/zones/${CF_ZONE_ID}/dns_records?type=CNAME&name=${CDN_DOMAIN}" \
  "${CF_HDR[@]}" | jq -r '.result[0].id // empty')

if [[ -n "$EXISTING_CDN" ]]; then
  RESP=$(curl -s -X PUT "${CF_API}/zones/${CF_ZONE_ID}/dns_records/${EXISTING_CDN}" \
    "${CF_HDR[@]}" \
    -d "{\"type\":\"CNAME\",\"name\":\"${CDN_DOMAIN}\",\"content\":\"${CF_DIST_DOMAIN}\",\"ttl\":60,\"proxied\":false}")
  echo "$RESP" | jq -e '.success' >/dev/null || die "Failed to update CDN CNAME: $RESP"
  ok "Updated CNAME: ${CDN_DOMAIN} → ${CF_DIST_DOMAIN}"
else
  RESP=$(curl -s -X POST "${CF_API}/zones/${CF_ZONE_ID}/dns_records" \
    "${CF_HDR[@]}" \
    -d "{\"type\":\"CNAME\",\"name\":\"${CDN_DOMAIN}\",\"content\":\"${CF_DIST_DOMAIN}\",\"ttl\":60,\"proxied\":false}")
  echo "$RESP" | jq -e '.success' >/dev/null || die "Failed to create CDN CNAME: $RESP"
  ok "Created CNAME: ${CDN_DOMAIN} → ${CF_DIST_DOMAIN}"
fi

# ─── Step 6: install 3x-ui + acme.sh + issue cert ────────────────────────────
header "Step 6 — 3x-ui, acme.sh, TLS cert"

# Install 3x-ui if not present and capture its random credentials
if command -v x-ui &>/dev/null; then
  ok "3x-ui already installed"
else
  info "Installing 3x-ui..."
  INSTALL_LOG=$(bash -c "$(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/main/install.sh)" < /dev/null 2>&1)
  echo "$INSTALL_LOG"
  XUI_PORT=$(echo "$INSTALL_LOG" | grep -oP 'Port:\s*\K\d+')
  XUI_BASEPATH=$(echo "$INSTALL_LOG" | grep -oP 'WebBasePath:\s*\K\S+')
  XUI_API_TOKEN=$(echo "$INSTALL_LOG" | grep -oP 'API Token:\s*\K\S+')
  ok "3x-ui installed (panel port: ${XUI_PORT})"
fi

systemctl enable --now x-ui

# Read panel config from DB if not captured from install (re-run scenario)
command -v sqlite3 &>/dev/null || apt install -y sqlite3 &>/dev/null
if [[ -f /etc/x-ui/x-ui.db ]]; then
  XUI_PORT="${XUI_PORT:-$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='webPort'" 2>/dev/null)}"
  XUI_BASEPATH="${XUI_BASEPATH:-$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='webBasePath'" 2>/dev/null)}"
fi

XUI_PORT="${XUI_PORT:-2053}"
XUI_BASEPATH="${XUI_BASEPATH:-}"
# Use https if the panel has TLS certs configured, otherwise http
XUI_CERT=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='webCertFile'" 2>/dev/null || true)
if [[ -n "$XUI_CERT" && -f "$XUI_CERT" ]]; then
  PANEL_SCHEME="https"
else
  PANEL_SCHEME="http"
fi
PANEL_URL="${PANEL_SCHEME}://localhost:${XUI_PORT}${XUI_BASEPATH%/}"

# Install acme.sh if not present
if [[ -f ~/.acme.sh/acme.sh ]]; then
  ok "acme.sh already installed"
else
  info "Installing acme.sh..."
  curl -s https://get.acme.sh | sh -s -- email=admin@${ROOT_DOMAIN}
  ok "acme.sh installed"
fi

mkdir -p "${CERT_DIR}"

# Check if existing cert covers both domains
# openssl prints all SANs on one line, so grep -c would return 1 even if both are present.
# Instead check for each domain separately.
SKIP_CERT=no
if [[ -f "${CERT_DIR}/fullchain.pem" ]]; then
  CERT_TEXT=$(openssl x509 -noout -text -in "${CERT_DIR}/fullchain.pem" 2>/dev/null)
  CERT_EXPIRY=$(openssl x509 -noout -enddate -in "${CERT_DIR}/fullchain.pem" 2>/dev/null \
    | cut -d= -f2)
  HAS_ROOT=$(echo "$CERT_TEXT" | grep -c "DNS:${ROOT_DOMAIN}" || true)
  HAS_CDN=$(echo  "$CERT_TEXT" | grep -c "DNS:${CDN_DOMAIN}"  || true)
  if [[ "$HAS_ROOT" -ge 1 && "$HAS_CDN" -ge 1 ]]; then
    ok "Cert already covers both ${ROOT_DOMAIN} and ${CDN_DOMAIN} (expires: ${CERT_EXPIRY}) — skipping issuance"
    SKIP_CERT=yes
  else
    warn "Cert exists but does not cover both domains (root=${HAS_ROOT} cdn=${HAS_CDN}) — re-issuing"
  fi
fi

if [[ "$SKIP_CERT" == "no" ]]; then
  info "Issuing TLS cert via acme.sh (Cloudflare DNS challenge)..."
  CF_Token="${CF_TOKEN}" ~/.acme.sh/acme.sh --issue --dns dns_cf \
    -d "${ROOT_DOMAIN}" -d "${CDN_DOMAIN}" \
    --fullchain-file "${CERT_DIR}/fullchain.pem" \
    --key-file "${CERT_DIR}/privkey.pem" \
    --reloadcmd 'systemctl restart x-ui' \
    --force
  ok "TLS cert issued and saved to ${CERT_DIR}"
fi

# ─── Step 7: upsert VLESS/WS/TLS inbound via 3x-ui REST API ────────────────
header "Step 7 — x-ui inbound (VLESS/WS/TLS)"

# Ensure API token exists in the api_tokens table (3x-ui stores tokens there, not in settings).
# If none exists, insert one — x-ui reads api_tokens at runtime so no restart needed.
XUI_API_TOKEN=$(sqlite3 /etc/x-ui/x-ui.db \
  "SELECT token FROM api_tokens WHERE enabled=1 ORDER BY id LIMIT 1" 2>/dev/null || true)
if [[ -z "$XUI_API_TOKEN" ]]; then
  XUI_API_TOKEN=$(cat /proc/sys/kernel/random/uuid | tr -d '-' | head -c 48)
  info "No API token found — inserting one into api_tokens table..."
  sqlite3 /etc/x-ui/x-ui.db \
    "INSERT INTO api_tokens (name, token, enabled, created_at) VALUES ('setup-script', '${XUI_API_TOKEN}', 1, $(date +%s%3N));"
  ok "API token created"
else
  ok "API token loaded from api_tokens table"
fi

# Bearer token auth + X-Requested-With (required by x-ui's auth middleware)
XUI_API_HDR=(-sk \
  -H "Authorization: Bearer ${XUI_API_TOKEN}" \
  -H "X-Requested-With: XMLHttpRequest" \
  -H "Content-Type: application/json")

# Generate UUID using xray binary bundled with x-ui
if [[ -z "$VLESS_UUID" ]]; then
  VLESS_UUID=$(/usr/local/x-ui/bin/xray uuid 2>/dev/null \
    || /usr/local/bin/xray uuid 2>/dev/null \
    || cat /proc/sys/kernel/random/uuid)
  VLESS_UUID="${VLESS_UUID// /}"
  [[ -n "$VLESS_UUID" ]] || die "Could not generate a UUID — set VLESS_UUID in .env"
  info "Generated UUID: ${VLESS_UUID}"
fi

# Build inbound payload
INBOUND_PAYLOAD=$(cat <<EOF
{
  "enable": true,
  "remark": "${X_UI_REMARK}",
  "port": ${INBOUND_PORT},
  "protocol": "vless",
  "settings": {
    "clients": [{
      "id": "${VLESS_UUID}",
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
      "serverName": "${CDN_DOMAIN}",
      "alpn": ["http/1.1"],
      "minVersion": "1.2",
      "maxVersion": "1.3",
      "certificates": [{
        "certificateFile": "${CERT_DIR}/fullchain.pem",
        "keyFile": "${CERT_DIR}/privkey.pem"
      }]
    },
    "wsSettings": {
      "path": "${WS_PATH}",
      "headers": {}
    }
  },
  "sniffing": {
    "enabled": false,
    "destOverride": ["http","tls","quic","fakedns"]
  }
}
EOF
)

# Check if inbound already exists
info "Checking for existing inbound '${X_UI_REMARK}'..."
LIST_RESP=$(curl "${XUI_API_HDR[@]}" "${PANEL_URL}/panel/api/inbounds/list" 2>/dev/null)
if [[ -z "$LIST_RESP" ]]; then
  die "No response from x-ui panel at ${PANEL_URL} — is x-ui running? Check: systemctl status x-ui"
fi
if ! echo "$LIST_RESP" | jq -e '.success' >/dev/null 2>&1; then
  die "x-ui API error on list: ${LIST_RESP}"
fi
EXISTING_ID=$(echo "$LIST_RESP" | jq -r --arg remark "${X_UI_REMARK}" '.obj[] | select(.remark == $remark) | .id // empty' 2>/dev/null || true)

if [[ -n "$EXISTING_ID" && "$EXISTING_ID" != "null" ]]; then
  info "Inbound '${X_UI_REMARK}' already exists (id=${EXISTING_ID}) — updating..."
  UPDATE_RESP=$(curl "${XUI_API_HDR[@]}" -X POST "${PANEL_URL}/panel/api/inbounds/update/${EXISTING_ID}" \
    -d "$INBOUND_PAYLOAD" 2>/dev/null)
  if echo "$UPDATE_RESP" | jq -e '.success' >/dev/null 2>&1; then
    ok "Inbound updated"
  else
    die "Failed to update inbound: $(echo "$UPDATE_RESP" | jq -c '.msg')"
  fi
else
  info "Creating new inbound '${X_UI_REMARK}'..."
  CREATE_RESP=$(curl "${XUI_API_HDR[@]}" -X POST "${PANEL_URL}/panel/api/inbounds/add" \
    -d "$INBOUND_PAYLOAD" 2>/dev/null)
  if echo "$CREATE_RESP" | jq -e '.success' >/dev/null 2>&1; then
    ok "Inbound created"
  else
    die "Failed to create inbound: $(echo "$CREATE_RESP" | jq -c '.msg')"
  fi
fi

# 4. Restart x-ui
info "Restarting x-ui to apply inbound..."
systemctl restart x-ui
sleep 3

systemctl is-active x-ui >/dev/null \
  || die "x-ui failed to start — check: journalctl -u x-ui -n 50"
ok "x-ui is running"

# 5. Probe WebSocket endpoint locally
info "Probing WebSocket endpoint (localhost)..."
WS_PROBE=$(curl -sk --http1.1 \
  -o /dev/null -w '%{http_code}' \
  -H "Upgrade: websocket" \
  -H "Connection: Upgrade" \
  -H "Host: ${CDN_DOMAIN}" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  -H "Sec-WebSocket-Version: 13" \
  "https://localhost:${INBOUND_PORT}${WS_PATH}" 2>/dev/null || echo "000")

if [[ "$WS_PROBE" == "101" ]]; then
  ok "WebSocket probe: 101 Switching Protocols ✓"
else
  warn "WebSocket probe returned HTTP ${WS_PROBE} (expected 101)"
  warn "May be normal if firewall blocks loopback on port ${INBOUND_PORT}."
  warn "Test externally: curl -vk --http1.1 -H 'Upgrade: websocket' ... https://${ROOT_DOMAIN}${WS_PATH}"
fi

# ─── Step 8: wait for CloudFront to deploy, resolve PoP IP ───────────────────
header "Step 8 — CloudFront deployment status"

CF_STATUS=$(aws cloudfront get-distribution \
  --id "$CF_DIST_ID" \
  --query 'Distribution.Status' --output text)

if [[ "$CF_STATUS" != "Deployed" ]]; then
  info "CloudFront status: ${CF_STATUS} — waiting for deployment (up to 15 min)..."
  for i in $(seq 1 30); do
    sleep 30
    CF_STATUS=$(aws cloudfront get-distribution \
      --id "$CF_DIST_ID" \
      --query 'Distribution.Status' --output text)
    printf "  [%d/30] status: %s\r" "$i" "$CF_STATUS"
    [[ "$CF_STATUS" == "Deployed" ]] && break
  done
  echo ""
fi

if [[ "$CF_STATUS" == "Deployed" ]]; then
  ok "CloudFront distribution is Deployed"
else
  warn "CloudFront not yet deployed (status: ${CF_STATUS}) — VLESS URI will work once it deploys"
fi

# Resolve current PoP IP
CF_POP_IP=$(dig +short "${CDN_DOMAIN}" 2>/dev/null | grep -E '^[0-9]+\.' | head -1 \
  || nslookup "${CDN_DOMAIN}" 2>/dev/null | awk '/^Address: / && !/#/ { print $2; exit }' \
  || true)

if [[ -z "$CF_POP_IP" ]]; then
  CF_POP_IP="${CDN_DOMAIN}"
  warn "Could not resolve ${CDN_DOMAIN} to an IP yet — using domain as address (also valid)"
fi

# ─── Step 9: print final VLESS URI ───────────────────────────────────────────
header "Setup Complete"

WS_PATH_ENC=$(printf '%s' "${WS_PATH}" | sed 's|/|%2F|g')
ALPN_ENC="http%2F1.1"

VLESS_URI="vless://${VLESS_UUID}@${CF_POP_IP}:443?type=ws&path=${WS_PATH_ENC}&security=tls&sni=${CDN_DOMAIN}&host=${CDN_DOMAIN}&alpn=${ALPN_ENC}&fp=random&encryption=none#CloudFront-WS"

echo ""
echo -e "${BOLD}VLESS URI:${RESET}"
echo "$VLESS_URI"
echo ""
echo -e "${BOLD}Summary:${RESET}"
printf "  %-28s %s\n" "VPS IP:"               "$VPS_IP"
printf "  %-28s %s\n" "Origin domain:"        "$ROOT_DOMAIN"
printf "  %-28s %s\n" "CDN alias domain:"     "$CDN_DOMAIN"
printf "  %-28s %s\n" "CloudFront dist ID:"   "$CF_DIST_ID"
printf "  %-28s %s\n" "CloudFront domain:"    "$CF_DIST_DOMAIN"
printf "  %-28s %s\n" "CloudFront PoP IP:"    "$CF_POP_IP"
printf "  %-28s %s\n" "ACM cert ARN:"         "$ACM_CERT_ARN"
printf "  %-28s %s\n" "VLESS UUID:"           "$VLESS_UUID"
printf "  %-28s %s\n" "WebSocket path:"       "$WS_PATH"
printf "  %-28s %s\n" "Inbound port:"         "$INBOUND_PORT"
printf "  %-28s %s\n" "Cert on VPS:"          "${CERT_DIR}/fullchain.pem"
echo ""
echo -e "${CYAN}Import the VLESS URI into v2rayN, Hiddify, Nekoray, or any VLESS-compatible client.${RESET}"
echo -e "${CYAN}If CloudFront is still deploying, wait 5-15 minutes before connecting.${RESET}"
