# Self-hosting the Claude Apps Gateway on AWS ECS

A step-by-step guide to standing up a **self-hosted Claude Apps Gateway** on AWS
Fargate, backed by Amazon Bedrock, with corporate SSO sign-in — and **nothing
else required**. No other stacks and no extra moving parts. Just developers
signing in with your IdP and inference flowing through Bedrock in your account.

> This is a standalone, self-contained example. Everything it deploys lives in
> your account and depends on no other stack. See
> [`code.claude.com/docs/en/claude-apps-gateway`](https://code.claude.com/docs/en/claude-apps-gateway).

---

## What you get

```
 developer laptop                          your AWS account (private VPC)
┌──────────────┐   HTTPS + bearer    ┌──────────────────────────────────────┐
│  claude CLI  │ ───────────────────▶│  internal ALB (IPv4)                   │
│  /login      │  (private network)  │     │                                  │
└──────────────┘                     │     ▼                                  │
       ▲  OIDC sign-in               │  ECS Fargate: `claude gateway`         │
       │                             │     │   ├─ OIDC RP ──▶ your IdP         │
   your IdP (Cognito/Okta/…)         │     │   ├─ Postgres (RDS)              │
                                     │     │   └─ Bedrock upstream (task role) │
                                     │     ▼                                  │
                                     │  Amazon Bedrock (Claude models)        │
                                     └──────────────────────────────────────┘
        (optional) ──▶ your existing OTLP collector  ── telemetry, no hard dep
```

- **Credentials never leave AWS.** The Bedrock credential is the ECS task role;
  developers hold only short-lived bearer tokens from SSO.
- **Server-side model access control**, per-user cost attribution, spend caps,
  and managed-settings delivery — all from the `claude` binary itself.
- **Telemetry is optional.** Point it at an existing OTLP collector or run with
  none.
- **HA and autoscaling by default.** ≥2 Fargate tasks across AZs behind the ALB,
  ECS auto-scaling on CPU + ALB request count, a **regional NAT gateway**
  (auto-HA egress across AZs), and a deployment circuit breaker with auto-rollback.
  See [Resilience and scalability](#resilience-and-scalability).

### How sign-in works (end to end)

No AWS credentials ever reach a developer machine. Here's the full flow the first
time someone runs `claude /login` against your gateway:

1. **Discovery.** Claude Code reads `managed-settings.json` (pushed by your MDM),
   sees `forceLoginGatewayUrl`, and calls the gateway's OAuth discovery document
   (`/.well-known/oauth-authorization-server`).
2. **Device-grant start.** The CLI kicks off the OAuth **device authorization grant**
   (the "device flow" — the browser-based grant designed for CLIs/devices) by
   calling `/oauth/device_authorization`; the gateway returns a `verification_uri`.
3. **Browser SSO.** The developer's browser opens to your IdP. They sign in with
   corporate SSO (MFA, conditional access, whatever your IdP enforces). The IdP
   redirects back to `https://<gateway>/oauth/callback`.
4. **Token mint.** The gateway validates the IdP response, reads the user's email
   and `groups_claim`, and mints a **short-lived JWT bearer token** signed with its
   `jwt_secret`. Sign-in state is recorded in RDS; the token itself is self-contained.
5. **Inference.** From then on Claude Code sends that bearer token on every request
   over the private network to the internal ALB. The gateway validates the token
   *locally* (no DB round-trip), checks the requested model against the allowlist,
   and forwards the call to **Amazon Bedrock using its own ECS task role**. The
   response streams back. The developer never held an AWS key or an API key.

Offboarding is just removing the user from the IdP — their next token can't be
minted, and any live token expires within `session.ttl_hours`.

## Prerequisites

| Need | Detail |
|------|--------|
| Claude Code ≥ 2.1.195 | On the server image **and** every developer laptop (`claude --version`). ≥ 2.1.198 recommended for laptops — that's when the `/model` picker started sending short-alias model IDs (already covered in the default allowlist). |
| An OIDC IdP | Cognito, Okta, Entra ID, Google Workspace, Keycloak, … This guide uses Amazon Cognito, but any works — see [Identity](#step-2--set-up-identity-oidc-client). |
| AWS account + admin credentials | Used for deploy. Set `AWS_REGION` (and `AWS_PROFILE` if you use named profiles). |
| Bedrock model access | Enable the Claude models you want in the Bedrock console, in your region. |
| Private network path | Developers must reach an **internal** ALB by **private** DNS — see [Network access](#step-4--give-developers-network-access). Existing VPN/Direct Connect/TGW is fine; a reference Client VPN is included if you have none. |
| Docker, AWS CLI, openssl | Local tooling for the image build and cert generation. |

> **New to the config file?** Read [`CONFIG.md`](CONFIG.md) first — it walks through
> the five required `gateway.yaml` sections (`listen` / `oidc` / `session` / `store`
> / `upstreams`) and the optional policy / telemetry / spend-cap blocks, explaining
> *why* each is set the way it is on AWS.

> **Why a private network?** Claude Code's `/login` **rejects any gateway whose
> hostname resolves to a public IP** — a security guard, because a trusted
> gateway can push settings that run commands on developer machines. So the ALB
> is **internal and IPv4-only** (dual-stack internal ALBs hand out public-range
> IPv6 and would be rejected), and developers reach it over a private network.
> **This does not require a dedicated VPN** — any existing private path works.

---

## Step 1 — Build and push the gateway image

The gateway *is* the `claude` binary run as `claude gateway`. We build a minimal
glibc image around the pinned, GPG-verified native Linux binary.

> **Skip this step if you're using `./deploy-all.sh` with `BUILD_IMAGE=true`** —
> the orchestrator runs `build-and-push.sh` for you and captures the image URI
> automatically. Read on only if you're driving `./deploy.sh` directly.

```bash
cd gateway
export AWS_REGION=<your-region>            # AWS_PROFILE optional
./build-and-push.sh                          # defaults CLAUDE_VERSION from VERSION file
```

This verifies the binary against the release's GPG-signed `manifest.json`,
pushes to ECR, and prints the image URI. Note it for Step 3.

## Step 2 — Set up identity (OIDC client)

The gateway is a confidential OIDC web app. Its redirect URI must be exactly
`https://<gateway-host>/oauth/callback`. Pick the path that matches what you have
(full detail in [`idp/README.md`](../idp/README.md)):

- **Already run a Cognito pool?** Deploy `idp/cognito-existing-pool.yaml` — it
  adds a confidential client to your pool and stores the secret in Secrets
  Manager. You only need your **user pool id**.
- **No IdP yet?** Deploy `idp/cognito-create-pool.yaml` — it stands up a fresh
  pool, hosted-UI domain, confidential client, and an invite-only admin user.
- **Okta / Entra / Google / Keycloak?** Create a confidential OIDC web app there,
  put its secret in Secrets Manager, and pass `issuer`, `client_id`, the secret
  ARN, and your `GroupsClaim` to the gateway stack. The design is IdP-agnostic.

Each path outputs a `ClientId`, `ClientSecretArn`, and `Issuer` for Step 3.

## Step 3 — Deploy: pick your path

Three paths cover the common cases. Pick the one that matches what you already have.

### Path A — All bundled (one command, greenfield)

You have no IdP / no OTEL collector / no VPN to plug into. Use the orchestrator
and a profile — it deploys Cognito → gateway → (optional) collector → gateway
update → (optional) VPN in one command, with no copy-paste between stacks.

```bash
cp config/managed-newcognito-collector-vpn.env config/my.env
$EDITOR config/my.env                       # fill in 5 values
source config/my.env
./deploy-all.sh                             # preflight -> everything -> summary
```

Profiles available under `config/`:
- **`managed-newcognito-collector-vpn.env`** — full greenfield with everything.
- **`managed-newcognito-notelemetry.env`** — Cognito + gateway only; no telemetry, no VPN.
- **`selfsigned-fallback.env`** — no public domain; self-signed cert path.

### Path B — BYO everything (your IdP, your collector, your network)

You already run an OIDC IdP (Okta / Entra / Google / Keycloak / existing Cognito),
your own OTEL collector, and have private connectivity into AWS. Skip the
orchestrator; call `deploy.sh` directly. Nothing bundled deploys.

**Callback URL to register in your IdP:** `https://$DOMAIN_NAME/oauth/callback`.

```bash
export GATEWAY_IMAGE_URI=<from gateway/build-and-push.sh>
export OIDC_ISSUER=https://example.okta.com/oauth2/default
export OIDC_CLIENT_ID=0oa1abcdEFGHIJKLMN0h8
export OIDC_CLIENT_SECRET_ARN=arn:aws:secretsmanager:...:secret:oidc-abc123
export GROUPS_CLAIM=groups                              # Cognito=cognito:groups, Entra=roles
export DOMAIN_NAME=claude-gateway.example.com
export PUBLIC_HOSTED_ZONE_ID=Zxxxxxxxxxxxxx
export ALLOWED_DOMAINS=example.com
export CLIENT_CIDR=10.0.0.0/8                           # your VPN/DX client range
export COLLECTOR_ENDPOINT=https://your-otel.example.com/  # must be https; or "off"
./deploy.sh
```

Or use the profile: [`config/byo-oidc-notelemetry.env`](../config/byo-oidc-notelemetry.env)
(no telemetry) — change `COLLECTOR_ENDPOINT` from `off` to your URL for BYO telemetry.

### Path C — Mix (existing Cognito + BYO collector + bundled VPN, or any combo)

Set `IDP_MODE=existing-cognito`, `ENABLE_COLLECTOR=false` (with a
`COLLECTOR_ENDPOINT` URL for BYO telemetry), and `ENABLE_VPN=true` (to bundle
the reference AWS Client VPN), then use `./deploy-all.sh`. Any combination of
toggles works. See [`config/managed-existingcognito-byotelemetry.env`](../config/managed-existingcognito-byotelemetry.env)
as a starting point.

### BYO integration reference

Whichever path you pick, these are the plug-in points:

| Subsystem | What you provide | Set as |
|-----------|------------------|--------|
| **IdP** (Okta/Entra/Google/…) | Issuer URL, client_id, secret ARN, groups claim | `OIDC_ISSUER`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET_ARN`, `GROUPS_CLAIM`. Callback = `https://$DOMAIN_NAME/oauth/callback`. |
| **OTEL collector** | HTTPS OTLP endpoint (cert must chain to a public CA or your bundled CA) | `COLLECTOR_ENDPOINT=https://your.otel/`. HTTP is rejected. |
| **Network access** | Your VPN/DX/TGW/peering into the gateway VPC + private DNS resolution of `$DOMAIN_NAME` | `CLIENT_CIDR=<your client pool>`. See [`infrastructure/network-access/README.md`](../infrastructure/network-access/README.md). |
| **Image** | (Optional) a pre-built ECR image tag; else `BUILD_IMAGE=true` builds it | `GATEWAY_IMAGE_URI=...` |

### Cert-mode reference

The cert-mode choice is the single biggest variable in Step 3. Below is the
detail for each of the two supported cert paths — read only the one you're
using.

#### Option A — Managed public certificate (recommended)

Set a public Route53 zone you own + a public hostname. The stack creates a
**DNS-validated public ACM certificate** and a public alias A-record to the
**internal** ALB. The cert is browser-trusted, so developers need **no**
`NODE_EXTRA_CA_CERTS`, **no** keychain import, **no** fingerprint prompt. The ALB
stays internal/IPv4-only — the public name resolves to private IPs (reachable
over your VPN), so `/login`'s private-IP check is still satisfied.

```bash
export AWS_REGION=<your-region>                # AWS_PROFILE optional
export GATEWAY_IMAGE_URI=<from step 1>
export OIDC_ISSUER=<from step 2>
export OIDC_CLIENT_ID=<from step 2>
export OIDC_CLIENT_SECRET_ARN=<from step 2>
export PUBLIC_HOSTED_ZONE_ID=<Zxxxxxxxx>       # a PUBLIC Route53 zone you own
export DOMAIN_NAME=claude-gateway.example.com  # within that zone
export ALLOWED_DOMAINS=example.com             # who may sign in
export CLIENT_CIDR=10.30.0.0/16                # client range allowed to the ALB
# Optional telemetry (see observability/), preferably an HTTPS collector:
# export COLLECTOR_ENDPOINT=https://claude-otel.example.com
./deploy.sh
```

> The stack **blocks ~2-8 min** while ACM validates the domain via DNS (it writes
> the validation record into your public zone automatically). If it hangs much
> longer, the zone id isn't the public authoritative zone.
>
> **The OIDC client callback must be `https://$DOMAIN_NAME/oauth/callback`** — if
> you change the hostname, update the IdP client (Step 2) to match, or `/login`
> fails at the IdP.

#### Option B — Self-signed / bring-your-own cert (fallback, no domain)

Omit the public vars and set a private zone; `deploy.sh` generates a self-signed
cert, imports it to ACM, and writes `gateway-ca.pem` (distribute to laptops,
Step 6). Or pass your own `CERT_ARN`. Requires the client-side trust steps in
Step 6.

```bash
# ... same OIDC/IMAGE/ALLOWED_DOMAINS vars as above, then:
export ZONE=internal.example.com               # private hosted zone to create
export GATEWAY_HOST=claude-gateway.$ZONE
./deploy.sh                                      # (or: export CERT_ARN=<your acm arn>)
```

When it finishes it prints the **Gateway URL**.

> **Model catalog / non-US regions:** the gateway's built-in catalog only maps
> `us.anthropic.*` IDs. In other regions (e.g. APAC/EU) set
> `auto_include_builtin_models: false` in `gateway.yaml` and list your region's
> ACTIVE CRIS inference-profile IDs explicitly
> (`aws bedrock list-inference-profiles --region <region>`). The shipped
> `gateway/gateway.yaml.example` shows the shape.

## Step 4 — Give developers network access

The ALB is private, so developers need a private path to the gateway VPC **and**
private DNS resolution of the gateway hostname. **You do not have to deploy a
VPN** — see [`infrastructure/network-access/README.md`](../infrastructure/network-access/README.md)
for the full decision guide. In short:

- **You already have connectivity** (corporate VPN, Direct Connect, Site-to-Site
  VPN, Transit Gateway, or VPC peering): route the gateway VPC CIDR over it,
  make the gateway's private hosted zone resolvable to those clients (associate
  the zone with their VPC, or use a Route 53 inbound resolver), and set the
  gateway stack's `CLIENT_CIDR` to your client range. **No stack to deploy.**

- **You have no private path:** deploy the included reference **AWS Client VPN**:

  ```bash
  cd infrastructure/network-access
  ./make-vpn-certs.sh developer1        # prints ServerCertificateArn + ClientRootCertificateArn

  aws cloudformation deploy --stack-name claude-gateway-vpn \
    --template-file client-vpn.yaml --region "$AWS_REGION" \
    --parameter-overrides \
      ServerCertificateArn=<...> ClientRootCertificateArn=<...> \
      VpcId=<gateway stack VpcId output> \
      SubnetId1=<private subnet 1> SubnetId2=<private subnet 2> \
      VpcCidr=<gateway VpcCidr output> VpcDnsResolver=<VPC base + 2, e.g. 10.20.0.2>
  ```

  Export the client config and append the client key/cert:

  ```bash
  aws ec2 export-client-vpn-client-configuration \
    --client-vpn-endpoint-id <id> --output text --region "$AWS_REGION" > claude-gw.ovpn
  # then append <cert>…</cert> and <key>…</key> from vpn-pki/developer1.{crt,key}
  ```

  The reference VPN pushes the VPC `.2` resolver so the gateway's **private** DNS
  name resolves to a private IP — which is what `/login` requires.

## Step 5 — Verify the gateway (from a machine on the private network)

```bash
H=https://claude-gateway.example.com      # your DOMAIN_NAME (managed) or private host
# Managed cert: drop -k (cert is publicly trusted). Self-signed: add -k or --cacert gateway-ca.pem.
curl -s $H/healthz                        # 200 (liveness)
curl -s $H/readyz                         # 200 (Postgres reachable)
curl -s $H/.well-known/oauth-authorization-server | jq   # full boot ok; issuer = your URL
curl -s -X POST $H/oauth/device_authorization | jq       # returns a user_code
```

Then open the `verification_uri_complete` in a browser → you're redirected to
your IdP → sign in → "signed in" confirmation. Check the gateway's audit log
(ECS task logs) for a `session.mint` event.

## Step 6 — Connect developer laptops

On each laptop, write the per-OS **managed settings** file (or push via MDM):

```json
{
  "forceLoginMethod": "gateway",
  "forceLoginGatewayUrl": "https://claude-gateway.internal.example.com"
}
```

Paths: macOS `/Library/Application Support/ClaudeCode/managed-settings.json`,
Linux `/etc/claude-code/managed-settings.json`,
Windows `C:\ProgramData\ClaudeCode\managed-settings.json`.

**Managed public cert (Option A):** nothing else needed — the cert is
browser-trusted, so no `NODE_EXTRA_CA_CERTS`, no keychain import, no fingerprint
prompt. Just:

```bash
claude /login          # opens directly on the Cloud gateway screen
```

**Self-signed / BYO (Option B) only:** also distribute `gateway-ca.pem` and set
`NODE_EXTRA_CA_CERTS=/path/to/gateway-ca.pem` (or install it in the OS trust
store) before `claude /login`. Use Chrome/Safari (they read the OS keychain);
Firefox uses its own store and its HSTS block makes self-signed painful. The CLI
also shows a one-time TLS fingerprint prompt.

Press Enter, complete the browser sign-in, and run a prompt. Inference now flows
laptop → gateway → Bedrock.

## Onboarding a colleague

**Automated path (recommended):**

```bash
# One command creates their Cognito user, mints a per-peer VPN client cert,
# and assembles a zip bundle (VPN profile + managed-settings + setup.sh + README).
./make-peer-bundle.sh alice alice@example.com
# -> peer-bundles/alice-bundle.zip
```

Send the zip via a secure channel. If you want to share it via an expiring
S3 presigned URL (safer than plain Slack attachments), deploy the optional
distribution stack once and use the delivery helper:

```bash
# One-time (per account+region):
aws cloudformation deploy --stack-name claude-gateway-distribution \
  --template-file infrastructure/distribution.yaml \
  --region <your-region> --tags auto-delete=no project=claude-apps-gateway

# Per peer:
./distribute-peer-bundle.sh alice
# -> uploads to a private bucket, prints a 24 h presigned URL +
#    a Slack-ready message you can paste into a DM.
```

The peer follows the `README.md` inside their bundle (5 steps: install prereqs,
import `.ovpn`, run `setup.sh`, `claude /login`, run a prompt). Bundle README
also documents the MTU 1300 workaround and stale-cache troubleshooting.

**Manual fallback** (skip the scripts): create the Cognito user by hand
(`aws cognito-idp admin-create-user ...`), run `make-vpn-certs.sh <name>` to
mint a client cert + assemble a `.ovpn`, hand-write `managed-settings.json`
with `forceLoginGatewayUrl` set to your gateway URL, and send everything +
"install Claude Code ≥ 2.1.195" to the peer.

## Telemetry (optional, no hard dependency)

Set `COLLECTOR_ENDPOINT` at deploy time to forward OTLP/HTTP **metrics**
(identity-stamped per user) to **any** existing OTLP collector. Leave it empty
and the gateway forwards nothing and works fully. The gateway pushes `OTEL_*`
env to clients automatically; developers configure nothing. Enable
`logs`/`traces` per-destination only on backends with appropriate retention —
they can carry commands and file paths.

> **Reusing an existing collector.** `COLLECTOR_ENDPOINT` accepts any reachable
> OTLP/HTTP endpoint — an OTEL collector you already run, a vendor endpoint, or a
> collector from another deployment. The gateway has no build- or deploy-time
> dependency on it; it's a plain URL, off by default.

## Resilience and scalability

The gateway is built to scale to a large-org rollout, and the template ships
production-ready:

**Where load actually goes.** Inference requests (`claude → gateway → Bedrock`)
and session refreshes validate bearer tokens *locally against the JWT secret* —
they **never touch Postgres**. The database is hit only on **sign-in** (the
device-grant flow) plus rate-limit counters, and (only if you enable spend
limits) durable spend tables. So DB load scales with sign-in rate, not request
rate; the request path scales on the stateless Fargate tier.

**What scales it, in this template:**

| Concern | How it's handled | Knob |
|---------|------------------|------|
| Compute (the hot path) | ECS Service Auto Scaling — target-tracking on CPU (60%) **and** ALB requests/target | `MinTasks` (default 2), `MaxTasks` (default 10), `TargetRequestsPerTask` |
| Multi-AZ availability | ≥2 tasks spread across two AZs behind the ALB | `MinTasks` ≥ 2 |
| Egress HA | **Regional NAT gateway** — one VPC-level NAT that auto-expands across AZs (no per-AZ NAT, HA by default, higher port limits) | (automatic) |
| Bad-deploy safety | ECS deployment **circuit breaker with auto-rollback** | (always on) |
| Database failover | RDS Multi-AZ (standby in a second AZ) | `MultiAzDatabase=true` |
| Bedrock capacity | The real ceiling — plan per-model RPM/TPM quota; the gateway supports multi-upstream **failover** (provisioned-throughput → on-demand, cross-region) | `upstreams:` / `models:` blocks |

**Demo vs. production defaults.** The defaults run `MinTasks=2` (HA) with
`MultiAzDatabase=false` to keep cost modest. For production set
`MultiAzDatabase=true`, raise `MaxTasks`, and right-size `TaskCpu`/`TaskMemory`.
The regional NAT is HA either way. Multi-tenant/multi-org means **one gateway
deployment per OIDC issuer** (the gateway is single-tenant per issuer), each
independently autoscaled.

## Operations notes

- **Health:** liveness `/healthz`, readiness `/readyz`. The target group probes
  `/healthz` so a brief Postgres outage doesn't drain all replicas.
- **Secrets:** OIDC client secret, JWT secret, and DB password live in Secrets
  Manager; the rendered `gateway.yaml` in SSM keeps them as `${VAR}` and the
  gateway expands them at boot. Rotate the JWT secret as a prepend-then-roll
  array (see the config reference).
- **Upgrades:** rebuild the image with a newer pinned `claude` version and
  redeploy; migrations are append-only and run at boot.
- **Teardown:** delete `claude-gateway-vpn` (if deployed), then `claude-gateway`,
  then the IdP client stack. RDS is created with `DeletionPolicy: Delete` in this
  example (no snapshot) — switch to `Snapshot` for production with spend tables.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `/login`: *resolves to a public address* | The ALB name resolved to a public IP. Confirm `IpAddressType: ipv4`, internal scheme, and that you're on the private network resolving via the private hosted zone. |
| `/login`: *could not resolve gateway host* | Not on the private network, or the private hosted zone isn't resolvable there (associate the zone with your VPC or use a Route 53 inbound resolver / the reference VPN's pushed `.2` resolver). |
| `/login` hangs / `curl https://<gateway>` hangs after VPN connect | Tunnel MTU 1500 drops large TLS packets. Fix: `sudo ifconfig utunN mtu 1300` on the VPN interface. See [`infrastructure/network-access/README.md`](../infrastructure/network-access/README.md#troubleshooting). |
| `Couldn't load settings from Cloud gateway https://<OLD-host>` after switching gateway hostname | Stale cache pins the old host. Delete `~/.claude/remote-settings.json` (cached OTLP endpoint) and the macOS keychain entry `Claude Code-credentials` (`security delete-generic-password -s "Claude Code-credentials"`) — plus the old cert if you trusted it (`sudo security delete-certificate -c <old-host> /Library/Keychains/System.keychain`). Then re-run `claude /login`. |
| 400 *model ... is not in the operator's model allowlist* | The CLI's default model isn't in the gateway's `models:` block. Add the exact id the CLI sends (e.g. `global.anthropic.claude-opus-4-8` or a short alias like `claude-sonnet-5` from CLI ≥ 2.1.198) to `gateway.yaml.example` and redeploy. |
| 400 *upstream rejected the request* on Fable 5 (`global.anthropic.claude-fable-5`) with a Bedrock hint about *"data retention mode 'default' is not available for this model"* | Anthropic's Fable model requires the account's Bedrock data-retention posture to be set appropriately. Not a gateway or IAM issue — open an AWS Support case for your account to enable Fable-compatible data retention, or remove the Fable 5 entries from the allowlist for now. |
| Every Bedrock request 502, *could not load credentials* | Task role missing or model access not enabled. ECS task role avoids the EC2 IMDSv2 hop-limit bug by design. |
| 400 *model not granted* | Region model mismatch — fix the `models:` block CRIS IDs for your region. |
| Repeated TLS trust prompt | Use the **managed public ACM cert** path (Step 3, Path A) — it's browser-trusted and this warning disappears. For self-signed: use a stable cert and distribute `gateway-ca.pem`. |
| `deploy.sh` says `Token has expired and refresh failed` | AWS SSO session expired. Run `aws sso login --profile <yours>` and retry. deploy.sh now sanity-checks credentials up front. |

---

## FAQ

**How much does it cost?** No gateway license fee — just AWS infrastructure
(order of **~$40/month** of fixed resources for a low-traffic deployment: 2 Fargate
tasks + `db.t4g.micro` RDS + internal ALB + regional NAT) plus your normal Bedrock
inference, billed exactly as it would be without the gateway. See the cost table in
the [README](../README.md#cost-note).

**Can CI/CD pipelines use the gateway?** No — the gateway requires browser SSO.
Point CI at Amazon Bedrock directly with IAM credentials instead.

**What about Claude Desktop / other Claude apps?** This gateway is for **Claude
Code**. Claude Desktop on Bedrock has its own separate MDM configuration path.

**Can it fail over between regions?** Yes. List multiple `upstreams` with different
regions; the gateway tries them in order and fails over on `5xx`/`429`/timeout (not
on `4xx`). See [`CONFIG.md`](CONFIG.md#5-upstreams--where-inference-goes-routing).

**Can the gateway run in one account and call Bedrock in another?** Yes — each
upstream can carry its own credentials (e.g. a cross-account assumed role).

**What happens if Postgres goes down?** Already-signed-in developers keep working
(bearer tokens validate locally against `jwt_secret`); *new* sign-ins fail until RDS
recovers. Spend enforcement fails **open** by default (set it to fail closed if you
need hard budget stops).

**Which models can developers use?** Whatever's in the gateway's `models:` allowlist
*and* enabled for Bedrock access in your region. The allowlist `id:` must match the
exact string the CLI sends — see [`CONFIG.md`](CONFIG.md#the-model-catalog-policy-part-1).

**How do I restrict models by team?** Add group policies keyed on your IdP's
`groups_claim` — engineering gets Opus, contractors get Haiku only, etc. See
[`CONFIG.md`](CONFIG.md#group-based-policy-policy-part-2).
