#!/usr/bin/env bash
# distribute-peer-bundle.sh — upload a peer bundle to S3 and mint a 24h
# presigned URL for private sharing (Slack DM, encrypted email, etc.).
#
# Prereq: peer-bundles/<peer>-bundle.zip already produced by
#   ./make-peer-bundle.sh <peer> <peer-email>
# Prereq: distribution stack deployed (claude-gateway-distribution).
#
# Usage:
#   ./distribute-peer-bundle.sh <peer-name>
# Env overrides:
#   AWS_PROFILE            (optional; ambient creds otherwise)
#   AWS_REGION             (default: your AWS CLI default region)
#   DISTRIBUTION_STACK     (default: claude-gateway-distribution)
#   URL_TTL_SECONDS        (default: 86400 = 24h; max 604800 = 7d)
set -euo pipefail

PEER_NAME="${1:?usage: ./distribute-peer-bundle.sh <peer-name>}"
DISTRIBUTION_STACK="${DISTRIBUTION_STACK:-claude-gateway-distribution}"
URL_TTL_SECONDS="${URL_TTL_SECONDS:-86400}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Shared AWS helpers: region resolve + guard, AWS_ARGS, cfn, aws_preflight.
source "$SCRIPT_DIR/lib/aws-common.sh"

BUNDLE_PATH="$SCRIPT_DIR/peer-bundles/${PEER_NAME}-bundle.zip"

# ---- Preflight --------------------------------------------------------------
echo "==> preflight" >&2
aws_preflight
[[ -f "$BUNDLE_PATH" ]] || {
  echo "ERROR: bundle not found at $BUNDLE_PATH" >&2
  echo "       Run './make-peer-bundle.sh $PEER_NAME <email>' first." >&2
  exit 1
}
# URL_TTL_SECONDS sanity — AWS caps presigns at 7d for SigV4.
if [[ "$URL_TTL_SECONDS" -lt 60 || "$URL_TTL_SECONDS" -gt 604800 ]]; then
  echo "ERROR: URL_TTL_SECONDS must be between 60 and 604800 (7d max). Got: $URL_TTL_SECONDS" >&2
  exit 1
fi

# ---- Look up the bucket from the distribution stack -------------------------
BUCKET="$(aws cloudformation describe-stacks --stack-name "$DISTRIBUTION_STACK" "${AWS_ARGS[@]}" \
  --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue" --output text 2>&1)"
if [[ -z "$BUCKET" || "$BUCKET" == "None" ]]; then
  echo "ERROR: distribution stack '$DISTRIBUTION_STACK' not found or has no BucketName output." >&2
  echo "       Deploy it first:" >&2
  echo "       aws cloudformation deploy --stack-name $DISTRIBUTION_STACK \\" >&2
  echo "         --template-file $SCRIPT_DIR/infrastructure/distribution.yaml \\" >&2
  echo "         --region $AWS_REGION${AWS_PROFILE:+ --profile $AWS_PROFILE}" >&2
  exit 1
fi
echo "    bucket=$BUCKET" >&2

# The distribution stack also publishes a dedicated IAM signer whose STATIC access
# keys we use to presign. Reason: a presigned URL signed with SSO / assumed-role
# TEMPORARY credentials inherits the session token's expiry (often ~1h), silently
# capping the X-Amz-Expires we requested. Static keys honor the full TTL.
SIGNER_SECRET_ARN="$(aws cloudformation describe-stacks --stack-name "$DISTRIBUTION_STACK" "${AWS_ARGS[@]}" \
  --query "Stacks[0].Outputs[?OutputKey=='SignerCredentialsSecretArn'].OutputValue" --output text 2>/dev/null || true)"

# ---- Upload -----------------------------------------------------------------
KEY="${PEER_NAME}-bundle.zip"
echo "==> upload s3://$BUCKET/$KEY (SSE=AES256)" >&2
aws s3 cp "$BUNDLE_PATH" "s3://${BUCKET}/${KEY}" \
  --sse AES256 \
  "${AWS_ARGS[@]}" >/dev/null

