#!/usr/bin/env bash
# deploy-all.sh — one-command orchestrator for the full self-hosted stack.
#
# Wraps deploy.sh + the auxiliary stacks so a greenfield peer can stand the
# whole thing up in one shot: (optional Cognito) -> gateway -> (optional
# bundled collector) -> gateway update with the collector endpoint ->
# (optional Client VPN) -> summary.
#
# If you already have your own IdP / OTEL collector / VPN, use deploy.sh
# directly instead — it's the low-level primitive. This orchestrator is for
# the peer who wants everything bundled in one AWS account.
#
# Usage:
#   source config/<profile>.env   # or export the vars yourself
#   ./deploy-all.sh
#
# Toggles (env vars):
#   IDP_MODE                   "new-cognito" | "existing-cognito" | "byo"   (default: byo)
#   COGNITO_POOL_ID            (required if IDP_MODE=existing-cognito)
#   COGNITO_ADMIN_EMAIL        (required if IDP_MODE=new-cognito)
#   COGNITO_DOMAIN_PREFIX      (required if IDP_MODE=new-cognito; globally unique)
#   ENABLE_COLLECTOR           "true" | "false"                             (default: false)
#   ENABLE_VPN                 "true" | "false"                             (default: false)
#   BUILD_IMAGE                "true" | "false"                             (default: false — reuse)
#   CLAUDE_VERSION             pinned binary version if BUILD_IMAGE         (default: 2.1.196)
#
# Plus every var deploy.sh accepts (AWS_REGION, PUBLIC_HOSTED_ZONE_ID,
# DOMAIN_NAME, ALLOWED_DOMAINS, CLIENT_CIDR, ...). For BYO IdP you MUST also
# set OIDC_ISSUER / OIDC_CLIENT_ID / OIDC_CLIENT_SECRET_ARN yourself; the
# orchestrator skips step 2 in that case.
set -euo pipefail

# ---- toggles -----------------------------------------------------------------
IDP_MODE="${IDP_MODE:-byo}"
ENABLE_COLLECTOR="${ENABLE_COLLECTOR:-false}"
ENABLE_VPN="${ENABLE_VPN:-false}"
BUILD_IMAGE="${BUILD_IMAGE:-false}"
# Default versions from the repo-root VERSION file (single source of truth).
_VERSION_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/VERSION"
_REPO_VERSION="$(awk -F= '/^repo_version=/{print $2}' "$_VERSION_FILE" 2>/dev/null || echo unknown)"
_DEFAULT_CLAUDE_VERSION="$(awk -F= '/^claude_binary_version=/{print $2}' "$_VERSION_FILE" 2>/dev/null || echo 2.1.196)"
CLAUDE_VERSION="${CLAUDE_VERSION:-$_DEFAULT_CLAUDE_VERSION}"

# ---- required inputs (universal) --------------------------------------------
DOMAIN_NAME="${DOMAIN_NAME:?set DOMAIN_NAME (e.g. claude-gateway.example.com — public hostname devs connect to)}"
PUBLIC_HOSTED_ZONE_ID="${PUBLIC_HOSTED_ZONE_ID:?set PUBLIC_HOSTED_ZONE_ID (Route53 public zone authoritative for DOMAIN_NAME)}"
ALLOWED_DOMAINS="${ALLOWED_DOMAINS:?set ALLOWED_DOMAINS (comma-separated, e.g. example.com)}"

# ---- shared AWS helpers (region resolve + guard, AWS_ARGS, cfn, aws_preflight) ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/aws-common.sh"

# ---- stack names (overridable) ----------------------------------------------
GATEWAY_STACK="${GATEWAY_STACK:-claude-gateway}"
COGNITO_STACK="${COGNITO_STACK:-claude-gateway-cognito-client}"
COLLECTOR_STACK="${COLLECTOR_STACK:-claude-gateway-collector}"
VPN_STACK="${VPN_STACK:-claude-gateway-vpn}"

# ---- 0. Preflight ------------------------------------------------------------
echo "==> preflight"
aws_preflight
if [[ "$BUILD_IMAGE" == "true" ]] && ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: BUILD_IMAGE=true but docker isn't on PATH." >&2
  exit 1
