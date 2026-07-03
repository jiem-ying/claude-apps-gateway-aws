# CLAUDE.md — context for AI coding assistants

Context for Claude Code (and other AI assistants) working in this repo. Kept
terse and factual — enough to make good decisions, not a re-write of the docs.

## What this repo is

AWS-native deployment for the **[Claude Apps Gateway](https://code.claude.com/docs/en/claude-apps-gateway)**
(the self-hosted control plane in the `claude` CLI). It is **not** the gateway
binary itself — the binary is downloaded + GPG-verified in `gateway/Dockerfile`.

The stack: ECS Fargate running `claude gateway` behind an **internal IPv4 ALB**,
RDS PostgreSQL for auth state, OIDC IdP (Cognito or BYO), optional ADOT collector
→ CloudWatch, optional AWS Client VPN. All in one VPC.

## Two entry points

- **`deploy.sh`** — low-level primitive. Deploys only the gateway stack. Use
  when the peer has their own IdP / OTEL collector / network path. Env-var
  driven. Fully backward-compatible.
- **`deploy-all.sh`** — orchestrator. Chains Cognito → gateway → collector →
  gateway update → VPN in one command. Toggles (all env vars):
  - `IDP_MODE` = `byo | new-cognito | existing-cognito` (default `byo`)
  - `ENABLE_COLLECTOR` = `true | false` (default `false`)
  - `ENABLE_VPN` = `true | false` (default `false`)
  - `BUILD_IMAGE` = `true | false` (default `false` — reuse existing tag)

Peers pick a profile from `config/*.env` (5 shipped) and `source` it before
running:

| Profile | Filename |
|---|---|
| greenfield / everything bundled | `config/managed-newcognito-collector-vpn.env` |
| new Cognito, no telemetry, no VPN | `config/managed-newcognito-notelemetry.env` |
| existing Cognito + BYO OTEL + BYO network | `config/managed-existingcognito-byotelemetry.env` |
| pure BYO (Okta/Entra/…) | `config/byo-oidc-notelemetry.env` |
| self-signed fallback (no domain) | `config/selfsigned-fallback.env` |

## TLS modes (precedence order, checked by `deploy.sh`)

1. **BYO** — `CERT_ARN=...` + `ZONE=<private-zone>` → uses the passed cert.
2. **Managed public ACM (recommended)** — `PUBLIC_HOSTED_ZONE_ID` +
   `DOMAIN_NAME` → stack creates a DNS-validated public cert + public alias
   A-record to the **internal** ALB (public name resolves to private IPs).
   Browser-trusted; no `NODE_EXTRA_CA_CERTS`, no keychain, no fingerprint prompt.
3. **Self-signed fallback** — neither set → generate + import to ACM, writes
   `gateway-ca.pem` for laptops.

## Telemetry modes (explicit; `COLLECTOR_ENDPOINT`)

- `off` (or unset) — telemetry off. Recommended default.
- `https://your.otel/` — BYO. Must be `https://` (gateway SSRF guard rejects http).
- `ENABLE_COLLECTOR=true` (orchestrator only) — bundle the ADOT collector +
  CloudWatch dashboard; orchestrator injects its URL as `COLLECTOR_ENDPOINT`
  in the post-collector gateway update.
- `FORWARD_LOGS=true` — also forward audit **events** (adds `logs: true` to the
  rendered telemetry block). The bundled collector lands them in
  `/aws/claude-gateway/events` (a second `awscloudwatchlogs` pipeline) → drives the
  governance Logs Insights widgets + the `api_error` alarm. Metrics-only otherwise.
  `deploy-all.sh` defaults it to `true` when `ENABLE_COLLECTOR=true`, else `false`.
  Collector alarms: `ALARM_EMAIL` (optional SNS sub) + `DAILY_COST_THRESHOLD_USD`.

## Group RBAC (`managed.policies`; `DENY_TOOL_GROUP` / `DENY_TOOLS`)

- `gateway.yaml.example` has a `__MANAGED_BLOCK__` placeholder (like
  `__TELEMETRY_BLOCK__`), rendered by `deploy.sh`. `DENY_TOOL_GROUP=<group>` +
  `DENY_TOOLS=<comma-sep tool rules>` emits a first-match policy that denies those
  tools to that group and a `match: {}` catch-all (everyone else unrestricted).
  Empty group ⇒ empty block ⇒ no policies (backward-compatible).
- **Tool permission strings:** `mcp__<server>` (whole server) or
  `mcp__<server>__<tool>` (one tool). `permissions` gate tools model-agnostically;
  `availableModels` gates models. **Neither is per-tool-per-model** — the model is
  chosen per session, so "model X only for tool Y" is NOT expressible.
- **The gateway CANNOT push MCP servers** (`mcpServers` in a policy is rejected at
  boot). Install MCP servers locally; the gateway only gates access. See
  `examples/weather-mcp/`.
- **Propagation:** policy edits need a gateway **redeploy** (config-in-taskdef) +
  reach CLIs on the ~hourly settings poll; a user's new **group membership** needs a
  fresh token, i.e. **re-login** (this Cognito client has no refresh token).

## Key architectural facts (things easy to get wrong)

- **ALB must stay `Scheme: internal` + `IpAddressType: ipv4`.** Claude Code's
  `/login` rejects any gateway resolving to a public IP; dual-stack internal
  ALBs return public-range IPv6.
- **Public cert + private ALB is intentional.** ACM validates against a public
  DNS name; the A-record aliases the internal ALB → resolves to `10.20.x.x`.
- **Gateway config lives in the task definition**, not SSM. Changing the
  telemetry endpoint or model list forces a new task-def revision → ECS auto-cycles.
  Do NOT reintroduce SSM injection — telemetry changes silently wouldn't take effect.
- **Config-in-taskdef limit is 4096 bytes.** The current render is ~3000 (a bit
  more with telemetry/managed blocks); the model allowlist has the most headroom to
  grow. `FORWARD_LOGS=true` adds `logs: true` (~13 bytes); the managed block adds a
  bit more. `deploy.sh` now hard-fails the deploy if the rendered config is ≥ 4096 bytes.
- **Observability cardinality: metrics vs. Logs Insights.** In `collector.yaml`,
  only `user.email`/`user.groups` on `token.usage`/`cost.usage` are promoted to
  metric dimensions (each distinct value = a custom metric = $). High-cardinality
  per-user/per-role slicing is done by CloudWatch Logs Insights over
  `/aws/claude-gateway/events`, not by adding more `metric_declarations`. Also
  `user.groups` is an OIDC list that awsemf stringifies → the metric dimension
  keys on the whole group-set; per-group splitting is a Logs Insights job.
- **Model IDs must match what the CLI sends.** The current allowlist covers
  fully-qualified `global.anthropic.*` (opus-4-6/7/8, sonnet-4-6, sonnet-5,
  haiku-4-5, fable-5) AND short aliases (`claude-opus-4-8`, `claude-sonnet-5`,
  `claude-haiku-4-5`, …). CLI ≥ 2.1.198 sends the short form after `/model`
  picker selection; older CLI versions send the fully-qualified form.
- **Fable 5 requires an account-level Bedrock data-retention configuration** —
  the allowlist has it, but `upstream rejected the request` from Bedrock means
  the account isn't approved for the model's retention mode yet (Support case).
- **RDS-generated password interpolates into `postgres://` DSN.** The
  `ExcludeCharacters` must exclude URL-structural chars (`# % & + = [ ] { }` etc.).
  The entrypoint percent-encodes the password for defense in depth.

## Gotchas peers hit (all documented, but worth knowing)

- **VPN tunnel MTU 1500** drops TLS handshake packets → `/login` hangs.
  Fix: `sudo ifconfig utunN mtu 1300`. Resets on VPN reconnect.
- **Stale `~/.claude/remote-settings.json` + macOS keychain
  `Claude Code-credentials`** pin the OLD gateway host when hostnames change.
  Delete both when switching from self-signed to managed cert.
- **ACM validation hangs ~90 min** if `PUBLIC_HOSTED_ZONE_ID` is a private zone
  or `DOMAIN_NAME` isn't under it. `deploy.sh` preflight now guards both.
- **AWS Client VPN server cert needs `keyUsage`** + a domain-style CN.
  `make-vpn-certs.sh` sets both; don't strip them.
- **`build-and-push.sh` version vs. tag.** `CLAUDE_VERSION` is what's
  downloaded/GPG-verified (must be a real release); `IMAGE_TAG` is the ECR tag
  (can be `2.1.196-fix2` etc.).

## Where things live

```
deploy.sh                              low-level primitive (backward-compat)
deploy-all.sh                          orchestrator
make-peer-bundle.sh                    per-peer onboarding (Cognito user + .ovpn + zip)
distribute-peer-bundle.sh              S3 upload + 24h presigned URL for bundle handoff
VERSION                                {repo_version, claude_binary_version}
config/*.env                           profiles peers copy + edit
infrastructure/
  claude-apps-gateway.yaml             the core stack (VPC + RDS + ECS + ALB + …)
  distribution.yaml                    optional S3 bucket for peer-bundle presigning
  network-access/                      optional Client VPN + cert helper
idp/
  cognito-{create,existing}-pool.yaml  managed IdP paths (AliasAttributes: [email])
  # BYO OIDC = just set OIDC_* env vars, no stack
observability/
  collector.yaml                       optional ADOT collector + CW dashboard
gateway/
  Dockerfile                           GPG-verified claude binary + optional CA baking
  extra-ca/                            optional CAs baked into the image trust store
  entrypoint.sh                        assembles Postgres DSN (percent-encoded pw)
  build-and-push.sh                    ECR build; reads VERSION for defaults
  gateway.yaml.example                 template rendered into the task-def
```

## When helping a peer here

- **Ask which path they're on first**: managed cert vs. BYO cert vs. self-signed.
  It determines almost every decision downstream.
- **Assume BYO is common.** Enterprises usually have their own IdP + OTEL +
  VPN. `deploy.sh` is the right entry point for them, not `deploy-all.sh`.
- **Never suggest putting `http://` in `COLLECTOR_ENDPOINT`** — the gateway
  refuses it. Corporate PKI = bake the CA (`COLLECTOR_CA_PEM`).
- **Never suggest making the ALB `internet-facing`** or `dualstack` — breaks `/login`.
- **When suggesting `cfn deploy` changes**, remember: params without `Default:`
  break existing stacks. All new params need `Default: ""` or a benign value.
- **Templates use `cfn-lint`**; the ignore list in `Metadata.cfn-lint.config`
  covers real false positives (W2001 for params surfaced for documentation,
  W1030 for conditionally-empty ARN defaults). Don't broaden it without cause.

## Session artifacts to know about

The repo history shows the bugs found during the initial end-to-end test
(DB password, image tag/version, config-in-taskdef, collector health port,
VPN cert keyUsage, MTU, stale cache, model allowlist, SSO expiry). Read
`git log` if you're triaging something that sounds familiar — it probably is.
