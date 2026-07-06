#!/usr/bin/env bash
# Deploy the standalone Claude Apps Gateway.
#
# This is the LOW-LEVEL primitive that deploys just the gateway stack. It's
# designed to plug into whatever IdP, OTEL collector, and network you already
# have — BYO is a first-class path. For a one-command greenfield deploy that
# also stands up a Cognito pool, the bundled collector, and/or a Client VPN,
# use ./deploy-all.sh instead.
#
# Required inputs (all peers):
#   - GATEWAY_IMAGE_URI       : ECR URI from gateway/build-and-push.sh
#   - OIDC_ISSUER / OIDC_CLIENT_ID / OIDC_CLIENT_SECRET_ARN
#                             : from any OIDC IdP (Cognito, Okta, Entra, ...)
#                               callback MUST be https://<gateway-host>/oauth/callback
#   - ALLOWED_DOMAINS         : who may sign in, e.g. example.com
#
# TLS mode is chosen by which vars you set (highest priority first):
#   1. CERT_ARN                          -> BYO: use that ACM cert (+ ZONE for private DNS)
#   2. PUBLIC_HOSTED_ZONE_ID + DOMAIN_NAME -> MANAGED (recommended): stack creates a
#                                            DNS-validated PUBLIC ACM cert + public alias.
#                                            Browser-trusted; no NODE_EXTRA_CA_CERTS/keychain.
#   3. neither                           -> self-signed: generate + import (writes gateway-ca.pem)
#
# Telemetry mode (explicit — pick one):
#   COLLECTOR_ENDPOINT=off               -> telemetry OFF (explicit; recommended default)
#   COLLECTOR_ENDPOINT=https://your.otel/ -> BYO: forward metrics to your OTLP/HTTP collector
#                                             (must be https://; must chain to a CA the
#                                              gateway image trusts — public ACM works
#                                              out of the box)
#   COLLECTOR_ENDPOINT unset             -> same as off (with a warning to prefer 'off')
#
# Spend caps (optional — hard per-user/group/org USD budgets, enforced server-side):
#   ENABLE_SPEND_CAPS=true               -> turn on the Admin API + enforcement. Over-cap
#                                           developers get 429 on /v1/messages until the
#                                           period resets. REQUIRES GATEWAY_ADMIN_WRITE_KEY_ARN.
#   GATEWAY_ADMIN_WRITE_KEY_ARN=arn:...  -> Secrets Manager ARN holding the admin write key
#                                           (x-api-key for POST/DELETE on the caps API).
#   (unset / false)                      -> caps OFF (default; observability still TRACKS cost)
#   Caps themselves are set AFTER deploy via the Admin API, not here — see docs/CONFIG.md.
#
# Usage:  ./deploy.sh
set -euo pipefail

# ---- required inputs ---------------------------------------------------------
GATEWAY_IMAGE_URI="${GATEWAY_IMAGE_URI:?set GATEWAY_IMAGE_URI (from gateway/build-and-push.sh)}"
OIDC_ISSUER="${OIDC_ISSUER:?set OIDC_ISSUER (from your IdP / idp/ stack output)}"
OIDC_CLIENT_ID="${OIDC_CLIENT_ID:?set OIDC_CLIENT_ID}"
OIDC_CLIENT_SECRET_ARN="${OIDC_CLIENT_SECRET_ARN:?set OIDC_CLIENT_SECRET_ARN (Secrets Manager ARN)}"
ALLOWED_DOMAINS="${ALLOWED_DOMAINS:?set ALLOWED_DOMAINS, e.g. example.com}"   # comma-separated

# ---- TLS/DNS mode inputs (set per the header; ZONE only needed for BYO/self-signed) ----
CERT_ARN="${CERT_ARN:-}"
PUBLIC_HOSTED_ZONE_ID="${PUBLIC_HOSTED_ZONE_ID:-}"
DOMAIN_NAME="${DOMAIN_NAME:-}"
ZONE="${ZONE:-}"                                      # private hosted zone (BYO/self-signed only)
GATEWAY_HOST="${GATEWAY_HOST:-${ZONE:+claude-gateway.${ZONE}}}"