fi
case "$IDP_MODE" in
  byo|new-cognito|existing-cognito) ;;
  *) echo "ERROR: IDP_MODE must be one of: byo | new-cognito | existing-cognito. Got: $IDP_MODE" >&2; exit 1 ;;
esac
echo "    IDP_MODE=$IDP_MODE  ENABLE_COLLECTOR=$ENABLE_COLLECTOR  ENABLE_VPN=$ENABLE_VPN  BUILD_IMAGE=$BUILD_IMAGE"
echo "    domain=$DOMAIN_NAME  zone=$PUBLIC_HOSTED_ZONE_ID  region=$AWS_REGION"

# ---- 1. Image (optional) -----------------------------------------------------
if [[ "$BUILD_IMAGE" == "true" ]]; then
  echo "==> 1/N build+push gateway image (claude=$CLAUDE_VERSION)"
  IMAGE_TAG="${IMAGE_TAG:-$CLAUDE_VERSION}" \
    "$SCRIPT_DIR/gateway/build-and-push.sh" "$CLAUDE_VERSION"
  ACCOUNT_ID="$(aws sts get-caller-identity "${AWS_ARGS[@]}" --query Account --output text)"
  export GATEWAY_IMAGE_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO:-claude-apps-gateway}:${IMAGE_TAG:-$CLAUDE_VERSION}"
  echo "    image: $GATEWAY_IMAGE_URI"
fi
: "${GATEWAY_IMAGE_URI:?set GATEWAY_IMAGE_URI (or BUILD_IMAGE=true to build it here)}"

# ---- 2. IdP (optional; only for Cognito modes) -------------------------------
if [[ "$IDP_MODE" != "byo" ]]; then
  echo "==> 2/N Cognito ($IDP_MODE): callback=https://$DOMAIN_NAME/oauth/callback"
  case "$IDP_MODE" in
    new-cognito)
      : "${COGNITO_ADMIN_EMAIL:?IDP_MODE=new-cognito needs COGNITO_ADMIN_EMAIL}"
      : "${COGNITO_DOMAIN_PREFIX:?IDP_MODE=new-cognito needs COGNITO_DOMAIN_PREFIX (globally unique)}"
      cfn deploy --stack-name "$COGNITO_STACK" \
        --template-file "$SCRIPT_DIR/idp/cognito-create-pool.yaml" \
        --capabilities CAPABILITY_IAM \
        --parameter-overrides \
          "GatewayHostname=$DOMAIN_NAME" \
          "AdminEmail=$COGNITO_ADMIN_EMAIL" \
          "HostedUiDomainPrefix=$COGNITO_DOMAIN_PREFIX" \
        --tags auto-delete=no project=claude-apps-gateway \
        --no-fail-on-empty-changeset
      ;;
    existing-cognito)
      : "${COGNITO_POOL_ID:?IDP_MODE=existing-cognito needs COGNITO_POOL_ID (e.g. us-east-1_xxxxxxxxx)}"
      cfn deploy --stack-name "$COGNITO_STACK" \
        --template-file "$SCRIPT_DIR/idp/cognito-existing-pool.yaml" \
        --capabilities CAPABILITY_IAM \
        --parameter-overrides \
          "UserPoolId=$COGNITO_POOL_ID" \
          "GatewayHostname=$DOMAIN_NAME" \
        --tags auto-delete=no project=claude-apps-gateway \
        --no-fail-on-empty-changeset
      ;;
  esac
  OIDC_CLIENT_ID="$(cfn describe-stacks --stack-name "$COGNITO_STACK" --query "Stacks[0].Outputs[?OutputKey=='ClientId'].OutputValue" --output text)"
  OIDC_CLIENT_SECRET_ARN="$(cfn describe-stacks --stack-name "$COGNITO_STACK" --query "Stacks[0].Outputs[?OutputKey=='ClientSecretArn'].OutputValue" --output text)"
  OIDC_ISSUER="$(cfn describe-stacks --stack-name "$COGNITO_STACK" --query "Stacks[0].Outputs[?OutputKey=='Issuer'].OutputValue" --output text)"
  export OIDC_CLIENT_ID OIDC_CLIENT_SECRET_ARN OIDC_ISSUER
  export GROUPS_CLAIM="${GROUPS_CLAIM:-cognito:groups}"
  echo "    client_id=$OIDC_CLIENT_ID  issuer=$OIDC_ISSUER"