# ---- Presign ----------------------------------------------------------------
echo "==> mint presigned URL (expires in ${URL_TTL_SECONDS}s)" >&2
if [[ -n "$SIGNER_SECRET_ARN" && "$SIGNER_SECRET_ARN" != "None" ]]; then
  # Fetch the signer's static keys and presign with THEM (not ambient creds).
  SIGNER_JSON="$(aws secretsmanager get-secret-value --secret-id "$SIGNER_SECRET_ARN" \
    "${AWS_ARGS[@]}" --query SecretString --output text)"
  # Flat JSON, no jq dependency; secret values never contain a double quote.
  SIGNER_AKID="$(printf '%s' "$SIGNER_JSON" | sed -n 's/.*"aws_access_key_id":"\([^"]*\)".*/\1/p')"
  SIGNER_SAK="$(printf '%s' "$SIGNER_JSON" | sed -n 's/.*"aws_secret_access_key":"\([^"]*\)".*/\1/p')"
  if [[ -z "$SIGNER_AKID" || -z "$SIGNER_SAK" ]]; then
    echo "ERROR: could not parse signer credentials from $SIGNER_SECRET_ARN." >&2
    exit 1
  fi
  # Isolate the static creds to this subshell: drop AWS_PROFILE / session token so
  # the SDK uses ONLY the signer keys, and pass --region explicitly (not AWS_ARGS,
  # which carries --profile). A freshly-created access key can take a few seconds
  # to propagate — retry briefly on the eventual-consistency window.
  URL=""
  for _attempt in 1 2 3 4 5; do
    if URL="$(
      unset AWS_PROFILE AWS_SESSION_TOKEN
      export AWS_ACCESS_KEY_ID="$SIGNER_AKID" AWS_SECRET_ACCESS_KEY="$SIGNER_SAK"
      aws s3 presign "s3://${BUCKET}/${KEY}" --expires-in "$URL_TTL_SECONDS" --region "$AWS_REGION" 2>/dev/null
    )" && [[ -n "$URL" ]]; then
      break
    fi
    sleep 3
  done
  [[ -n "$URL" ]] || { echo "ERROR: presign with signer credentials failed (key may still be propagating — retry)." >&2; exit 1; }
else
  # Older distribution stack without the signer identity. Presign with ambient
  # creds — WARNING: under SSO/assumed-role this URL may expire in ~1h regardless
  # of URL_TTL_SECONDS. Redeploy infrastructure/distribution.yaml to add the signer.
  echo "WARNING: distribution stack has no SignerCredentialsSecretArn output." >&2
  echo "         Presigning with ambient credentials; under SSO/assumed-role the" >&2
  echo "         URL may expire in ~1h regardless of the requested ${URL_TTL_SECONDS}s." >&2
  echo "         Redeploy infrastructure/distribution.yaml to enable full-TTL URLs." >&2
  URL="$(aws s3 presign "s3://${BUCKET}/${KEY}" --expires-in "$URL_TTL_SECONDS" "${AWS_ARGS[@]}")"
fi

# Compute expiration in a portable way (GNU date and BSD/macOS date differ).
if EXPIRES_AT="$(date -u -d "+${URL_TTL_SECONDS} seconds" "+%Y-%m-%d %H:%M:%S UTC" 2>/dev/null)"; then :; else
  EXPIRES_AT="$(date -u -v "+${URL_TTL_SECONDS}S" "+%Y-%m-%d %H:%M:%S UTC" 2>/dev/null || echo "in ${URL_TTL_SECONDS}s")"
fi

# ---- Print (stdout) ---------------------------------------------------------
cat <<EOF

==============================================================================
  Distribution URL for '$PEER_NAME' — expires at $EXPIRES_AT
==============================================================================
$URL

Slack-ready message (edit the peer's email if needed):
------------------------------------------------------------------------------
Hey $PEER_NAME — you're being onboarded to a self-hosted Claude Apps Gateway.
Your onboarding kit (24h link): $URL

Prereqs (macOS): claude --version (>= 2.1.195); brew install --cask aws-vpn-client

Setup:
  1. Download + unzip
  2. AWS VPN Client → Manage Profiles → Add → claude-gw.ovpn → Connect
  3. Run ./setup.sh
  4. claude /login (Cognito temp password came in a separate email — check spam)
  5. claude -p 'hello in 3 words'

If /login hangs after VPN connect: sudo ifconfig utun4 mtu 1300
(README.md in the bundle has full details + troubleshooting)
------------------------------------------------------------------------------
EOF