# ---- shared AWS helpers (region resolve + guard, AWS_ARGS, cfn, aws_preflight) ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/aws-common.sh"

# ---- optional inputs (sensible defaults) -------------------------------------
BEDROCK_REGION="${BEDROCK_REGION:-$AWS_REGION}"
GROUPS_CLAIM="${GROUPS_CLAIM:-cognito:groups}"        # Okta/custom: groups; Entra: roles
VPC_CIDR="${VPC_CIDR:-10.20.0.0/16}"
CLIENT_CIDR="${CLIENT_CIDR:-10.30.0.0/16}"            # client range allowed to the ALB
MIN_TASKS="${MIN_TASKS:-2}"
MAX_TASKS="${MAX_TASKS:-10}"
MULTI_AZ_DB="${MULTI_AZ_DB:-false}"
COLLECTOR_ENDPOINT="${COLLECTOR_ENDPOINT:-}"          # empty = no telemetry
FORWARD_LOGS="${FORWARD_LOGS:-false}"                 # true = also forward audit events (logs)
# Optional group RBAC: deny a set of tools to one IdP group (keeps their models).
# e.g. DENY_TOOL_GROUP=partners DENY_TOOLS=mcp__weather  -> partners lose the
# weather MCP tool; everyone else is unrestricted. Empty = no managed policies.
DENY_TOOL_GROUP="${DENY_TOOL_GROUP:-}"
DENY_TOOLS="${DENY_TOOLS:-mcp__weather}"               # comma-separated tool rules
# Optional spend caps: enforce hard per-user/group/org USD budgets (429 over-cap).
# Off by default; when on, the observability stack still TRACKS cost — this CAPS it.
ENABLE_SPEND_CAPS="${ENABLE_SPEND_CAPS:-false}"
GATEWAY_ADMIN_WRITE_KEY_ARN="${GATEWAY_ADMIN_WRITE_KEY_ARN:-}"  # required iff ENABLE_SPEND_CAPS=true
SPEND_CAP_FAIL_CLOSED="${SPEND_CAP_FAIL_CLOSED:-false}"  # true = block if Postgres unreachable
SPEND_BLOCKED_MESSAGE="${SPEND_BLOCKED_MESSAGE:-Contact your platform team to request a higher limit.}"
ADMIN_GROUPS="${ADMIN_GROUPS:-}"                       # comma-sep IdP groups granted admin via JWT
GATEWAY_STACK="${GATEWAY_STACK:-claude-gateway}"

# Fail FAST if AWS credentials are missing/expired (see lib/aws-common.sh for why
# this matters — a stale session can make a no-op look like a successful update).
aws_preflight

# ---- collector mode (explicit) -----------------------------------------------
# Accept 'off' as an explicit choice so peers don't have to leave the var unset
# and hope. Reject plain http:// upfront — the gateway will reject it too, but
# a boot-time failure is a lot noisier than 'preflight said no'.
case "${COLLECTOR_ENDPOINT:-}" in
  ""|off|OFF|false|no)
    COLLECTOR_ENDPOINT=""     # CFN param stays empty in the template
    TELEMETRY_MODE="off"
    ;;
  https://*)
    TELEMETRY_MODE="on ($COLLECTOR_ENDPOINT)"
    ;;
  http://*)
    echo "ERROR: COLLECTOR_ENDPOINT must be https:// (the gateway rejects http:// targets — SSRF guard)." >&2
    echo "       Got: $COLLECTOR_ENDPOINT" >&2
    exit 1
    ;;
  *)
    echo "ERROR: COLLECTOR_ENDPOINT must be 'off' or an https:// URL. Got: $COLLECTOR_ENDPOINT" >&2
    exit 1
    ;;
