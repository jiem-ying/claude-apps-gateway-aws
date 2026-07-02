# Security

## Reporting security issues

**Do not open a public GitHub issue for security-sensitive bugs.** Instead,
open a **private security advisory** on this repository via the **Security tab →
"Report a vulnerability"** (GitHub path: `/security/advisories/new` under this
repo). That keeps the report confidential until a fix is available.

If GitHub Security Advisories aren't available to you, email the repo owner
directly (contact link on their GitHub profile). Please include repro steps,
the deployment mode (managed / BYO / self-signed), and any relevant logs with
credentials/ARNs redacted.

We aim to acknowledge reports within 5 business days.

## What's in scope

Security-relevant surfaces this repo owns:

- **OIDC client secret handling.** How `cognito-existing-pool.yaml` and
  `cognito-create-pool.yaml` mint + persist the client secret in Secrets
  Manager, and how the gateway task retrieves it.
- **RDS Postgres credential.** The generated password in
  `claude-apps-gateway.yaml` `DbSecret`; whether characters slip through that
  break the DSN or are otherwise interpolation-unsafe.
- **Gateway TLS chain.** Cert issuance path (managed ACM vs BYO vs self-signed),
  what the gateway image trusts (`extra-ca/` + `update-ca-certificates`), and
  the risk that a baked CA broadens the trust surface for all outbound TLS
  (OIDC, Bedrock, telemetry).
- **Telemetry SSRF.** `COLLECTOR_ENDPOINT` is operator-supplied; the deploy
  script rejects `http://` (the gateway itself does too — its SSRF guard).
  Report any bypass.
- **Client VPN PKI.** `make-vpn-certs.sh` produces mutual-TLS material; the
  helper flow and how it's imported to ACM.
- **Managed settings delivery.** The gateway pushes `managed-settings.json`
  to signed-in laptops; that channel can execute commands on developer
  machines (see [Claude Apps Gateway docs](https://code.claude.com/docs/en/claude-apps-gateway#threat-model-summary)).
  Anything in this repo that could let a non-admin operator inject managed
  settings is in scope.
- **Public DNS record → private IPs.** The managed-cert path deliberately
  publishes RFC-1918 IPs in a public zone (VPN-only reachable). Reports of
  information disclosure beyond that (e.g. leaking of stack names, secrets in
  outputs) are welcome.
- **Peer-bundle S3 distribution.** `infrastructure/distribution.yaml`
  provisions a private bucket holding `.zip` bundles (each contains a VPN
  client private key). `distribute-peer-bundle.sh` mints time-limited
  presigned URLs. In scope: bucket policy (TLS-only, BPA, ownership),
  lifecycle expiry (7 d default), presigned-URL TTL bounds, whether a
  URL leak exposes anything beyond the specific peer's bundle. Not in
  scope: how the URL is transmitted (Slack/email/etc. — operator's choice).

## What's out of scope for this repo

These belong upstream, not here:

- **The gateway server binary itself** (the `claude gateway` process). Report
  those to [anthropics/claude-code](https://github.com/anthropics/claude-code/security/advisories/new).
- **Bedrock service, Cognito service, or other AWS service** vulnerabilities.
  Use [AWS Vulnerability Reporting](https://aws.amazon.com/security/vulnerability-reporting/).
- **Third-party OIDC provider issues** (Okta, Entra, Google, Keycloak).

## Fix expectations

Once a report is confirmed:

- Critical (RCE, credential leak, auth bypass): fix landed within 7 days,
  advisory published on disclosure.
- High (privilege escalation, sensitive data exposure): fix within 30 days.
- Medium / low: batched with regular releases, disclosed in changelog.

## Currently known limitations (not bugs — deliberate trade-offs)

- **Self-signed cert path publishes a CA that clients must trust manually.**
  If you trust it in your macOS keychain, remember to remove it when done:
  `sudo security delete-certificate -c <hostname> /Library/Keychains/System.keychain`.
- **Baking a collector CA into the gateway image expands the container's TLS
  trust surface for all outbound calls,** not just to the collector. Use the
  managed-cert collector path (`config/managed-*collector*`) to avoid this.
- **The `.ovpn` profile contains a client cert + private key.** Treat it as
  sensitive; the `.gitignore` covers `*.ovpn` and `vpn-pki/`. Rotate keys and
  ACM certs on developer offboarding.