fi
: "${OIDC_ISSUER:?set OIDC_ISSUER (BYO) or use IDP_MODE=new-cognito/existing-cognito}"
: "${OIDC_CLIENT_ID:?set OIDC_CLIENT_ID}"
: "${OIDC_CLIENT_SECRET_ARN:?set OIDC_CLIENT_SECRET_ARN}"

# ---- 3. Gateway pass 1 (telemetry OFF; managed cert) -------------------------
echo "==> 3/N deploy gateway (telemetry OFF — first pass, or final if ENABLE_COLLECTOR=false)"
COLLECTOR_ENDPOINT="off" "$SCRIPT_DIR/deploy.sh"

# Capture VPC outputs for the collector + VPN steps.
VPC_ID="$(cfn describe-stacks --stack-name "$GATEWAY_STACK" --query "Stacks[0].Outputs[?OutputKey=='VpcId'].OutputValue" --output text)"
PRIVATE_SUBNETS="$(cfn describe-stacks --stack-name "$GATEWAY_STACK" --query "Stacks[0].Outputs[?OutputKey=='PrivateSubnets'].OutputValue" --output text)"
VPC_CIDR_OUT="$(cfn describe-stacks --stack-name "$GATEWAY_STACK" --query "Stacks[0].Outputs[?OutputKey=='VpcCidr'].OutputValue" --output text)"
SUBNET1="${PRIVATE_SUBNETS%%,*}"
SUBNET2="${PRIVATE_SUBNETS##*,}"

# ---- 4. Bundled collector (optional) -----------------------------------------
COLLECTOR_URL=""
if [[ "$ENABLE_COLLECTOR" == "true" ]]; then
  COLLECTOR_HOST="${COLLECTOR_HOST:-claude-otel.${DOMAIN_NAME#*.}}"   # default: claude-otel.<rest of domain>
  echo "==> 4/N deploy bundled OTEL collector (managed ACM cert for $COLLECTOR_HOST)"
  cfn deploy --stack-name "$COLLECTOR_STACK" \
    --template-file "$SCRIPT_DIR/observability/collector.yaml" \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides \
      "VpcId=$VPC_ID" \
      "PrivateSubnet1=$SUBNET1" \
      "PrivateSubnet2=$SUBNET2" \
      "PublicHostedZoneId=$PUBLIC_HOSTED_ZONE_ID" \
      "DomainName=$COLLECTOR_HOST" \
      "VpcCidr=$VPC_CIDR_OUT" \
    --tags auto-delete=no project=claude-apps-gateway \
    --no-fail-on-empty-changeset
  COLLECTOR_URL="$(cfn describe-stacks --stack-name "$COLLECTOR_STACK" --query "Stacks[0].Outputs[?OutputKey=='CollectorEndpoint'].OutputValue" --output text)"
  echo "    collector: $COLLECTOR_URL"

  # ---- 5. Gateway pass 2 (telemetry ON) --------------------------------------
  echo "==> 5/N update gateway (telemetry ON -> $COLLECTOR_URL)"
  COLLECTOR_ENDPOINT="$COLLECTOR_URL" "$SCRIPT_DIR/deploy.sh"
fi

