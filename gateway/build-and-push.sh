#!/usr/bin/env bash
# Build the Claude Apps Gateway image and push it to ECR.
#
# Usage:
#   ./build-and-push.sh [CLAUDE_VERSION]
#
# Env overrides:
#   AWS_PROFILE   (optional: omit to use ambient credentials / your default profile)
#   AWS_REGION    (default: your AWS CLI default region)
#   ECR_REPO      (default: claude-apps-gateway)
#   IMAGE_TAG     (default: CLAUDE_VERSION — set this to tag the image differently
#                  from the downloaded binary version, e.g. IMAGE_TAG=2.1.196-ca
#                  to rebuild the SAME claude 2.1.196 binary with an extra CA baked
#                  in. Do NOT put a non-release string in CLAUDE_VERSION — the build
#                  downloads that exact release and would 404.)
#   PLATFORM      (default: linux/amd64 — Fargate x86_64; use linux/arm64 for Graviton)
set -euo pipefail

# Default CLAUDE_VERSION from the repo-root VERSION file (single source of truth).
# Falls back to a hardcoded pin if the file isn't readable.
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_DEFAULT_CLAUDE_VERSION="$(awk -F= '/^claude_binary_version=/{print $2}' "$_SCRIPT_DIR/../VERSION" 2>/dev/null)"
CLAUDE_VERSION="${1:-${_DEFAULT_CLAUDE_VERSION:-2.1.196}}"
IMAGE_TAG="${IMAGE_TAG:-$CLAUDE_VERSION}"
ECR_REPO="${ECR_REPO:-claude-apps-gateway}"
PLATFORM="${PLATFORM:-linux/amd64}"
TARGETARCH="${PLATFORM##*/}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Shared AWS helpers: region resolve + guard, AWS_ARGS, cfn, aws_preflight.
# (lib/ lives at the repo root, one level up from gateway/.)
source "$SCRIPT_DIR/../lib/aws-common.sh"

# get-caller-identity doubles as the credential preflight here.
ACCOUNT_ID="$(aws sts get-caller-identity "${AWS_ARGS[@]}" --query Account --output text)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
IMAGE_URI="${REGISTRY}/${ECR_REPO}:${IMAGE_TAG}"

echo "==> Ensuring ECR repo ${ECR_REPO} exists"
aws ecr describe-repositories --repository-names "$ECR_REPO" \
  "${AWS_ARGS[@]}" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name "$ECR_REPO" \
       --image-scanning-configuration scanOnPush=true \
       --image-tag-mutability IMMUTABLE \
       "${AWS_ARGS[@]}" >/dev/null

echo "==> Logging in to ${REGISTRY}"
aws ecr get-login-password "${AWS_ARGS[@]}" \
  | docker login --username AWS --password-stdin "$REGISTRY"

# Optionally bake a self-hosted collector's CA into the image so the gateway
# trusts it over HTTPS for telemetry forwarding. Set COLLECTOR_CA_PEM to the CA
# path (e.g. observability/collector-pki/collector-ca.pem). Staged as a .crt
# (update-ca-certificates only reads .crt) and cleaned up after the build.
EXTRA_CA_DIR="$SCRIPT_DIR/extra-ca"
STAGED_CA=""
if [[ -n "${COLLECTOR_CA_PEM:-}" ]]; then
  [[ -f "$COLLECTOR_CA_PEM" ]] || { echo "COLLECTOR_CA_PEM not found: $COLLECTOR_CA_PEM" >&2; exit 1; }
  STAGED_CA="$EXTRA_CA_DIR/collector-ca.crt"
  cp "$COLLECTOR_CA_PEM" "$STAGED_CA"
  echo "==> Baking collector CA into image: $COLLECTOR_CA_PEM"
fi
cleanup() { [[ -n "$STAGED_CA" ]] && rm -f "$STAGED_CA"; }
trap cleanup EXIT

echo "==> Building ${IMAGE_URI} (platform=${PLATFORM}, claude=${CLAUDE_VERSION})"
docker build \
  --platform "$PLATFORM" \
  --build-arg "CLAUDE_VERSION=${CLAUDE_VERSION}" \
  --build-arg "TARGETARCH=${TARGETARCH}" \
  -t "$IMAGE_URI" \
  "$SCRIPT_DIR"

echo "==> Pushing ${IMAGE_URI}"
docker push "$IMAGE_URI"

echo ""
echo "Image pushed: ${IMAGE_URI}"
echo "Pass this as the GatewayImageUri parameter to claude-apps-gateway.yaml."
