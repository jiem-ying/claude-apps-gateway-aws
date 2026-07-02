#!/usr/bin/env bash
# Entrypoint for the Claude Apps Gateway container.
#
# The gateway config is supplied as YAML in the GATEWAY_CONFIG_CONTENT env var
# (injected by ECS from an SSM parameter) so the image stays config-free and the
# same image runs every deployment. Secrets stay as ${VAR} placeholders inside
# the YAML and are expanded by the gateway at boot from the secret env vars that
# ECS injects from Secrets Manager (OIDC_CLIENT_SECRET, GATEWAY_JWT_SECRET,
# GATEWAY_POSTGRES_URL, ...).
set -euo pipefail

CONFIG_PATH="${GATEWAY_CONFIG_PATH:-/tmp/.claude/gateway.yaml}"
mkdir -p "$(dirname "$CONFIG_PATH")"

# Percent-encode a string for safe use in a URL userinfo/component. Pure bash so
# it needs no python/perl in the image. RFC 3986 unreserved chars pass through;
# everything else becomes %XX. Without this, a generated password containing
# URL-structural characters (e.g. '#' truncates the DSN as a fragment, '%' starts
# an invalid escape) makes the gateway exit with "cannot be parsed as a URL".
urlencode() {
  local s="$1" i c enc out=""
  for (( i=0; i<${#s}; i++ )); do
    c="${s:$i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v enc '%%%02X' "'$c"; out+="$enc" ;;
    esac
  done
  printf '%s' "$out"
}

# Assemble the Postgres URL from components when GATEWAY_POSTGRES_URL isn't
# supplied directly. ECS injects GATEWAY_PG_PASSWORD as a secret (from the
# RDS-managed Secrets Manager secret) and the host/port/db/user as plain env, so
# the full connection string — which contains the password — is never stored as
# a static secret of its own. The password is percent-encoded so any generated
# value is DSN-safe. sslmode=require for managed Postgres.
if [[ -z "${GATEWAY_POSTGRES_URL:-}" && -n "${GATEWAY_PG_HOST:-}" ]]; then
  enc_pw="$(urlencode "${GATEWAY_PG_PASSWORD}")"
  export GATEWAY_POSTGRES_URL="postgres://${GATEWAY_PG_USER:-gateway}:${enc_pw}@${GATEWAY_PG_HOST}:${GATEWAY_PG_PORT:-5432}/${GATEWAY_PG_DB:-gateway}?sslmode=${GATEWAY_PG_SSLMODE:-require}"
fi

if [[ -n "${GATEWAY_CONFIG_CONTENT:-}" ]]; then
  printf '%s' "${GATEWAY_CONFIG_CONTENT}" > "$CONFIG_PATH"
elif [[ -f "${CONFIG_PATH}" ]]; then
  : # use a config file already mounted at CONFIG_PATH
else
  echo "[entrypoint] no GATEWAY_CONFIG_CONTENT and no config at ${CONFIG_PATH}" >&2
  exit 1
fi

exec claude gateway --config "${CONFIG_PATH}"
