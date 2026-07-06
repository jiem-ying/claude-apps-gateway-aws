---
title: "Run Claude Code for Your Whole Team - Zero API Keys on Developer Laptops"
published: false
tags: ai, aws, devops, claudeai
---

Here's a thing that happens at almost every company that starts using AI coding tools: one developer gets an Anthropic API key, tells two colleagues, and within a week half the team has their own keys stored in `.env` files, shell profiles, and CI jobs. Someone leaves. Their key is still active somewhere. You have no idea what it's calling or how much it's spending.

There's a better model. This post walks through an open-source AWS setup that lets your whole engineering team use Claude Code without a single API key or AWS credential ever touching a developer laptop — and how a few architectural tricks make it work without the usual enterprise friction.

---

## What the gateway actually does

The [Claude Apps Gateway](https://code.claude.com/docs/en/claude-apps-gateway) is a self-hosted proxy you run in your own AWS account. The architecture is deliberately simple:

```
┌ your AWS account (private VPC) ──────────────────────────────┐
│  internal IPv4 ALB → ECS Fargate (claude gateway)            │
│      ├─ OIDC → your IdP (Cognito / Okta / Entra / …)         │
│      ├─ RDS PostgreSQL (sign-in + rate-limit + spend state)   │
│      └─ Amazon Bedrock upstream (via ECS task role)           │
└──────────────────────────────────────────────────────────────┘
   developers reach the ALB over your private network
   (corporate VPN / Direct Connect / TGW — or a bundled reference Client VPN)
```

Developers run `claude /login`, complete corporate SSO in a browser (MFA, conditional access — whatever your IdP enforces), and get a short-lived JWT. That's their credential. The gateway holds the Bedrock IAM role; it never leaves AWS. Offboarding is removing someone from your IdP.

The repo that sets this all up is at [github.com/your-org/claude-apps-gateway-aws](https://github.com) — a self-contained CloudFormation stack you can copy into your own repo and deploy as-is.

---

## Up and running in one command

The repo ships five `.env` profiles covering the common starting points:

| You have… | Profile |
|---|---|
| Nothing yet (greenfield) | `managed-newcognito-collector-vpn.env` |
| Existing Cognito pool | `managed-existingcognito-byotelemetry.env` |
| Okta / Entra / any OIDC IdP | `byo-oidc-notelemetry.env` |
| No public domain (just testing) | `selfsigned-fallback.env` |

Copy one, fill in ~5 values (your domain, Route53 zone ID, and IdP details), and run:

```bash
cp config/managed-newcognito-collector-vpn.env config/my.env
$EDITOR config/my.env      # domain, zone, region — that's mostly it

source config/my.env
./deploy-all.sh
```

The orchestrator chains everything: IdP stack → gateway stack → optional ADOT collector → optional Client VPN. It prints a summary at the end with the gateway URL, CloudWatch dashboard link, and `.ovpn` path if VPN was bundled.

If you already have your own IdP, OTLP collector, and private network path, skip `deploy-all.sh` entirely and call `deploy.sh` directly with your existing endpoints — nothing bundled deploys.

---

## Three architectural tricks worth borrowing

### 1. Public certificate + private address

The ALB is **internal and IPv4-only** — that's not optional. Claude Code's `/login` flow explicitly rejects any gateway that resolves to a public IP address, so the isolation is enforced by the client, not by policy.

The certificate, however, needs to be browser-trusted, and getting there without distributing a self-signed CA to every laptop is painful. The solution is: issue a **DNS-validated public ACM certificate** against your domain, then point the public A-record at the **internal ALB**.

The domain resolves to private IPs (`10.20.x.x`), reachable only over your private network. But the cert was validated against a public DNS name, so browsers trust it. Zero `NODE_EXTRA_CA_CERTS`, zero keychain imports, zero fingerprint prompts.

### 2. Config lives in the task definition, not SSM

The rendered `gateway.yaml` config is passed as an ECS task-definition environment variable. This means any config change — model allowlist, telemetry endpoint, RBAC policies — forces a new task-def revision, and ECS automatically cycles the running tasks to pick it up.

We tried an earlier version that fetched config from SSM at runtime. It broke in a subtle way: if you updated the telemetry endpoint in SSM, the running tasks kept using the old one until manually recycled. Config-in-taskdef makes the deploy process the source of truth.

The constraint is a 4096-byte ECS env var limit. The current render is ~3000 bytes. `deploy.sh` fails fast with a byte count if the rendered config exceeds the limit.

### 3. GPG-verified binary download in Docker

The Dockerfile uses a two-stage build. Stage 1 imports Anthropic's release signing key (fingerprint hardcoded), downloads a signed manifest, verifies the detached signature, downloads the `claude` Linux binary, and SHA256-checks it against the manifest. Only the verified binary is copied into the runtime stage.

```dockerfile
# stage 1: verify
RUN gpg --import anthropic-release-key.asc \
 && gpg --verify manifest.json.sig manifest.json \
 && sha256sum --check <(jq -r '...' manifest.json)

# stage 2: minimal runtime
FROM debian:stable-slim
COPY --from=verifier /usr/local/bin/claude /usr/local/bin/claude
```

The runtime image is `debian:stable-slim` with only `ca-certificates` added. No verification tooling ships to production.

---

## RBAC without a new system

Group-based access control is two env vars away:

```bash
export DENY_TOOL_GROUP=contractors
export DENY_TOOLS="mcp__bash,mcp__computer"
```

`deploy.sh` renders these into a `managed.policies` block in the gateway config — a first-match policy list that denies those tools to the specified IdP group, with a catch-all that leaves everyone else unrestricted:

```yaml
managed:
  policies:
    - name: contractors-deny-shell
      match:
        groups: ["contractors"]
      deny:
        tools: ["mcp__bash", "mcp__computer"]
    - name: everyone-else
      match: {}
```

Model allowlists work the same way — engineering gets Opus, contractors get Haiku. Policy changes take effect on redeploy; a user's new group membership takes effect on their next `claude /login`.

---

## Observability: metrics vs. Logs Insights

The bundled ADOT collector exports OTLP events to CloudWatch. Only `user.email` and `user.groups` are promoted to CloudWatch EMF metric **dimensions** on `token.usage` and `cost.usage` events. Every distinct dimension value creates a new custom metric, and CloudWatch charges per metric. So: keep dimensions low-cardinality.

High-cardinality slicing — per-user spend breakdowns, per-role analysis — is done in **CloudWatch Logs Insights** over `/aws/claude-gateway/events`. Logs Insights is billed per GB scanned, which is orders of magnitude cheaper for ad-hoc queries.

```
CloudWatch Metrics  → "what is team A spending per day?"  (dashboard, alarms)
Logs Insights       → "which user spiked spend on Tuesday?"  (ad-hoc)
```

Enable log forwarding with `FORWARD_LOGS=true`. It's off by default; metrics-only is the default.

---

## Gotchas we hit

**ALB idle timeout truncates long "thinking" turns.** This one is sneaky because the network is fine. Claude Code holds a single streaming connection open for the whole turn — and during extended thinking, *no bytes cross the ALB*. An Application Load Balancer closes any connection idle longer than `idle_timeout.timeout_seconds`, which **defaults to 60 seconds**. So a turn that thinks for longer than a minute before streaming its answer dies with `API Error: Connection closed mid-response` — while every ping, curl, and TLS handshake you throw at it looks perfectly healthy. The fix is a one-line load-balancer attribute; we set it to the ALB maximum (4000s):

```yaml
LoadBalancerAttributes:
  - Key: idle_timeout.timeout_seconds
    Value: "4000"   # AWS default is 60 — far too short for long plan/think turns
```

Configurable via the `AlbIdleTimeoutSeconds` stack parameter. If you see mid-response drops that correlate with long thinking pauses (not with payload size or flaky Wi-Fi), this is almost always the cause.

**VPN tunnel MTU.** If `/login` hangs silently, suspect the VPN MTU. At 1500, TLS handshake packets get fragmented and dropped. Fix: `sudo ifconfig utunN mtu 1300`. It resets on every VPN reconnect — put it in a connect script. (The bundled peer `.ovpn` now bakes in `tun-mtu 1300` / `mssfix 1260` so this survives reconnects.)

**Stale client state on hostname change.** When switching from a self-signed cert to the managed ACM cert (hostname change), both `~/.claude/remote-settings.json` and the macOS keychain entry `Claude Code-credentials` pin the old host. Delete both or `claude /logout` before reconnecting.

**ACM validation hangs for ~90 minutes** if `PUBLIC_HOSTED_ZONE_ID` is a private zone, or if `DOMAIN_NAME` isn't under the zone you specified. `deploy.sh` now preflights both and fails immediately — but if you hit this on an older version, delete the stuck ACM cert and redeploy.

**RDS-generated passwords in Postgres DSNs.** RDS can generate passwords containing `#`, `%`, `&`, and other URL-structural characters. The `entrypoint.sh` assembles the `postgres://` DSN at runtime and percent-encodes the password in pure bash — no Python, no Perl in the image.

---

## What it costs

No gateway license. You pay for the AWS infrastructure plus normal Bedrock per-token pricing — the same as if you were calling Bedrock directly.

| Resource | Rough cost |
|---|---|
| 2× ECS Fargate tasks (HA across AZs) | ~$9/mo |
| RDS PostgreSQL `db.t4g.micro` | ~$12/mo |
| Internal ALB | ~$16/mo |
| Regional NAT gateway | data-dependent |
| **Bedrock inference** | **per-token, same as always** |

Roughly **$40/month** of fixed infrastructure for a team of any size. Scale ECS to 0 or tear down the stack when you don't need it.

---

## Try it

The stack is MIT-licensed, self-contained, and deploys into your own account — no SaaS dependency, no license server, no phoning home.

Source is at the link above. If you try it and hit something that isn't in the gotchas list, open an issue — the troubleshooting guide in `docs/GUIDE.md` grows with every team that runs it.

---

