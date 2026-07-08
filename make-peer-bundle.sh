#!/usr/bin/env bash
# make-peer-bundle.sh — issue a peer onboarding kit for the Claude Apps Gateway.
#
# Produces peer-bundles/<peer-name>/ containing:
#   - claude-gw.ovpn          per-peer VPN profile (unique client cert)
#   - managed-settings.json   Claude Code managed settings pointing at the gateway
#   - setup.sh                one-shot setup script the peer runs on their laptop
#   - README.md               5-step instructions
#
# Also creates a Cognito user in the pool (temp password emailed to the peer).
#
# The peer must have an email under one of the gateway's ALLOWED_DOMAINS
# (widen the gateway's allowlist if you need to admit users from other domains).
#
# Prereqs (already met by the deployed stack):
#   - claude-gateway stack live (gateway URL from its outputs)
#   - claude-gateway-vpn stack live (endpoint id from its outputs)
#   - CA + server cert exist in infrastructure/network-access/vpn-pki/ (from your
#     initial make-vpn-certs.sh run)
#
# Usage:
#   ./make-peer-bundle.sh <peer-username> <peer-email> [group]
#   e.g.: ./make-peer-bundle.sh alice alice@example.com partners
#   The optional [group] assigns the user to a Cognito group (must already exist)
#   so the gateway's managed.policies apply to them. Omit for no group.
set -euo pipefail

PEER_NAME="${1:?usage: ./make-peer-bundle.sh <peer-username> <peer-email> [group]}"
PEER_EMAIL="${2:?usage: ./make-peer-bundle.sh <peer-username> <peer-email> [group]}"
PEER_GROUP="${3:-}"   # optional Cognito group to assign the user to

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Shared AWS helpers: region resolve + guard, AWS_ARGS, cfn, aws_preflight.
source "$SCRIPT_DIR/lib/aws-common.sh"

# Stack names (must match the deployed stacks)
GATEWAY_STACK="${GATEWAY_STACK:-claude-gateway}"
VPN_STACK="${VPN_STACK:-claude-gateway-vpn}"
COGNITO_STACK="${COGNITO_STACK:-claude-gateway-cognito-new}"

NA_DIR="$SCRIPT_DIR/infrastructure/network-access"
PKI_DIR="$NA_DIR/vpn-pki"
OUT_DIR="$SCRIPT_DIR/peer-bundles/$PEER_NAME"

# ---- 0. Preflight ------------------------------------------------------------
echo "==> preflight"
aws_preflight
[[ -f "$PKI_DIR/ca.key" && -f "$PKI_DIR/ca.crt" ]] || {
  echo "ERROR: expected CA at $PKI_DIR/ca.{key,crt}. Run infrastructure/network-access/make-vpn-certs.sh once first (that establishes the CA)." >&2
  exit 1
}

# ---- 1. Look up gateway URL, VPN endpoint, Cognito pool ---------------------
GATEWAY_URL="$(aws cloudformation describe-stacks --stack-name "$GATEWAY_STACK" "${AWS_ARGS[@]}" \
  --query "Stacks[0].Outputs[?OutputKey=='GatewayUrl'].OutputValue" --output text)"
VPN_ENDPOINT="$(aws cloudformation describe-stacks --stack-name "$VPN_STACK" "${AWS_ARGS[@]}" \
  --query "Stacks[0].Outputs[?OutputKey=='ClientVpnEndpointId'].OutputValue" --output text)"
# The pool id is the last path segment of the OIDC issuer URL.
POOL_ISSUER="$(aws cloudformation describe-stacks --stack-name "$COGNITO_STACK" "${AWS_ARGS[@]}" \
  --query "Stacks[0].Outputs[?OutputKey=='Issuer'].OutputValue" --output text)"
POOL_ID="${POOL_ISSUER##*/}"
echo "    gateway=$GATEWAY_URL"
echo "    vpn_endpoint=$VPN_ENDPOINT"
echo "    cognito_pool=$POOL_ID"

# ---- 2. Create the Cognito user (idempotent) --------------------------------
mkdir -p "$OUT_DIR"
echo "==> Cognito user"
if aws cognito-idp admin-get-user --user-pool-id "$POOL_ID" --username "$PEER_NAME" "${AWS_ARGS[@]}" >/dev/null 2>&1; then
  echo "    user '$PEER_NAME' already exists — leaving as-is"
else
  aws cognito-idp admin-create-user --user-pool-id "$POOL_ID" \
    --username "$PEER_NAME" \
    --user-attributes Name=email,Value="$PEER_EMAIL" Name=email_verified,Value=true \
    --desired-delivery-mediums EMAIL \
    "${AWS_ARGS[@]}" --output text >/dev/null
  echo "    created user '$PEER_NAME' (temp password emailed to $PEER_EMAIL)"
fi

