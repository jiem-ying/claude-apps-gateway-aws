# Claude Apps Gateway on AWS — standalone example

Run Claude Code across a whole team **without putting AWS credentials or API keys
on any developer machine.** The [Claude Apps Gateway](https://code.claude.com/docs/en/claude-apps-gateway)
is a proxy that lives in *your* AWS account: developers sign in with your corporate
SSO, and the gateway routes every request to Amazon Bedrock using a single IAM
role it holds. Developers just run `claude /login` — no AWS profiles, no keys, and
the Bedrock credential never leaves AWS. Offboarding is removing someone from your
IdP; the gateway also gives you per-user cost attribution and model-access policies
by team.

This repo is a **self-contained, copy-out-able** example that stands the gateway
up on ECS Fargate. **Nothing else in this repository is required** — you can lift
this directory into its own repo and deploy it as-is.

```
┌ your AWS account (private VPC) ──────────────────────────────┐
│  internal IPv4 ALB → ECS Fargate (`claude gateway`)          │
│      ├─ OIDC RP → your IdP (Cognito / Okta / Entra / …)      │
│      ├─ RDS PostgreSQL (sign-in + rate-limit + spend state)   │
│      └─ Amazon Bedrock upstream (via ECS task role)          │
└──────────────────────────────────────────────────────────────┘
   developers reach the internal ALB over your private network
   (existing VPN / Direct Connect / TGW / peering — or the bundled reference Client VPN)
```

## What's here

| Path | What it is |
|------|-----------|
| `infrastructure/claude-apps-gateway.yaml` | **The core stack.** Self-contained VPC + RDS + ECS Fargate + internal IPv4 ALB + regional NAT + private DNS + autoscaling. No cross-stack references. |
| `gateway/` | Container image (`Dockerfile`, `entrypoint.sh`), `build-and-push.sh`, and the annotated `gateway.yaml.example` config. |
| `idp/` | OIDC identity. `cognito-create-pool.yaml` (new pool), `cognito-existing-pool.yaml` (reuse a pool), or bring any OIDC IdP. |
| `infrastructure/network-access/` | **Optional, swappable.** How laptops reach the private ALB — "bring your own VPN/DX/TGW" is the primary path; a reference AWS Client VPN is included if you have none. |
| `observability/` | **Optional.** Self-hosted ADOT OTEL collector (ECS + internal HTTPS ALB) → CloudWatch metrics + dashboard. For orgs with no third-party observability platform. Toggle = deploy it or not; telemetry can also point at any HTTPS OTLP collector you already run. |
| `deploy.sh` | One-shot deploy: cert → render config → core stack. Profile-agnostic. |
| `docs/GUIDE.md` | The full step-by-step walkthrough, operations, resilience, and troubleshooting. |

## Design principles

- **Private by requirement, not by VPN.** Claude Code's `/login` rejects any
  gateway that resolves to a public IP, so the ALB is internal + IPv4-only. All
  that's needed is *private reachability + private DNS* — **a dedicated VPN is
  one option, not a requirement.** If you already have connectivity into AWS,
  use it. See [`infrastructure/network-access/README.md`](infrastructure/network-access/README.md).
- **Browser-trusted TLS, AWS-managed.** Set a public Route53 zone + hostname and
  the stack issues a **DNS-validated public ACM cert** — no self-signed CA, no
  `NODE_EXTRA_CA_CERTS`, no keychain import, no fingerprint prompt. The public
  name aliases the internal ALB, so it resolves to private IPs (VPN-reachable)
  while staying publicly trusted. Self-signed remains a no-domain fallback.
- **IdP-agnostic.** Any OIDC provider via four inputs (`OidcIssuer`,
  `OidcClientId`, `OidcClientSecretArn`, `GroupsClaim`). Cognito templates are
  provided for convenience.
- **Telemetry optional.** `CollectorEndpoint` forwards OTLP/HTTP metrics to any
  collector you already run — off by default, no hard dependency.
- **HA + autoscaling by default.** ≥2 tasks across AZs, regional NAT, ECS
  target-tracking autoscaling, deployment circuit breaker with rollback.

## Quick start

### Prerequisites (all paths)

- **A domain you own**, hosted in a **PUBLIC Route53 zone in your own AWS account**
  (e.g. `example.com` or a subdomain). This is what the gateway's public ACM cert
  is issued against. You cannot borrow someone else's zone — ACM validates via
  DNS, and only the zone's owner can write the validation record. If you don't
  have a domain yet, register one (Route53 or elsewhere) and delegate it, or
  create a subdomain zone under one you own. The [self-signed profile](config/selfsigned-fallback.env)
  is the no-domain fallback (with UX friction).
- **AWS credentials** with permission to create VPC / RDS / ECS / ACM /
  Route53 / ECR / Secrets Manager resources.
- **Bedrock model access** enabled in the console for the Claude models you want,
  in your deploy region.
- **Claude Code CLI ≥ 2.1.195** on both the gateway image and every developer's
  machine — this is the first release with the `claude gateway` subcommand and the
  gateway `/login` flow. ≥ 2.1.198 is recommended (the modern `/model` picker and
  Claude Platform on AWS support landed there). Developers update with `claude update`.
- **A way to push a JSON file to developer machines** (MDM such as Jamf or Intune,
  or config management). One `managed-settings.json` tells each machine where the
  gateway is; without it developers see the standard login picker instead of the
  gateway flow. See [`docs/GUIDE.md`](docs/GUIDE.md#step-6--connect-developer-laptops).
- **Local CLI tools** for running the scripts: `aws` CLI v2, `bash` 4+, `openssl`,
  `git`, plus `docker` (only when building the image) and `zip` (only for peer
  bundles). No `jq` required. `cfn-lint` is optional (used by the contributor dev loop).

### Pick your path

A handful of profiles cover ~everything. Answer these questions about what you
already have in your org:

| Do you have… | Domain? | IdP? | OTEL collector? | Private network path? | → Profile |
|---|---|---|---|---|---|
| Nothing yet (greenfield) | yes | no | no | no | [`managed-newcognito-collector-vpn.env`](config/managed-newcognito-collector-vpn.env) |
| An **existing Cognito pool** you want the gateway to attach to | yes | Cognito | BYO HTTPS OTLP | yes (corp VPN/DX/TGW) | [`managed-existingcognito-byotelemetry.env`](config/managed-existingcognito-byotelemetry.env) |
| Any **other OIDC IdP** (Okta/Entra/Google/Keycloak), no telemetry | yes | Okta/Entra/… | off | yes | [`byo-oidc-notelemetry.env`](config/byo-oidc-notelemetry.env) |
| **BYO OIDC IdP + your own OTLP collector** | yes | Okta/Entra/… | BYO HTTPS OTLP | yes | [`byo-oidc-byotelemetry.env`](config/byo-oidc-byotelemetry.env) |
| Just want to try it, minimal cost | yes | no | no | yes | [`managed-newcognito-notelemetry.env`](config/managed-newcognito-notelemetry.env) |
| No public domain (yet) | **no** | any | any | any | [`selfsigned-fallback.env`](config/selfsigned-fallback.env) *(UX friction — see profile notes)* |

Each profile is a documented `.env` file: copy, edit ~5 values, then one command.

```bash
# 0. Enable Claude model access in the Bedrock console for your region.

# 1. Pick a profile, copy + edit
cp config/managed-newcognito-collector-vpn.env config/my.env
$EDITOR config/my.env                       # fill in DOMAIN_NAME, PUBLIC_HOSTED_ZONE_ID, etc.

# 2. Deploy everything in one go
source config/my.env
./deploy-all.sh                             # preflight -> IdP -> gateway -> [collector -> gateway update] -> [VPN] -> summary
```

The orchestrator prints a final summary with your gateway URL, dashboard link,
and (if VPN bundled) the `.ovpn` path. Then push `managed-settings.json` to
laptops per [`docs/GUIDE.md`](docs/GUIDE.md#step-6--connect-developer-laptops).

### Already have your own IdP / collector / network?

Skip the orchestrator entirely — call `deploy.sh` directly with your existing
endpoints. Nothing bundled deploys.

```bash
export GATEWAY_IMAGE_URI=<from gateway/build-and-push.sh>
export OIDC_ISSUER=... OIDC_CLIENT_ID=... OIDC_CLIENT_SECRET_ARN=... GROUPS_CLAIM=groups
export DOMAIN_NAME=claude-gateway.example.com  PUBLIC_HOSTED_ZONE_ID=Zxxxxxxxxxxxxx
export ALLOWED_DOMAINS=example.com  CLIENT_CIDR=10.0.0.0/8
export COLLECTOR_ENDPOINT=https://your.otel/    # or =off for no telemetry
./deploy.sh
```

Callback URL for your IdP client: `https://$DOMAIN_NAME/oauth/callback`.
Full walkthrough (BYO integration details for each subsystem):
**[`docs/GUIDE.md`](docs/GUIDE.md)**.

## Onboarding peers

> **This section applies only if you deployed the bundled reference AWS Client
> VPN.** The peer bundle exists to hand someone a ready-to-use VPN profile, so it
> requires the `claude-gateway-vpn` stack. **If you bring your own network**
> (corporate VPN / Direct Connect / TGW / peering), skip this — peers reach the
> gateway over your existing private path, and you onboard them by creating their
> IdP user and pushing `managed-settings.json` (see
> [`docs/GUIDE.md`](docs/GUIDE.md#step-6--connect-developer-laptops)). For the
> network paths themselves, see
> [`infrastructure/network-access/README.md`](infrastructure/network-access/README.md).

With the reference VPN deployed, add a peer in one command:

```bash
./make-peer-bundle.sh alice alice@example.com
# -> peer-bundles/alice-bundle.zip  (VPN profile + Cognito user + managed-settings)
```

The zip contains a **VPN client private key** — treat it as sensitive. To share
safely, deploy the optional distribution stack once, then upload + presign:

```bash
# One-time (per account/region):
aws cloudformation deploy --stack-name claude-gateway-distribution \
  --template-file infrastructure/distribution.yaml \
  --region <your-region> --tags auto-delete=no project=claude-apps-gateway

# Per peer:
./distribute-peer-bundle.sh alice
# -> uploads to a private S3 bucket, prints a 24h presigned URL + a
#    Slack-ready message you can paste into a DM.
```

The bucket has all-public-access-blocked, TLS-only, SSE-encrypted, and a 7-day
object-lifecycle expiry so onboarding artifacts don't linger.

## Versioning

The repo pins two versions in a single [`VERSION`](VERSION) file:
- `repo_version` — this deployment guide's version (semver; `v1.0.0` first release)
- `claude_binary_version` — the Claude Code CLI release used as the gateway image

Scripts read `VERSION` as the default; `CLAUDE_VERSION=<x.y.z>` still overrides for
a one-off build. Upgrading the gateway is a two-step change:

1. Bump `claude_binary_version` in `VERSION` (check compatibility at
   [Anthropic's release notes](https://code.claude.com/docs/en/claude-apps-gateway-deploy#upgrades) —
   the gateway server and every developer's CLI must be at ≥ that version).
2. Rebuild + push the image: `( cd gateway && ./build-and-push.sh )` then
   redeploy with the new `IMAGE_TAG`. ECS auto-cycles tasks (the config lives
   in the task-def, so revision-bumps trigger a rollout).

Tag releases with `git tag v1.0.0 && git push --tags`.

## What the gateway does (five capabilities)

The gateway is more than a passthrough. Once it's running you get:

| Capability | What it gives you |
|---|---|
| **Identity** | SSO via any OIDC IdP. The gateway mints short-lived bearer tokens; developers never hold AWS credentials. |
| **Policy** | Model allowlists and tool permissions per IdP group — e.g. engineering gets Opus, contractors get Haiku only. Enforced server-side. |
| **Telemetry** | Per-user usage/cost attribution forwarded as OTLP to any collector you run (or the bundled one). Off by default. |
| **Routing** | The gateway holds the Bedrock credential and routes inference on developers' behalf, with optional multi-region/-account failover. |
| **Spend caps** | Optional per-user/group/org daily/weekly/monthly budgets; over-cap requests are blocked until the period resets. |

Identity, routing, and policy are covered in this repo's config; telemetry and
spend caps are optional add-ons. See [`docs/CONFIG.md`](docs/CONFIG.md) for the
`gateway.yaml` sections behind each, and [`docs/GUIDE.md`](docs/GUIDE.md) for the
deploy walkthrough.

## Cost note

No gateway license fee — you pay only for the AWS infrastructure plus your normal
Bedrock inference. The core stack runs these cost-bearing resources 24/7:

| Resource | Purpose | Rough cost* |
|---|---|---|
| 2× ECS Fargate tasks | The gateway (HA across AZs) | ~$9/mo |
| RDS PostgreSQL (`db.t4g.micro`) | Sign-in / rate-limit / spend state | ~$12/mo |
| Internal ALB | Front door for the private VPC | ~$16/mo |
| Regional NAT gateway | Egress for the tasks | data-dependent |
| **Bedrock inference** | Per-token model usage | **billed as usual — same as without the gateway** |

\* Order-of-magnitude estimate for a low-traffic deployment (roughly **$40/mo** of
fixed infrastructure before inference); actual cost varies by region, traffic, and
data transfer. Check the [AWS Pricing Calculator](https://calculator.aws/) for your
region. To cut idle cost, scale ECS to 0 or tear the stack down. Teardown order:
`claude-gateway-vpn` (if any) → `claude-gateway` → the IdP client stack.

## Known limitations

Deliberate trade-offs of this deployment model (not bugs):

- **Browser SSO required** — CI/CD pipelines can't authenticate through the
  gateway. Point CI at Bedrock directly with IAM credentials instead.
- **One OIDC issuer per gateway instance** — multi-tenant setups need one gateway
  per issuer.
- **Claude Code only** — not for Claude Desktop (which has its own Bedrock/MDM path).
- **Server-side web search is disabled** through the gateway; **1-hour prompt
  caching is unavailable** (5-minute only).
- **Built-in model catalog is region-opinionated** — this example ships a
  `global.*`/APAC model list; US and other regions should adjust the `models:`
  block or set `auto_include_builtin_models: true` (see [`docs/CONFIG.md`](docs/CONFIG.md)).
- **No admin UI / no Helm chart** — configuration is the `gateway.yaml` file
  (redeploy to change); Kubernetes users write a standard Deployment.

See the [FAQ in `docs/GUIDE.md`](docs/GUIDE.md#faq) for the reasoning behind these.
