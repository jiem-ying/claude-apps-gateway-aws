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
on an unauthorized model). `permissions` gate **tools**, model-agnostically — a rule
can name a built-in tool like `WebFetch`, or an MCP server: a bare `mcp__github`
removes that whole MCP server from the group's CLI (a scoped
`mcp__github__create_issue` denies just one tool). Settings refresh about hourly, so
policy changes reach developers within an hour of redeploy.

**This repo now wires a policy block** (it used to be doc-only). `deploy.sh` renders
`__MANAGED_BLOCK__` from two env vars:

```bash
DENY_TOOL_GROUP=contractor     # IdP group to restrict (empty = no policies)
DENY_TOOLS=WebFetch            # comma-separated tool rules to deny that group
```

which produces the canonical group-RBAC demo: the `contractor` group keeps **all
models** but loses the built-in `WebFetch` tool; everyone else (`match: {}`) is
unrestricted.

**Org-wide model allowlist (`ENFORCE_MODELS`).** To make a set of models
authoritative for **every** signed-in user — so a developer's local
`settings.json` model pin can't bypass it — set:

```bash
ENFORCE_MODELS="claude-opus-4-8,claude-sonnet-5,claude-haiku-4-5,claude-fable-5,global.anthropic.claude-fable-5"
```

`deploy.sh` renders this onto the `match: {}` catch-all as
`availableModels: [...]` with `enforceAvailableModels: true`, so the gateway
**rejects any off-list model server-side (400)** regardless of local settings.
It bounds the *allowed set* only — it does **not** force a default model. List the
exact ids CLIs send; include both the short alias and the `global.*` form for each
model so either CLI version resolves. `ENFORCE_MODELS` and `DENY_TOOL_GROUP`
compose (the group-deny rule renders first, the enforced catch-all last); either
empty is fine. Keep the whole rendered config **under 4096 bytes** (`deploy.sh`
fails the deploy if it isn't).

Peers wanting per-group model restrictions instead can hand-edit the block in
`gateway/gateway.yaml.example` per the official config reference.

> **The gateway cannot distribute MCP servers.** `mcpServers` inside a policy is
> rejected at boot — the gateway gates *access* to tools, but each developer installs
> any MCP server locally.

### What's a hotfix vs. what needs a redeploy / re-login

| Change | Hotfix (live)? | Re-auth? |
|--------|----------------|----------|
| Create a group / assign a user (`admin-add-user-to-group`) | yes, no redeploy | — |
| Edit `managed.policies` (config lives in the task-def) | **needs gateway redeploy** (new task-def revision → ECS cycles) | — |
| A user picking up new **group membership** | only on a fresh token | **user must `/logout` + `/login`** — this Cognito client has no refresh token, so the new `cognito:groups` claim is minted only at next login |
| Policy contents reaching an already-logged-in CLI | next managed-settings poll (~hourly) after redeploy | — |

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
- **`deploy.sh` renders this block from `COLLECTOR_ENDPOINT` + `FORWARD_LOGS`.**
  `FORWARD_LOGS=true` adds `logs: true` so governance events (`tool_decision`,
  `auth`, `api_request`, `api_error`) reach the collector — the bundled collector
  lands them in the `/aws/claude-gateway/events` log group and drives the
  dashboard's Logs Insights + governance alarms. `traces` stays off (out of scope).
  The rendered config must still fit the 4096-byte task-def budget (~3000 used;
  `logs: true` adds ~13 bytes).
- **Metrics data plane — `ENABLE_CODING_AGENT_INSIGHTS` (default `true`).** This is a
  **collector-side** toggle (a `deploy-all.sh` env var → the collector stack's
  `EnableCodingAgentInsights` param), not part of the gateway telemetry block above.
  When `true`, the bundled collector exports metrics to the **native CloudWatch OTLP
  endpoint** so the managed **GenAI Observability → Coding Agent Insights** dashboard
  auto-populates (usage/cost/token/adoption/productivity, PromQL-queryable), and the
  stack's own dashboard shrinks to a governance/audit companion (`<stack>-governance`)
  with **PromQL alarms**. Set `false` for the legacy `awsemf`/EMF path (namespace
  `ClaudeGateway`, `<stack>-usage` dashboard, classic metric alarms) — use only if
  Coding Agent Insights isn't available in your region. Either way the events/audit
  pipeline (`FORWARD_LOGS`) is identical. Full detail in
  [`observability/README.md`](../observability/README.md).

## Spend caps (optional — hard enforcement)

**Track vs. cap.** Telemetry (above) *tracks* cost per user/team and *alarms* when a
threshold is crossed — it observes and notifies, it does not block. Spend caps are the
*circuit breaker*: daily/weekly/monthly USD budgets per **user**, **group**, or **org**,
enforced on every `/v1/messages` request. An over-cap developer gets a **`429`
billing_error** (`x-should-retry: false`) on their next request until the period resets
or an admin raises the cap. `count_tokens` is exempt. Enable both for the full story:
the dashboard shows *who* is spending, the caps stop *runaway* spend on your shared
upstream credential.

### Enabling it (deployed path)

`deploy.sh` / `deploy-all.sh` render the `admin:` + `enforcement:` block from env vars.
The write key stays a `${GATEWAY_ADMIN_WRITE_KEY}` placeholder the gateway expands at
boot — it's injected by ECS from Secrets Manager, never written into the config.

```bash
# 1. Create the admin write key secret (the x-api-key for the caps API):
aws secretsmanager create-secret --name claude-gateway-admin-write \
  --secret-string "$(openssl rand -base64 32)"

# 2. Deploy with caps on:
export ENABLE_SPEND_CAPS="true"
export GATEWAY_ADMIN_WRITE_KEY_ARN="arn:aws:secretsmanager:...:secret:claude-gateway-admin-write-XXXXXX"
export SPEND_CAP_FAIL_CLOSED="false"       # true = no unmetered spend if Postgres is down
export ADMIN_GROUPS="platform-finops"      # optional: IdP group(s) that manage caps via JWT
./deploy.sh
```

This renders:

```yaml
admin:
  write_keys: [{id: ops, key: "${GATEWAY_ADMIN_WRITE_KEY}"}]
  blocked_message: "Contact your platform team to request a higher limit."
  admin_groups: [platform-finops]
enforcement:
  fail_closed_on_error: false
```

Off by default (`ENABLE_SPEND_CAPS` unset ⇒ empty block ⇒ byte-identical to a no-caps
deploy). `deploy.sh` fails fast if you set `ENABLE_SPEND_CAPS=true` without an ARN.

### Setting caps (after deploy, via the Admin API)

Caps are **not** in YAML — you set them through `POST /v1/organizations/spend_limits`
(amounts are **USD cents**, whole-number strings; `null` = unlimited, `"0"` = block all):

```bash
# $500/developer/month org-wide default:
curl -X POST https://<gateway>/v1/organizations/spend_limits \
  -H "x-api-key: $GATEWAY_ADMIN_WRITE_KEY" -H "Content-Type: application/json" \
  -d '{"scope":{"type":"organization"},"amount":"50000","period":"monthly"}'

# Tighter $100/day cap on the contractors group:
curl -X POST https://<gateway>/v1/organizations/spend_limits \
  -H "x-api-key: $GATEWAY_ADMIN_WRITE_KEY" -H "Content-Type: application/json" \
  -d '{"scope":{"type":"rbac_group","rbac_group_id":"contractors"},"amount":"10000","period":"daily"}'
```

- **Scopes:** `user` (by OIDC `sub`, as `scope.user_id`), `rbac_group` (IdP group name,
  as `scope.rbac_group_id`), or `organization`. **Periods:** `daily` / `weekly` / `monthly`
  (independent — over any one blocks).
- **Resolution order** per period: per-user override → most-restrictive group cap → org
  default → unlimited. Set `ADMIN_GROUPS`/`group_limit_mode` accordingly; a group/org cap
  is a **per-seat default**, not a shared pool.
- **Visibility:** `GET /v1/organizations/spend_limits/effective` shows each principal's
  resolved cap + period-to-date spend (great for the demo). `GET .../audit` is the
  mutation trail. Use `admin.read_keys` for GET-only automation.
- **Caveat:** spend is *estimated* from token counts at list price — a circuit breaker,
  not an invoice; reconcile against Bedrock/CUR for billing. Enforcement **fails open** by
  default if Postgres is unreachable (keeps inference up); `SPEND_CAP_FAIL_CLOSED=true`
  fails closed (no unmetered spend, at the cost of tying inference to the store).
- **Storage:** enabling caps adds durable `spend` / `spend_limits` / `admin_audit` /
  `principal_emails` tables to Postgres — set `MULTI_AZ_DB=true` and consider the RDS
  `DeletionPolicy` for production (see the note in `infrastructure/claude-apps-gateway.yaml`).

A full copy-paste demo (set a cap → trip the 429 → raise it) is in
[`slides/DEMO-RUNBOOK.md`](../slides/DEMO-RUNBOOK.md).

### What's a hotfix vs. what needs a redeploy

| Change | Live? | Redeploy? |
|--------|-------|-----------|
| Set / change / delete a cap via the Admin API | **yes, live** (next request enforces) | no |
| Turn caps on/off, change fail-open/closed, admin key/groups (`ENABLE_SPEND_CAPS`, …) | no | **yes** (task-def config) |
