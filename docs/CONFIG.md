# The gateway config file, section by section

The gateway is a single Linux binary driven by **one YAML file**. In this repo the
file is [`gateway/gateway.yaml.example`](../gateway/gateway.yaml.example) — a
template with `__PLACEHOLDER__` tokens that `deploy.sh` fills in at deploy time and
passes to the ECS task definition (the config lives in the task-def, not SSM — so a
config change forces a new task-def revision and ECS cycles the tasks).

Every deployment needs **five sections**. This page explains what each is and *why
it's set the way it is on AWS*. For the deploy walkthrough, see
[`GUIDE.md`](GUIDE.md); for the authoritative config reference, see the
[official docs](https://code.claude.com/docs/en/claude-apps-gateway-config).

```yaml
listen:      # where the gateway listens + how it sees the real client IP
oidc:        # your SSO connection (the "identity" capability)
session:     # bearer-token lifetime (also bounds offboarding latency)
store:       # PostgreSQL connection (sign-in / rate-limit / spend state)
upstreams:   # where inference goes — Amazon Bedrock (the "routing" capability)
```

---

## 1. `listen` — where the gateway listens

```yaml
listen:
  host: 0.0.0.0
  port: 8080
  public_url: https://claude-gateway.internal.example.com
  trusted_proxies:
    - 10.20.0.0/16          # the gateway VPC CIDR
```

The container binds `0.0.0.0:8080` behind a **TLS-terminating internal ALB**. Two
AWS-specific points:

- **`public_url` must be the private hostname the ALB answers on.** The gateway
  uses it to build the OIDC `redirect_uri`, the OAuth discovery document, and (when
  telemetry is on) the OTLP endpoint it pushes to clients. It must resolve to a
  **private IP** — Claude Code's `/login` refuses any gateway on a public IP,
  because a trusted gateway can push settings that run commands on developer
  machines, so it may only be reachable on your internal network. This is why the
  ALB is `Scheme: internal` + `IpAddressType: ipv4` and must stay that way.
- **`trusted_proxies` is the VPC CIDR**, so the gateway trusts `X-Forwarded-For`
  only from the ALB. Without it, per-user rate limits and audit records would show
  the ALB's IP instead of the real client.

## 2. `oidc` — your SSO connection (Identity)

```yaml
oidc:
  issuer: https://cognito-idp.<region>.amazonaws.com/<poolId>
  client_id: <confidential web client id>
  client_secret: ${OIDC_CLIENT_SECRET}   # from Secrets Manager, expanded at boot
  allowed_email_domains: [example.com]
  userinfo_fallback: true
  groups_claim: cognito:groups
  scopes: [openid, email, profile]
```

This is the whole **identity** story: developers authenticate against *your* IdP,
and the gateway never sees an AWS credential from them. Register **one OAuth
application** in your IdP with redirect URI `https://<gateway-hostname>/oauth/callback`
and supply the issuer, client id, and client secret.

- **Any OIDC provider works** — Cognito, Okta, Microsoft Entra ID, Google
  Workspace, Keycloak, etc. Not supported: SAML-only providers, or AWS IAM Identity
  Center for custom apps. The three IdP paths (reuse a Cognito pool, create a new
  one, or bring your own) are in [`idp/README.md`](../idp/README.md).
- **`groups_claim` is IdP-specific** and is what the policy layer keys on: Cognito
  emits `cognito:groups`, Okta/custom typically `groups`, Entra may use `roles`.
- **`userinfo_fallback: true`** covers IdPs (like Cognito) whose `id_token` may omit
  `email`/`groups` — the gateway then fetches them from the userinfo endpoint.
- **The client secret is a `${VAR}`**, never a literal. ECS injects it from Secrets
  Manager and the gateway expands it at boot, so the rendered YAML stays non-secret.

## 3. `session` — bearer-token lifetime

```yaml
session:
  jwt_secret: ${GATEWAY_JWT_SECRET}   # openssl rand -base64 32
  ttl_hours: 8
```

After sign-in the gateway mints a short-lived **JWT bearer token**; Claude Code
sends it on every request. The token is validated *locally* against `jwt_secret`
(no database hit), which is why signed-in developers keep working even if Postgres
blips.

- **`ttl_hours` is also your offboarding SLA.** Remove someone from the IdP and
  their session dies within this many hours — no credential rotation needed. Lower
  = tighter deprovisioning but more frequent logins.
- This example uses **8 hours** because Cognito's app-client token endpoint rejects
  the `offline_access` scope, so there's no refresh token; a longer TTL avoids
  hourly re-login. IdPs that issue refresh tokens can use a shorter TTL.
- **Rotate `jwt_secret`** by supplying an array (old + new) so in-flight tokens stay
  valid during the roll.

## 4. `store` — PostgreSQL state

```yaml
store:
  postgres_url: ${GATEWAY_POSTGRES_URL}   # includes ?sslmode=require
```

A small **Amazon RDS PostgreSQL** instance (a `db.t4g.micro` is plenty — the
gateway stores only a few KB of sign-in, rate-limit, and spend state). The core
stack builds it for you and assembles the DSN from an RDS-generated password.

- The password is **percent-encoded** into the `postgres://` DSN by
  `gateway/entrypoint.sh`, and the RDS password's `ExcludeCharacters` omits
  URL-structural characters — otherwise a stray `#`/`&`/`=` would corrupt the DSN.
- **If Postgres is down:** already-signed-in developers keep working (tokens
  validate locally); *new* sign-ins fail until it recovers. Spend enforcement fails
  **open** by default (inference continues) unless you set it to fail closed.

## 5. `upstreams` — where inference goes (Routing)

```yaml
upstreams:
  - provider: bedrock
    region: us-east-1
    auth: {}          # empty = AWS default credential chain (the ECS task role)
```

The gateway holds the upstream credential and routes inference **on the developer's
behalf**, translating between the Anthropic Messages API (what Claude Code speaks)
and Bedrock.

- **`auth: {}` means "use the ECS task role."** The task role is granted
  `bedrock:InvokeModel*` on `inference-profile/*` and `foundation-model/anthropic.*`
  — see [`infrastructure/claude-apps-gateway.yaml`](../infrastructure/claude-apps-gateway.yaml).
  On EKS you'd use IRSA; on EC2, the instance profile. No key is stored.
- **Multi-region / multi-account failover** is supported by listing more than one
  upstream: the gateway tries them in order and fails over on `5xx`/`429`/timeout
  (never on `4xx`). Each upstream can carry its own credentials for cross-account.
- **Cross-region inference profiles** (`us.anthropic.*`, `global.anthropic.*`)
  require model access enabled in each region the profile spans. List what your
  region actually serves with `aws bedrock list-inference-profiles --region <r>`.

---

## The model catalog (Policy, part 1)

Below `upstreams`, the `models:` block is the server-side **model allowlist** — the
gateway rejects any model id not listed with *"not in the operator's model
allowlist."* Two things to know:

- **`id:` must match the exact string the CLI sends.** Modern Claude Code (≥ 2.1.198)
  sends short aliases like `claude-opus-4-8` after the `/model` picker; older CLIs
  send the fully-qualified `global.anthropic.*` form. The shipped example lists
  **both** forms so either CLI works.
- **This catalog is region-opinionated.** It maps to `global.*` cross-region
  profiles (APAC-friendly). In us-east-1/us-west-2 you may prefer the
  `us.anthropic.*` profiles, or set `auto_include_builtin_models: true` and drop the
  explicit list.
- **The whole rendered config must stay under 4096 bytes** (the ECS task-def
  environment limit this repo renders into). The model list has the most room to
  grow; the current render is ~3.6 KB.

## Group-based policy (Policy, part 2)

The gateway can enforce **per-group model access and tool permissions**, delivered
to the CLI at sign-in. Policies are evaluated top-to-bottom, first match wins;
`match: {}` is the catch-all. Conceptually:

```yaml
managed:
  policies:
    - match: { groups: [contractors] }      # restrict contractors to Haiku, no web
      cli:
        availableModels: [claude-haiku-4-5]
        enforceAvailableModels: true
        permissions: { deny: ["WebFetch", "WebSearch"] }
    - match: {}                               # everyone else: full access
      cli:
        availableModels: [claude-opus-4-8, claude-sonnet-4-6, claude-haiku-4-5]
```

`availableModels` is enforced both client-side (the picker) and server-side (a 400
on an unauthorized model). Settings refresh about hourly, so policy changes reach
developers within an hour of redeploy. This example repo focuses on the allowlist;
group policies are an enhancement you layer on per the official config reference.

## Telemetry (optional)

```yaml
telemetry:
  forward_to:
    - url: https://otel-collector.internal.example.com   # MUST be https
      headers: { Authorization: "Bearer ${OTLP_TOKEN}" }
      metrics: true      # token counts, latency, model, user identity
      logs: false        # bash commands, file paths — opt-in, sensitive
      traces: false      # full tool inputs — opt-in, most sensitive
```

The gateway relays OTLP metrics stamped with each developer's identity to **any
collector you run** — so you get per-user cost/usage attribution with zero
developer-side config. Key points for AWS:

- **The endpoint must be `https://`.** The gateway has an SSRF guard that rejects
  `http://`. If your collector uses a private/corporate CA, bake that CA into the
  image (`gateway/extra-ca/`) rather than downgrading to http. This repo ships an
  optional self-hosted ADOT collector → CloudWatch — see
  [`observability/README.md`](../observability/README.md).
- **`metrics` is the safe default; `logs`/`traces` are opt-in** because they carry
  commands and file paths. The gateway itself never logs prompt/completion content.
- Setting `forward_to` automatically pushes the OTEL env vars to connected clients.

## Spend caps (optional)

Daily/weekly/monthly USD budgets per user, group, or org. Over-cap requests get a
`429` until the period resets. Enable the admin API in the config, then set caps
via that API (not in YAML):

```yaml
admin:
  write_keys: [ { id: terraform, key: "${GATEWAY_ADMIN_WRITE_KEY}" } ]
  blocked_message: "Contact your platform team to request a higher limit."
```

```bash
# $500/developer/month org-wide default (amounts are USD cents):
curl -X POST https://<gateway>/v1/organizations/spend_limits \
  -H "x-api-key: $GATEWAY_ADMIN_WRITE_KEY" -H "Content-Type: application/json" \
  -d '{"scope":{"type":"organization"},"amount":"50000","period":"monthly"}'
```

Caps are **per-seat defaults**, not shared pools. Spend is *estimated* from token
counts at list price — a circuit breaker, not an invoice. If Postgres is down,
enforcement fails open unless you set `enforcement.fail_closed_on_error: true`.