# Optional group assignment (idempotent). Group must already exist in the pool.
# The cognito:groups claim carries it once the user next signs in, so the
# gateway's managed.policies match them.
if [[ -n "$PEER_GROUP" ]]; then
  aws cognito-idp admin-add-user-to-group --user-pool-id "$POOL_ID" \
    --username "$PEER_NAME" --group-name "$PEER_GROUP" "${AWS_ARGS[@]}"
  echo "    added '$PEER_NAME' to group '$PEER_GROUP' (takes effect on their next login)"
fi

# ---- 3. Generate per-peer client cert (reuses existing CA) ------------------
echo "==> per-peer VPN client cert"
cd "$PKI_DIR"
if [[ -f "${PEER_NAME}.crt" ]]; then
  echo "    client cert for '$PEER_NAME' already exists — reusing"
else
  openssl genrsa -out "${PEER_NAME}.key" 2048 2>/dev/null
  openssl req -new -key "${PEER_NAME}.key" -out "${PEER_NAME}.csr" -subj "/CN=${PEER_NAME}" 2>/dev/null
  openssl x509 -req -in "${PEER_NAME}.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out "${PEER_NAME}.crt" -days 825 \
    -extfile <(printf "keyUsage=digitalSignature\nextendedKeyUsage=clientAuth") 2>/dev/null
  rm -f "${PEER_NAME}.csr"
  echo "    minted client cert (no ACM changes — same CA the VPN endpoint already trusts)"
fi
cd - >/dev/null

# ---- 4. Assemble the peer's .ovpn -------------------------------------------
echo "==> assemble .ovpn"
aws ec2 export-client-vpn-client-configuration --client-vpn-endpoint-id "$VPN_ENDPOINT" \
  "${AWS_ARGS[@]}" --output text > "$OUT_DIR/claude-gw.ovpn"
# Clamp the tunnel MTU so full-size TLS packets don't get black-holed by a
# lower-MTU hop on the path (a PMTUD black hole stalls `/login` and truncates
# streamed responses mid-flight). Baking these in means every reconnect starts
# clamped, instead of relying on the manual `ifconfig utunN mtu 1300` workaround.
# tun-mtu 1300 sizes the tunnel interface; mssfix 1260 caps TCP MSS with room
# for the tunnel's own encapsulation overhead.
{ echo ""
  echo "# --- MTU clamp (see README: PMTUD black hole workaround) ---"
  echo "tun-mtu 1300"
  echo "mssfix 1260"; } >> "$OUT_DIR/claude-gw.ovpn"
{ echo "<cert>"; cat "$PKI_DIR/${PEER_NAME}.crt"; echo "</cert>"
  echo "<key>"; cat "$PKI_DIR/${PEER_NAME}.key"; echo "</key>"; } >> "$OUT_DIR/claude-gw.ovpn"

# ---- 5. Emit managed-settings.json ------------------------------------------
cat > "$OUT_DIR/managed-settings.json" <<EOF
{
  "forceLoginMethod": "gateway",
  "forceLoginGatewayUrl": "$GATEWAY_URL",
  "env": {
    "CLAUDE_CODE_ENABLE_AUTO_MODE": "1"
  }
}
EOF

# ---- 6. Emit the peer's setup.sh --------------------------------------------
# GATEWAY_URL is https://<host>; strip the scheme for the nslookup hint.
GATEWAY_HOST_ONLY="${GATEWAY_URL#https://}"
# Unquoted heredoc so we can interpolate GATEWAY_HOST_ONLY. Runtime variables
# the PEER'S shell must evaluate (e.g. $HERE) are escaped with \$.
cat > "$OUT_DIR/setup.sh" <<PEERSETUP
#!/usr/bin/env bash
# setup.sh — laptop setup for the Claude Apps Gateway.
# Run once on the laptop after unpacking the bundle. macOS defaults shown;
# Linux/Windows paths are in the README.
set -euo pipefail
HERE="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"

echo "==> installing managed-settings.json (sudo will prompt)"
sudo mkdir -p "/Library/Application Support/ClaudeCode"
sudo cp "\$HERE/managed-settings.json" "/Library/Application Support/ClaudeCode/managed-settings.json"

echo ""
echo "Done. Next:"
echo "  1. Install the AWS VPN Client if you don't have it:"
echo "       brew install --cask aws-vpn-client"
echo "  2. Open AWS VPN Client -> File > Manage Profiles > Add Profile"
echo "     Point it at:  \$HERE/claude-gw.ovpn"
echo "  3. Connect the VPN. The profile pins the tunnel MTU to 1300 already, so"
echo "     /login should not hang. If it still does (e.g. the client ignored the"
echo "     baked-in clamp), force it on the live interface:"
echo "       # find your VPN interface (the utunN with a 10.30.x.x address):"
echo "       for i in \\\$(ifconfig -l); do ifconfig \\\$i 2>/dev/null | grep -q 'inet 10.30\\.' && echo \\\$i; done"
echo "       sudo ifconfig <utunN> mtu 1300     # replace <utunN> with what you found"
echo "  4. Confirm:  nslookup $GATEWAY_HOST_ONLY  (should be 10.20.x.x)"
echo "  5. Sign in: claude /login  (Cognito credentials from the admin email)"
echo "  6. Try it:  claude -p 'hello'"
PEERSETUP
chmod +x "$OUT_DIR/setup.sh"

