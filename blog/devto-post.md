---
title: "Run Claude Code for Your Whole Team - Zero API Keys on Developer Laptops"
published: false
tags: ai, aws, devops, claudeai
---

Here's a thing that happens at almost every company that starts using AI coding tools: one developer gets an Anthropic API key, tells two colleagues, and within a week half the team has their own keys stored in `.env` files, shell profiles, and CI jobs. Someone leaves. Their key is still active somewhere. You have no idea what it's calling or how much it's spending.

There's a better model. This post walks through an open-source AWS setup that lets your whole engineering team use Claude Code without a single API key or AWS credential ever touching a developer laptop. We'll cover the architectural tricks that make that work without the usual enterprise friction — and, further down, a feature that goes one step past visibility: a hard, enforced dollar limit on any one person's spend, so "no idea how much it's spending" stops being possible in the first place.

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

The repo ships six `.env` profiles covering the common starting points — pick the row that matches what you already have, not the one that sounds most complete:

| You have… | Profile |
|---|---|
| Nothing yet (greenfield: new Cognito pool, bundled telemetry, bundled VPN) | `managed-newcognito-collector-vpn.env` |
| An existing Cognito pool, and your own telemetry collector | `managed-existingcognito-byotelemetry.env` |
| Okta / Entra / any other OIDC IdP, no telemetry yet | `byo-oidc-notelemetry.env` |
| Okta / Entra / any other OIDC IdP, plus your own telemetry collector | `byo-oidc-byotelemetry.env` |
| Just want to try it cheaply (new Cognito, no telemetry) | `managed-newcognito-notelemetry.env` |
| No public domain yet | `selfsigned-fallback.env` |

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

Group-based access control is two env vars away — there's no separate policy engine to stand up and no new console to learn:

```bash
export DENY_TOOL_GROUP=contractor
export DENY_TOOLS=WebFetch
```

`deploy.sh` renders these into a `managed.policies` block in the gateway config: a first-match, top-to-bottom policy list, with a catch-all clause that leaves everyone else unrestricted. The rendered result looks like this:

```yaml
managed:
  policies:
    - match: { groups: [contractor] }
      cli:
        permissions: { deny: ["WebFetch"] }
    - match: {}      # everyone else: unrestricted
```

The same block can restrict which *models* a group is even offered — point contractors at Haiku while engineering keeps Opus and Sonnet — via `cli.availableModels` on a policy, and the repo wires that to a `ENFORCE_MODELS` deploy-time env var (rendered onto the `match: {}` catch-all so it applies org-wide) exactly the way the tool deny-list is. One catch that cost us real debugging time is in the Gotchas below: `availableModels` alone doesn't actually *stop* anyone until you pair it with `enforceAvailableModels: true`.

One propagation quirk worth remembering: policy edits need a gateway redeploy (they live in the task definition, so a change ships as a new task-def revision that ECS cycles in). A user picking up a *new* group membership needs to `/logout` and `/login` again — this Cognito client issues no refresh token, so the `groups` claim is only minted at sign-in.

---

## Observability: metrics vs. Logs Insights

The bundled ADOT collector exports OTLP events to CloudWatch. Only `user.email` and `user.groups` are promoted to CloudWatch EMF metric **dimensions** on `token.usage` and `cost.usage` events. Every distinct dimension value creates a new custom metric, and CloudWatch charges per metric. So: keep dimensions low-cardinality.

High-cardinality slicing — per-user spend breakdowns, per-role analysis — is done in **CloudWatch Logs Insights** over `/aws/claude-gateway/events`. Logs Insights is billed per GB scanned, which is orders of magnitude cheaper for ad-hoc queries.

```
CloudWatch Metrics  → "what is team A spending per day?"  (dashboard, alarms)
Logs Insights       → "which user spiked spend on Tuesday?"  (ad-hoc)
```

Enable log forwarding with `FORWARD_LOGS=true`. It's off by default; metrics-only is the default.

The bundled CloudWatch dashboard puts that Logs Insights query to work directly: one bar chart each for cost by user, by team, by model, and by agent, totalled over whatever time window you're looking at. That replaced an earlier version built on fixed one-day metric widgets, which had a habit of clumping everyone's spend into a single indistinguishable bar — useful for noticing *that* spend happened, useless for figuring out *whose*. There's also an optional per-user daily-cost alarm (set `PerUserAlarmEmailAddress` on the observability stack) that fires its own SNS topic. It's notify-only today, but it's a clean hook if you later want to wire an automated response to it.