esac
echo "==> telemetry: $TELEMETRY_MODE"
[[ "$TELEMETRY_MODE" != "off" ]] && echo "==> telemetry logs (audit events) forwarding: $FORWARD_LOGS"

# ---- spend-caps mode (explicit) ----------------------------------------------
# Enforcement needs an admin write key (the x-api-key for the caps API). Fail fast
# here rather than booting a gateway whose admin block references an unset secret.
if [[ "$ENABLE_SPEND_CAPS" == "true" ]]; then
  : "${GATEWAY_ADMIN_WRITE_KEY_ARN:?ENABLE_SPEND_CAPS=true requires GATEWAY_ADMIN_WRITE_KEY_ARN (Secrets Manager ARN of the admin write key)}"
  echo "==> spend caps: ON (fail_closed_on_error=$SPEND_CAP_FAIL_CLOSED). Set caps via the Admin API after deploy."
else
  echo "==> spend caps: off (observability still tracks cost; no hard 429 enforcement)"
fi

# ---- 1/2 choose TLS/DNS mode -------------------------------------------------
# CONNECT_HOST is the hostname devs use — it becomes the gateway public_url (which
# builds the OIDC redirect_uri), so the IdP client callback MUST be
# https://$CONNECT_HOST/oauth/callback.
if [[ -n "$CERT_ARN" ]]; then
  MODE="byo"
  : "${ZONE:?BYO mode needs ZONE (private hosted zone) for GatewayHostname/private DNS}"
  CONNECT_HOST="$GATEWAY_HOST"
  echo "==> 1/2 BYO cert: $CERT_ARN (host $CONNECT_HOST)"
elif [[ -n "$PUBLIC_HOSTED_ZONE_ID" && -n "$DOMAIN_NAME" ]]; then
  MODE="managed"
  CONNECT_HOST="$DOMAIN_NAME"
  # Guard: a private zone here makes ACM DNS validation hang ~90 min then roll back.
  ZTYPE="$(aws route53 get-hosted-zone --id "$PUBLIC_HOSTED_ZONE_ID" \
    --query "HostedZone.Config.PrivateZone" --output text "${AWS_ARGS[@]}" 2>/dev/null || echo "unknown")"
  if [[ "$ZTYPE" == "True" ]]; then
    echo "ERROR: PUBLIC_HOSTED_ZONE_ID $PUBLIC_HOSTED_ZONE_ID is a PRIVATE zone; ACM validation would hang. Use a public zone." >&2
    exit 1
  fi
  # DOMAIN_NAME must sit under this zone; otherwise ACM writes the validation
  # CNAME where public resolvers can't find it and validation hangs the full
  # 90-min timeout. Cheap check: fetch the zone name and confirm the domain
  # ends with it.
  ZNAME="$(aws route53 get-hosted-zone --id "$PUBLIC_HOSTED_ZONE_ID" \
    --query "HostedZone.Name" --output text "${AWS_ARGS[@]}" 2>/dev/null | sed 's/\.$//')"
  if [[ -n "$ZNAME" && "$DOMAIN_NAME" != *"$ZNAME" ]]; then
    echo "ERROR: DOMAIN_NAME '$DOMAIN_NAME' is not under PUBLIC_HOSTED_ZONE_ID zone '$ZNAME'." >&2
    echo "       ACM DNS validation would hang. Fix the zone id or the domain." >&2
    exit 1
  fi
  echo "==> 1/2 Managed public ACM cert for $CONNECT_HOST (stack creates + DNS-validates; ~2-8 min)"
  echo "    No self-signed CA — clients need NO NODE_EXTRA_CA_CERTS / keychain trust."