# ---- 7. Emit the peer README ------------------------------------------------
cat > "$OUT_DIR/README.md" <<EOF
# Claude Apps Gateway — your onboarding kit

You're being onboarded to a self-hosted Claude Apps Gateway. All your Claude Code
usage routes through it: your Amazon SSO identity authorises access, and inference
runs against Bedrock in the admin's AWS account. You don't need any AWS credentials.

## What you got

- \`claude-gw.ovpn\`         — your unique VPN profile (do NOT share; it embeds your client cert)
- \`managed-settings.json\`  — Claude Code config pointing at the gateway
- \`setup.sh\`               — one-shot laptop setup (macOS; Linux/Windows steps in this README)
- \`README.md\`              — this file

## First-time setup (5 steps)

1. **Install prerequisites**:
   - Claude Code ≥ 2.1.195 (≥ 2.1.198 recommended for the \`/model\` picker): \`claude --version\` (update via \`claude update\` if older)
   - AWS VPN Client:
     - macOS: \`brew install --cask aws-vpn-client\`
     - Windows/Linux: download from https://aws.amazon.com/vpn/client-vpn-download/
2. **Import the VPN profile**:
   AWS VPN Client → File → Manage Profiles → Add Profile → point at \`claude-gw.ovpn\` → Connect.
3. **Push managed settings**:
   - **macOS (setup.sh handles this)** — writes to \`/Library/Application Support/ClaudeCode/\`:
     \`\`\`bash
     ./setup.sh
     \`\`\`
   - **Linux** — copy manually:
     \`\`\`bash
     sudo mkdir -p /etc/claude-code
     sudo cp managed-settings.json /etc/claude-code/managed-settings.json
     \`\`\`
   - **Windows (PowerShell as admin)**:
     \`\`\`powershell
     New-Item -ItemType Directory -Path C:\\ProgramData\\ClaudeCode -Force
     Copy-Item .\\managed-settings.json C:\\ProgramData\\ClaudeCode\\
     \`\`\`
4. **Sign in**:
   \`\`\`bash
   claude /login
   \`\`\`
   Uses your Cognito user (email: **$PEER_EMAIL**). You'll get a temp password by email — set a real one on first login.
5. **Try it**:
   \`\`\`bash
   claude -p "hello in 3 words"
   \`\`\`

## Troubleshooting

**"/login hangs" or curl times out after VPN connect** — MTU black hole. Your
\`.ovpn\` already pins \`tun-mtu 1300\` / \`mssfix 1260\`, which fixes this for most
clients. If it still hangs, your client ignored the baked-in clamp — force it on
the live tunnel:
\`\`\`bash
for i in \$(ifconfig -l); do ifconfig \$i 2>/dev/null | grep -q 'inet 10.30\\.' && echo \$i; done
sudo ifconfig <utunN> mtu 1300     # replace <utunN> with what the first command showed
\`\`\`
This manual override resets on every VPN reconnect — re-apply after each reconnect.

**"Couldn't load settings from Cloud gateway <old-host>"** — stale cache pinning
an old gateway hostname or session. Clear all three cache locations, then retry:
\`\`\`bash
rm -f ~/.claude/remote-settings.json                                                     # cached OTEL endpoint
security delete-generic-password -s "Claude Code-credentials" 2>/dev/null || true       # macOS keychain session
security delete-certificate -c "<old-host>" /Library/Keychains/System.keychain 2>/dev/null || true  # only if you trusted a self-signed CA before
\`\`\`
Then re-run \`claude /login\`.

**"400 model not in operator's model allowlist"** — the admin needs to add that
model to the gateway allowlist. Report it back with the exact model id.

## Notes

- The \`.ovpn\` pins the tunnel MTU to 1300 (\`tun-mtu\`/\`mssfix\`) so it survives
  reconnects. If you ever set it manually with \`ifconfig\`, that override **resets
  to 1500 on every reconnect** — keep the 1300 workaround above handy.
- Your \`.ovpn\` file is sensitive (contains your private client cert). Don't share it.
- To offboard: the admin revokes your Cognito user + rotates the VPN client cert.
EOF

# ---- 8. Zip it up -----------------------------------------------------------
cd "$SCRIPT_DIR/peer-bundles"
zip -qr "${PEER_NAME}-bundle.zip" "$PEER_NAME/"
cd - >/dev/null

echo ""
echo "=============================================================================="
echo "  Peer bundle ready"
echo "=============================================================================="
echo "  Bundle:  $SCRIPT_DIR/peer-bundles/${PEER_NAME}-bundle.zip"
echo "  Cognito: $POOL_ID user='$PEER_NAME' email='$PEER_EMAIL' (temp password emailed)"
echo ""
echo "Send the .zip to the peer via a channel appropriate to your org's data-handling"
echo "policy (Slack DM, encrypted email, S3 pre-signed URL, etc.). Do NOT publish it."
echo "The peer follows peer-bundles/$PEER_NAME/README.md."