# ---- 6. Bundled Client VPN (optional) ----------------------------------------
OVPN_PATH=""
if [[ "$ENABLE_VPN" == "true" ]]; then
  echo "==> 6/N bundled Client VPN"
  VPN_OUT="$(mktemp)"
  ( cd "$SCRIPT_DIR/infrastructure/network-access" && ./make-vpn-certs.sh "${VPN_CLIENT_NAME:-developer1}" ) | tee "$VPN_OUT"
  SERVER_ARN="$(grep -E '^ServerCertificateArn' "$VPN_OUT" | awk '{print $NF}')"
  CLIENT_ROOT_ARN="$(grep -E '^ClientRootCertificateArn' "$VPN_OUT" | awk '{print $NF}')"
  rm -f "$VPN_OUT"
  [[ -n "$SERVER_ARN" && -n "$CLIENT_ROOT_ARN" ]] || { echo "ERROR: could not parse VPN cert ARNs from make-vpn-certs.sh output" >&2; exit 1; }

  # VPC .2 resolver = VPC CIDR base + 2. Compute from the actual VPC_CIDR_OUT
  # (which is what the gateway stack was deployed with).
  BASE_OCT="${VPC_CIDR_OUT%%/*}"           # e.g. 10.20.0.0
  BASE_PREFIX="${BASE_OCT%.*.*}"           # e.g. 10.20
  DNS_RESOLVER="${BASE_PREFIX}.0.2"        # e.g. 10.20.0.2

  cfn deploy --stack-name "$VPN_STACK" \
    --template-file "$SCRIPT_DIR/infrastructure/network-access/client-vpn.yaml" \
    --parameter-overrides \
      "ServerCertificateArn=$SERVER_ARN" \
      "ClientRootCertificateArn=$CLIENT_ROOT_ARN" \
      "VpcId=$VPC_ID" \
      "SubnetId1=$SUBNET1" \
      "SubnetId2=$SUBNET2" \
      "VpcCidr=$VPC_CIDR_OUT" \
      "VpcDnsResolver=$DNS_RESOLVER" \
      "ClientCidrBlock=${VPN_CLIENT_CIDR:-10.30.0.0/22}" \
    --tags auto-delete=no project=claude-apps-gateway \
    --no-fail-on-empty-changeset

  EP_ID="$(cfn describe-stacks --stack-name "$VPN_STACK" --query "Stacks[0].Outputs[?OutputKey=='ClientVpnEndpointId'].OutputValue" --output text)"
  OVPN_PATH="$SCRIPT_DIR/infrastructure/network-access/claude-gw.ovpn"
  aws ec2 export-client-vpn-client-configuration --client-vpn-endpoint-id "$EP_ID" \
    "${AWS_ARGS[@]}" --output text > "$OVPN_PATH"
  { echo "<cert>"; cat "$SCRIPT_DIR/infrastructure/network-access/vpn-pki/${VPN_CLIENT_NAME:-developer1}.crt"; echo "</cert>";
    echo "<key>"; cat "$SCRIPT_DIR/infrastructure/network-access/vpn-pki/${VPN_CLIENT_NAME:-developer1}.key"; echo "</key>"; } >> "$OVPN_PATH"
  echo "    .ovpn: $OVPN_PATH"
fi

# ---- Summary -----------------------------------------------------------------
GATEWAY_URL="$(cfn describe-stacks --stack-name "$GATEWAY_STACK" --query "Stacks[0].Outputs[?OutputKey=='GatewayUrl'].OutputValue" --output text)"

cat <<EOF

==============================================================================
  Claude Apps Gateway — deployed
==============================================================================
  Repo version    : $_REPO_VERSION  (claude binary $CLAUDE_VERSION)
  Gateway URL     : $GATEWAY_URL
  Cognito stack   : $([[ "$IDP_MODE" == "byo" ]] && echo "(BYO — you provided OIDC vars)" || echo "$COGNITO_STACK ($IDP_MODE)")
  Collector       : $([[ "$ENABLE_COLLECTOR" == "true" ]] && echo "$COLLECTOR_URL (bundled, managed ACM)" || echo "(off or BYO — set COLLECTOR_ENDPOINT next time)")
  Client VPN      : $([[ "$ENABLE_VPN" == "true" ]] && echo "$OVPN_PATH  (import into AWS VPN Client)" || echo "(bring your own network)")

Next steps for developers:
  1. Get on your private network (existing VPN/DX/TGW, or the bundled .ovpn above).
  2. Push managed settings to their machine (macOS path shown):
       sudo mkdir -p "/Library/Application Support/ClaudeCode"
       printf '%s\n' '{ "forceLoginMethod": "gateway", "forceLoginGatewayUrl": "$GATEWAY_URL" }' \\
         | sudo tee "/Library/Application Support/ClaudeCode/managed-settings.json"
  3. \`claude /login\` — public ACM cert is browser-trusted, no NODE_EXTRA_CA_CERTS.
EOF