else
  MODE="selfsigned"
  : "${ZONE:?self-signed mode needs ZONE (private hosted zone), or set PUBLIC_HOSTED_ZONE_ID+DOMAIN_NAME for managed}"
  CONNECT_HOST="$GATEWAY_HOST"
  echo "==> 1/2 Self-signed TLS cert -> ACM (for $CONNECT_HOST)"
  TMP="$(mktemp -d)"
  openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=$CONNECT_HOST" \
    -addext "subjectAltName=DNS:$CONNECT_HOST" >/dev/null 2>&1
  CERT_ARN="$(aws acm import-certificate \
    --certificate "fileb://$TMP/cert.pem" --private-key "fileb://$TMP/key.pem" \
    --tags Key=project,Value=claude-apps-gateway \
    "${AWS_ARGS[@]}" --query CertificateArn --output text)"
  cp "$TMP/cert.pem" "$SCRIPT_DIR/gateway-ca.pem"   # distribute to clients (NODE_EXTRA_CA_CERTS)
  rm -rf "$TMP"
  echo "    imported $CERT_ARN ; CA at gateway-ca.pem (distribute to laptops)"
fi

# ---- 2/2 render gateway.yaml + deploy ----------------------------------------
echo "==> 2/2 Render gateway.yaml + deploy gateway stack"
if [[ -n "$COLLECTOR_ENDPOINT" ]]; then
  # metrics always on when telemetry is enabled; logs (audit events — tool
  # decisions, auth, api_request/error) are opt-in via FORWARD_LOGS. traces stay
  # off (most sensitive; out of scope). +13 bytes vs the 4096B task-def budget.
  if [[ "$FORWARD_LOGS" == "true" ]]; then
    TELEMETRY_BLOCK=$(printf 'telemetry:\n  forward_to:\n    - url: %s\n      metrics: true\n      logs: true\n' "$COLLECTOR_ENDPOINT")
  else
    TELEMETRY_BLOCK=$(printf 'telemetry:\n  forward_to:\n    - url: %s\n      metrics: true\n' "$COLLECTOR_ENDPOINT")
  fi
else
  TELEMETRY_BLOCK=""
fi
DOMAINS_YAML="[$(echo "$ALLOWED_DOMAINS" | sed 's/,/, /g')]"

# Group RBAC: deny DENY_TOOLS (comma-separated tool rules) to DENY_TOOL_GROUP;
# everyone else (match: {}) is unrestricted. Flow style keeps it under the
# 4096-byte task-def config budget. Empty group => empty block => no policies.
if [[ -n "$DENY_TOOL_GROUP" ]]; then
  DENY_TOOLS_YAML="[\"$(echo "$DENY_TOOLS" | sed 's/,/", "/g')\"]"
  MANAGED_BLOCK=$(printf 'managed:\n  policies:\n    - match: {groups: [%s]}\n      cli: {permissions: {deny: %s}}\n    - match: {}\n' \
    "$DENY_TOOL_GROUP" "$DENY_TOOLS_YAML")
  echo "==> group RBAC: deny [$DENY_TOOLS] to group '$DENY_TOOL_GROUP' (all other groups unrestricted)"
else
  MANAGED_BLOCK=""
fi

# Spend caps: enable the Admin API + server-side enforcement. Flow style keeps it
# under the 4096-byte task-def config budget. The write key stays a ${VAR} the
# gateway expands at boot (injected by ECS from Secrets Manager) — never rendered
# into the non-secret config. Empty when disabled => empty block => caps off.
if [[ "$ENABLE_SPEND_CAPS" == "true" ]]; then
  ADMIN_GROUPS_LINE=""
  if [[ -n "$ADMIN_GROUPS" ]]; then
    ADMIN_GROUPS_YAML="[$(echo "$ADMIN_GROUPS" | sed 's/,/, /g')]"
    ADMIN_GROUPS_LINE=$(printf '\n  admin_groups: %s' "$ADMIN_GROUPS_YAML")
  fi
  ADMIN_BLOCK=$(printf 'admin:\n  write_keys: [{id: ops, key: "${GATEWAY_ADMIN_WRITE_KEY}"}]\n  blocked_message: "%s"%s\nenforcement:\n  fail_closed_on_error: %s\n' \
    "$SPEND_BLOCKED_MESSAGE" "$ADMIN_GROUPS_LINE" "$SPEND_CAP_FAIL_CLOSED")
