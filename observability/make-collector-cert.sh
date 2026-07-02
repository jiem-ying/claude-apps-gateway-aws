#!/usr/bin/env bash
# Generate a self-signed TLS cert for the self-hosted OTEL collector and import
# it to ACM. Emits the CA PEM that must be baked into the gateway image so the
# gateway trusts the collector over HTTPS (the gateway verifies telemetry TLS
# against its container trust store and has no per-destination CA option).
#
# Skip this entirely if you pass a public/ACM CertificateArn the gateway already
# trusts.
#
# Usage:  ./make-collector-cert.sh <collector-hostname>
#   e.g.  ./make-collector-cert.sh otel.internal.example.com
# Env overrides:
#   AWS_PROFILE (optional), AWS_REGION (default: your AWS CLI default region)
set -euo pipefail

HOST="${1:?usage: ./make-collector-cert.sh <collector-hostname>}"

# Shared AWS helpers: region resolve + guard, AWS_ARGS, cfn, aws_preflight.
# (lib/ lives at the repo root, one level up from observability/.)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/aws-common.sh"

OUT="${OUT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/collector-pki}"
mkdir -p "$OUT"; cd "$OUT"

if [[ ! -f ca.key ]]; then
  echo "==> CA"
  openssl genrsa -out ca.key 2048
  openssl req -x509 -new -nodes -key ca.key -days 3650 -out ca.crt -subj "/CN=claude-gateway-collector-ca"
fi

echo "==> server cert for ${HOST}"
openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr -subj "/CN=${HOST}"
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 825 \
  -extfile <(printf "subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth" "$HOST")

echo "==> import server cert to ACM"
CERT_ARN="$(aws acm import-certificate \
  --certificate "fileb://server.crt" --private-key "fileb://server.key" \
  --certificate-chain "fileb://ca.crt" \
  --tags Key=project,Value=claude-apps-gateway \
  "${AWS_ARGS[@]}" --query CertificateArn --output text)"

# The CA the gateway image must trust:
cp ca.crt "$OUT/collector-ca.pem"

echo ""
echo "CollectorCertificateArn = $CERT_ARN"
echo "Collector CA (bake into gateway image): $OUT/collector-ca.pem"
echo ""
echo "Next:"
echo "  1. Build the gateway image with the CA baked in:"
echo "       cd ../gateway && COLLECTOR_CA_PEM=$OUT/collector-ca.pem ./build-and-push.sh <version>"
echo "  2. Deploy collector.yaml with CertificateArn=$CERT_ARN"
echo "  3. Deploy the gateway with COLLECTOR_ENDPOINT=https://${HOST}"
