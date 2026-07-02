#!/usr/bin/env bash
# Generate mutual-TLS certs for the reference Client VPN and import them to ACM.
#
# Only needed if you deploy the optional client-vpn.yaml add-on. If you reach the
# gateway over an existing corporate VPN / Direct Connect / Transit Gateway, skip
# this entirely.
#
# Produces a CA, a server cert, and one client cert using plain openssl (no
# easy-rsa dependency), imports the server + CA to ACM, and writes the client
# key/cert locally for assembling the .ovpn profile.
#
# Usage:  ./make-vpn-certs.sh [client-name]
# Env overrides:
#   AWS_PROFILE   (optional: omit to use ambient credentials / your default profile)
#   AWS_REGION    (default: your AWS CLI default region)
set -euo pipefail

CLIENT_NAME="${1:-developer1}"

# Shared AWS helpers: region resolve + guard, AWS_ARGS, cfn, aws_preflight.
# (lib/ lives at the repo root, two levels up from infrastructure/network-access/.)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/aws-common.sh"

OUT="${OUT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vpn-pki}"
mkdir -p "$OUT"; cd "$OUT"

if [[ ! -f ca.key ]]; then
  echo "==> CA"
  openssl genrsa -out ca.key 2048
  openssl req -x509 -new -nodes -key ca.key -days 3650 -out ca.crt -subj "/CN=claude-gateway-vpn-ca"
fi

# AWS Client VPN requires the server cert to carry a domain-style CN + a matching
# SAN (it derives a domain from it); a bare CN=server is rejected with
# "Certificate does not have a domain".
SERVER_CN="${SERVER_CN:-server.claude-gateway-vpn}"
echo "==> server cert (CN=${SERVER_CN})"
openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr -subj "/CN=${SERVER_CN}"
# keyUsage is REQUIRED: the .ovpn's `remote-cert-tls server` makes OpenVPN reject
# a server cert with no Key Usage extension ("VERIFY KU ERROR"). Pair it with
# extendedKeyUsage=serverAuth (which remote-cert-tls also checks).
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 825 \
  -extfile <(printf "subjectAltName=DNS:%s\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth" "$SERVER_CN")

echo "==> client cert ($CLIENT_NAME)"
openssl genrsa -out "${CLIENT_NAME}.key" 2048
openssl req -new -key "${CLIENT_NAME}.key" -out "${CLIENT_NAME}.csr" -subj "/CN=${CLIENT_NAME}"
openssl x509 -req -in "${CLIENT_NAME}.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out "${CLIENT_NAME}.crt" -days 825 \
  -extfile <(printf "keyUsage=digitalSignature\nextendedKeyUsage=clientAuth")

echo "==> import server cert to ACM"
SERVER_ARN="$(aws acm import-certificate --certificate "fileb://server.crt" --private-key "fileb://server.key" \
  --certificate-chain "fileb://ca.crt" \
  --tags Key=project,Value=claude-apps-gateway \
  "${AWS_ARGS[@]}" --query CertificateArn --output text)"
echo "==> import CA (client root) to ACM"
CLIENT_ROOT_ARN="$(aws acm import-certificate --certificate "fileb://ca.crt" --private-key "fileb://ca.key" \
  --tags Key=project,Value=claude-apps-gateway \
  "${AWS_ARGS[@]}" --query CertificateArn --output text)"

echo ""
echo "ServerCertificateArn      = $SERVER_ARN"
echo "ClientRootCertificateArn  = $CLIENT_ROOT_ARN"
echo "Client key/cert: $OUT/${CLIENT_NAME}.{key,crt}"
echo "Pass the two ARNs to client-vpn.yaml."