else
  ADMIN_BLOCK=""
fi

# Render: strip the template's comment header, substitute placeholders.
RENDERED="$(sed '/^# /d; /^#$/d' "$SCRIPT_DIR/gateway/gateway.yaml.example" \
  | sed \
      -e "s#__PUBLIC_URL__#https://$CONNECT_HOST#" \
      -e "s#__VPC_CIDR__#$VPC_CIDR#" \
      -e "s#__OIDC_ISSUER__#$OIDC_ISSUER#" \
      -e "s#__OIDC_CLIENT_ID__#$OIDC_CLIENT_ID#" \
      -e "s#__ALLOWED_DOMAINS__#$DOMAINS_YAML#" \
      -e "s#__GROUPS_CLAIM__#$GROUPS_CLAIM#" \
      -e "s#__BEDROCK_REGION__#$BEDROCK_REGION#")"
RENDERED="${RENDERED/__MANAGED_BLOCK__/$MANAGED_BLOCK}"
RENDERED="${RENDERED/__TELEMETRY_BLOCK__/$TELEMETRY_BLOCK}"
RENDERED="${RENDERED/__ADMIN_BLOCK__/$ADMIN_BLOCK}"

# The rendered config is injected as one ECS task-def env var, capped at 4096
# bytes. Fail loudly here rather than getting a confusing deploy-time error.
CONFIG_BYTES=$(printf '%s' "$RENDERED" | wc -c | tr -d ' ')
if (( CONFIG_BYTES >= 4096 )); then
  echo "ERROR: rendered gateway config is ${CONFIG_BYTES} bytes (>= 4096, the ECS task-def env limit)." >&2
  echo "       Trim the model allowlist or the managed policies (see docs/CONFIG.md)." >&2
  exit 1
fi
echo "    rendered gateway config: ${CONFIG_BYTES}/4096 bytes"

cfn deploy --stack-name "$GATEWAY_STACK" \
  --template-file "$SCRIPT_DIR/infrastructure/claude-apps-gateway.yaml" \
  --capabilities CAPABILITY_NAMED_IAM CAPABILITY_IAM \
  --parameter-overrides \
    "GatewayImageUri=$GATEWAY_IMAGE_URI" \
    "OidcIssuer=$OIDC_ISSUER" \
    "OidcClientId=$OIDC_CLIENT_ID" \
    "OidcClientSecretArn=$OIDC_CLIENT_SECRET_ARN" \
    "AllowedEmailDomains=$ALLOWED_DOMAINS" \
    "GroupsClaim=$GROUPS_CLAIM" \
    "BedrockRegion=$BEDROCK_REGION" \
    "CollectorEndpoint=$COLLECTOR_ENDPOINT" \
    "VpcCidr=$VPC_CIDR" \
    "DomainName=${DOMAIN_NAME}" \
    "PublicHostedZoneId=${PUBLIC_HOSTED_ZONE_ID}" \
    "GatewayHostname=${GATEWAY_HOST:-}" \
    "PrivateHostedZoneName=${ZONE}" \
    "CertificateArn=${CERT_ARN}" \
    "ClientCidr=$CLIENT_CIDR" \
    "MinTasks=$MIN_TASKS" \
    "MaxTasks=$MAX_TASKS" \
    "MultiAzDatabase=$MULTI_AZ_DB" \
    "EnableSpendCaps=$ENABLE_SPEND_CAPS" \
    "AdminWriteKeyArn=$GATEWAY_ADMIN_WRITE_KEY_ARN" \
    "GatewayConfigContent=$RENDERED" \
  --no-fail-on-empty-changeset

echo ""
echo "Gateway URL: https://$CONNECT_HOST"
if [[ "$MODE" == "managed" ]]; then
  echo "Managed public cert — ensure the OIDC client callback is https://$CONNECT_HOST/oauth/callback"
fi
cfn describe-stacks --stack-name "$GATEWAY_STACK" --query "Stacks[0].Outputs" --output table