---

## From visibility to a hard stop: spend caps

A dashboard and an alarm are good for noticing a problem. Neither one stops it from happening while you're asleep — that's the gap spend caps are built to close.

Telemetry, described above, *tracks* spend and *notifies* you once it crosses a threshold you set. Spend caps go a step further and *enforce* a budget on every single request. Set a daily, weekly, or monthly USD limit — per user, per IdP group, or for the whole org — and the moment someone crosses it, their next `/v1/messages` call comes back with a `429 billing_error` instead of running. Nobody has to notice and go revoke a credential; the gateway does it inline.

Turning it on is, again, a small handful of env vars:

```bash
export ENABLE_SPEND_CAPS=true
export GATEWAY_ADMIN_WRITE_KEY_ARN=arn:aws:secretsmanager:us-east-1:123456789012:secret:admin-write-key
export SPEND_CAP_FAIL_CLOSED=false   # true = block all inference if Postgres is briefly unreachable
export ADMIN_GROUPS=platform-finops  # optional: let this IdP group manage caps with their own JWT
./deploy.sh
```

The caps themselves aren't part of the YAML config — they're set at runtime through the gateway's admin API, so a finance or platform team can adjust a budget without waiting on a redeploy:

```bash
curl -X POST https://<gateway>/v1/organizations/spend_limits \
  -H "x-api-key: $GATEWAY_ADMIN_WRITE_KEY" -H "Content-Type: application/json" \
  -d '{"scope":{"type":"rbac_group","rbac_group_id":"contractors"},"amount":"10000","period":"daily"}'
```

Two things worth knowing before you flip this on. First, the amount here is estimated from token counts at list price, not drawn from an actual invoice — treat it as a circuit breaker, and reconcile against Bedrock billing or your Cost and Usage Report for the real number. Second, enforcement **fails open** by default: if Postgres is briefly unreachable, inference keeps running for everyone rather than grinding to a halt. Set `SPEND_CAP_FAIL_CLOSED=true` if a hard budget guarantee matters more to you than uptime — that's a genuine tradeoff, not a default we'd pick for you. (Enabling caps also adds a few small tables to Postgres; it doesn't change the cost math below, but it's a reason to think about RDS Multi-AZ if you're relying on this for production budget enforcement.)

Turn on both features and you get the complete picture: the dashboard tells you *who* is spending, and the caps make sure no one of them spends more than you decided they should.

---

## Gotchas we hit

**ALB idle timeout truncates long "thinking" turns.** This one is sneaky because the network is fine. Claude Code holds a single streaming connection open for the whole turn — and during extended thinking, *no bytes cross the ALB*. An Application Load Balancer closes any connection idle longer than `idle_timeout.timeout_seconds`, which **defaults to 60 seconds**. So a turn that thinks for longer than a minute before streaming its answer dies with `API Error: Connection closed mid-response` — while every ping, curl, and TLS handshake you throw at it looks perfectly healthy. The fix is a one-line load-balancer attribute; we set it to the ALB maximum (4000s):

```yaml
LoadBalancerAttributes:
  - Key: idle_timeout.timeout_seconds
    Value: "4000"   # AWS default is 60 — far too short for long plan/think turns
```

Configurable via the `AlbIdleTimeoutSeconds` stack parameter. If you see mid-response drops that correlate with long thinking pauses (not with payload size or flaky Wi-Fi), this is almost always the cause.

**A local `settings.json` quietly overrides your model allowlist.** A tester couldn't select a newly-added model after logging in through the gateway, even though it was right there in the server's `models:` catalog and a teammate could pick it fine. The catalog isn't the enforcement point: it only rejects model ids the gateway has *never heard of*. Any model that IS in the catalog can still be pinned by a developer's local `~/.claude/settings.json`, and that local pin wins the `/model` picker — so "it's in the allowlist" and "everyone can actually use it" are two different facts. The real difference between the two testers turned out to be a stale local `model` setting, not the gateway at all. If you want the gateway to be *authoritative* over models — so an off-list pick is refused with a 400 no matter what's in local settings — the policy needs `enforceAvailableModels: true` on its `availableModels` list, not just the catalog entry. It bounds the allowed set; it doesn't force a default. And like every policy change, it only takes effect after a redeploy *and* each user re-logs in (no refresh token on this Cognito client).

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

