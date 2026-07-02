#!/usr/bin/env bash
# lib/aws-common.sh — shared AWS helpers for the deploy/onboarding scripts.
#
# SOURCE this file (don't execute it) after `set -euo pipefail`:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/aws-common.sh"      # adjust the relative path per script
#
# On source it:
#   - resolves AWS_REGION (env → `aws configure get region`) and guards it,
#   - builds the AWS_ARGS array (adds --profile only when AWS_PROFILE is set),
#   - defines cfn()          — `aws cloudformation` with AWS_ARGS appended,
#   - defines aws_preflight() — fail fast on missing/expired credentials.
#
# Callers keep their own SCRIPT_DIR and any script-specific vars; this only
# removes the boilerplate that was copy-pasted across every script.

# Resolve + guard the region (a failed :? under `set -e` exits the caller).
AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}"
: "${AWS_REGION:?set AWS_REGION (no default region configured for your AWS CLI profile)}"

# Pass --profile only when AWS_PROFILE is set, so scripts also work with ambient
# credentials (env vars, instance role / task role, or the default profile).
AWS_ARGS=(--region "$AWS_REGION")
[[ -n "${AWS_PROFILE:-}" ]] && AWS_ARGS+=(--profile "$AWS_PROFILE")

# `aws cloudformation ...` with the region/profile args appended.
cfn() { aws cloudformation "$@" "${AWS_ARGS[@]}"; }

# Fail FAST if credentials are missing/expired. Without this a stale SSO session
# lets an `aws` call error mid-deploy while the prior stack state makes it *look*
# like the update succeeded when nothing was pushed.
aws_preflight() {
  if ! aws sts get-caller-identity "${AWS_ARGS[@]}" >/dev/null 2>&1; then
    echo "ERROR: AWS credentials invalid or expired. Run 'aws sso login${AWS_PROFILE:+ --profile $AWS_PROFILE}' and retry." >&2
    exit 1
  fi
}
