# Observability — optional self-hosted OTEL collector + CloudWatch

An **optional** module for orgs that have **no third-party observability platform**
(Datadog, Splunk, etc.) and want Claude Apps Gateway usage metrics in **CloudWatch**.
It provisions an ECS Fargate [AWS Distro for OpenTelemetry](https://aws-otel.github.io/)
(ADOT) collector behind an **internal HTTPS ALB**, and ships CloudWatch dashboards +
alarms.

**Toggle:** deploy this stack to turn gateway telemetry on; don't deploy it and the
gateway runs fine with no telemetry. There is no hard dependency either way.

### Metrics path — `EnableCodingAgentInsights` (default `true`)

**Native / Coding Agent Insights (default).** The collector exports metrics to the
**native CloudWatch OTLP metrics endpoint** (`https://monitoring.<region>.amazonaws.com/v1/metrics`,
`otlphttp` + `sigv4auth`). This is a **different CloudWatch data plane** from EMF: the
metrics are PromQL-queryable and — crucially — auto-populate the **managed
[Coding Agent Insights](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/coding-agents-claude-code-gateway.html)
dashboard** (console → GenAI Observability → Coding Agent Insights → Claude Code tab),
which owns usage/cost/token/adoption/productivity slicing across identity/org
attributes. This stack then ships a lean **`<stack>-governance`** dashboard for the
gateway-specific governance/audit views that feature does not provide, and creates the
cost/usage alarms as **PromQL alarms**.

```
gateway (ECS) ─OTLP/HTTPS─▶ collector ALB (443) ─▶ ADOT (4318) ─┬─otlphttp/cwmetrics─▶ native CloudWatch OTLP metrics ─▶ Coding Agent Insights (managed, PromQL)
                                                                │                                                   └─ PromQL alarms ─▶ SNS
                                                                └─awscloudwatchlogs──▶ CloudWatch Logs (/aws/claude-gateway/events)
                                                                                       └─ <stack>-governance dashboard (Logs Insights)
```

**Legacy EMF (`EnableCodingAgentInsights=false`).** Falls back to the `awsemf`
exporter → EMF custom metrics in namespace `ClaudeGateway`, driving the full
`<stack>-usage` dashboard + classic metric alarms. Use this only if Coding Agent
Insights isn't available in your region, or you specifically need the EMF namespace.

```
gateway (ECS) ─OTLP/HTTPS─▶ collector ALB (443) ─▶ ADOT (4318) ─┬─awsemf───────────▶ CloudWatch metrics (ns: ClaudeGateway) ─▶ <stack>-usage dashboard + classic alarms
                                                                └─awscloudwatchlogs▶ CloudWatch Logs (/aws/claude-gateway/events)
```

Metrics are always forwarded when telemetry is on. **Audit events** (governance
logs — tool decisions, auth, api_request/error) are **opt-in**: set
`FORWARD_LOGS=true` on the gateway deploy so its telemetry block requests
`logs: true`. The logs pipeline sits idle and harmless until then. The events
pipeline is **identical in both metrics modes**.

## Why HTTPS is mandatory here

The gateway refuses to forward telemetry to a plaintext `http://` endpoint
(`forward_to.url must be https://` — part of its SSRF hardening). So the collector
**must** present HTTPS. Two ways to give it a cert the **gateway trusts**:

The gateway verifies telemetry TLS against its **container trust store** and has
**no per-destination CA or `insecure` option** (unlike the laptop→gateway leg,
which has fingerprint pinning). So the collector's cert must chain to a CA the
gateway image trusts:

| Option | Collector cert | Gateway trusts it via |
|--------|----------------|-----------------------|
| **Public / BYO ACM** (simplest if you own a domain) | Public ACM cert (DNS-validated) on a domain you control | Amazon public CA already in the image — no rebuild |
| **Self-signed** (no domain needed) | `make-collector-cert.sh` → self-signed, imported to ACM | Bake its CA into the gateway image (below) |

## Files

| File | Purpose |
|------|---------|
| `collector.yaml` | ECS Fargate ADOT collector + internal HTTPS ALB (443→4318) + metrics export (native OTLP → Coding Agent Insights by default; `awsemf`→EMF in legacy mode) + governance/usage dashboard + alarms. Deploys into the gateway VPC. |
| `make-collector-cert.sh` | Self-signed cert helper: CA + server cert → ACM, emits `collector-ca.pem` to bake into the gateway image. |

## Deploy (managed public cert — recommended)

> **Prereq:** the gateway stack (`claude-gateway`) is already deployed. The
> collector stack lives **inside the gateway's VPC** and takes the gateway's
> `VpcId` / `PrivateSubnets` outputs as parameters. If you haven't deployed
> the gateway yet, see [`../docs/GUIDE.md`](../docs/GUIDE.md) first.

If you have a public Route53 zone, use a public ACM cert. The **stock gateway
image trusts it automatically — no `COLLECTOR_CA_PEM`, no CA baking, no image
rebuild.** The collector's public hostname aliases the internal ALB (private IPs);
the gateway resolves it via NAT egress and reaches it in-VPC.

```bash
export AWS_REGION=<your-region>          # AWS_PROFILE optional

aws cloudformation deploy --stack-name claude-gateway-collector \
  --template-file collector.yaml --region "$AWS_REGION" \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    VpcId=<gateway VpcId> \
    PrivateSubnet1=<gateway private subnet 1> \
    PrivateSubnet2=<gateway private subnet 2> \
    PublicHostedZoneId=<Zxxxxxxxx> \
    DomainName=claude-otel.example.com \
    VpcCidr=10.20.0.0/16
#   -> blocks ~2-8 min on ACM DNS validation; outputs CollectorEndpoint = https://claude-otel.example.com

# Then point the gateway at it and redeploy (no CA baking needed):
#   export COLLECTOR_ENDPOINT=https://claude-otel.example.com ; ../deploy.sh
```

## Deploy (self-signed path — no domain required)

The collector lives **in the gateway's VPC** and uses a name in the gateway's
**private hosted zone**, so the gateway must be deployed first (it creates the VPC
and zone). Order:

```bash
export AWS_REGION=<your-region>          # AWS_PROFILE optional
HOST=otel.internal.example.com           # within the gateway's private zone

# 1. Cert: self-signed -> ACM, emits collector-ca.pem
./make-collector-cert.sh "$HOST"         # prints CollectorCertificateArn

# 2. Bake the CA into the gateway image, then (re)deploy the gateway with it
( cd ../gateway && COLLECTOR_CA_PEM="$PWD/../observability/collector-pki/collector-ca.pem" \
    ./build-and-push.sh 2.1.196 )        # -> new image URI; deploy gateway with it

# 3. Deploy the collector INTO the gateway VPC (use the gateway stack outputs)
aws cloudformation deploy --stack-name claude-gateway-collector \
  --template-file collector.yaml --region "$AWS_REGION" \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    VpcId=<gateway VpcId> \
    PrivateSubnet1=<gateway private subnet 1> \
    PrivateSubnet2=<gateway private subnet 2> \
    PrivateHostedZoneId=<gateway private hosted zone id> \
    CollectorHostname="$HOST" \
    CertificateArn=<CollectorCertificateArn from step 1> \
    VpcCidr=10.20.0.0/16
#   -> outputs CollectorEndpoint = https://otel.internal.example.com

# 4. Point the gateway at it (deploy.sh COLLECTOR_ENDPOINT) and redeploy:
#    export COLLECTOR_ENDPOINT=https://otel.internal.example.com ; ./deploy.sh
```

Once developers run inference through the gateway, metrics flow to the native
CloudWatch OTLP endpoint and the managed **Coding Agent Insights** dashboard
auto-populates (console → GenAI Observability → Coding Agent Insights → Claude
Code tab). The stack's own `claude-gateway-collector-governance` dashboard covers
the gateway-specific governance signals. In legacy EMF mode
(`EnableCodingAgentInsights=false`) metrics land in the `ClaudeGateway` namespace
and the `claude-gateway-collector-usage` dashboard populates instead.

## What the gateway emits (OTEL reference)

Claude Code is the source of the telemetry; the **gateway relays it and re-stamps
every export with the signed-in user's identity** from the OIDC token (so you get
per-user/team attribution with zero developer-side config). Three signal types flow
over the one OTLP/HTTP endpoint: **metrics** (always, when telemetry is on),
**logs/events** (opt-in via `FORWARD_LOGS=true`), and **traces** (out of scope here).

### Identity & resource attributes (stamped on everything)

These ride on **every** metric and event, added by the gateway from the OIDC token —
this is what makes governance possible. In the native OTLP metrics path they are
forwarded **unchanged as OTel resource attributes** (Coding Agent Insights slices on
them; PromQL addresses them as `@resource.user.email`, `@resource.user.groups`, …).
In legacy EMF mode they become CloudWatch **dimensions** (via
`resource_to_telemetry_conversion`). In the events path they appear under
`attributes.*` in the log record.

| Attribute | Source | What it gives you |
|-----------|--------|-------------------|
| `user.email` | OIDC `email` claim | Human-readable per-user attribution; email domain = org boundary |
| `user.id` | OIDC `sub` claim | Stable, immutable per-user id (survives email changes) |
| `user.groups` | OIDC groups claim (`GROUPS_CLAIM`) | **Team / role** attribution — the key RBAC-governance signal |
| `organization.id` | IdP / org context | Org-level rollup |
| `model` | per request | Model attribution on cost/token metrics (e.g. `claude-opus-4-8`) |
| `session.id` | per CLI session | Session correlation |

> `user.groups` is a **list**. In the native OTLP path it stays an OTel list
> resource attribute — Coding Agent Insights and PromQL (`@resource.user.groups`)
> handle it directly. In legacy EMF mode awsemf stringifies the whole array into one
> dimension value (keys on the group-*set*, not per-group). Either way the events
> path can split it with `stats … by attributes.user.groups`.

### Metrics (native OTel names)

| Metric | Unit | Notable attributes | Governance / demo use |
|--------|------|--------------------|-----------------------|
| `claude_code.cost.usage` | USD | `user.email`, `user.groups`, `model` | Cost per user / team / model — spend governance |
| `claude_code.token.usage` | tokens | `type` (input/output/cacheRead/cacheCreation), `model`, `user.email`, `user.groups` | Token volume + cache economics |
| `claude_code.session.count` | count | — | Adoption; availability (no-session alarm) |
| `claude_code.active_time.total` | seconds | — | Engagement / active time |
| `claude_code.lines_of_code.count` | count | — | Productivity |
| `claude_code.commit.count` | count | — | Productivity |
| `claude_code.pull_request.count` | count | — | Productivity |
| `claude_code.code_edit_tool.decision` | count | `decision` (accept/reject) | **Governance** — edit-tool accept/reject rate + alarm |

In the native OTLP path these are forwarded verbatim (metric names keep their dots;
in PromQL: `{"claude_code.cost.usage"}`), and Coding Agent Insights slices them by
the identity/org resource attributes automatically. In legacy EMF mode, which
attributes are promoted to CloudWatch metric **dimensions** is controlled by
`metric_declarations` in `collector.yaml` — see the cardinality note below.

### Events / audit logs (`FORWARD_LOGS=true` → `/aws/claude-gateway/events`)

Opt-in structured events, keyed by `attributes.event_name`. These are the richest
governance signals — queried by the dashboard's Logs Insights widgets.

| `event_name` | Fires on | Key attributes (beyond identity) |
|--------------|----------|----------------------------------|
| `tool_decision` | Permission check on a tool | `tool_name`, `decision` (accept/reject/ask), `source` (config/hook/user_*) |
| `auth` | Login / logout / session lifecycle | `outcome`, `method` (gateway vs local) |
| `api_request` | Inference API call | `model`, `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_creation_tokens`, `cost_usd`, `duration_ms`, `request_id` |
| `api_error` | API error (4xx/5xx) | `model`, `request_id`, error type/message |
| `user_prompt` | User submits a prompt | `prompt_length`, `command_name` (prompt text only if the sensitive body flag is on — not enabled here) |

`tool_decision` is the highest-value governance event (who tried what, allowed or
denied). `api_request` carries the authoritative per-call cost/token breakdown —
the per-team-spend widget aggregates it and splits the `user.groups` array cleanly.

> **What `FORWARD_LOGS` does *not* forward.** It relays event metadata (decisions,
> tokens, cost, identity, tool names). It does **not** enable the gateway's most
> sensitive prompt/response *body* capture. Keep it that way unless you have a reason
> and the retention/compliance story to match — see **Audit events & governance** below.

## Metrics & dashboards

**Native mode (default) — two dashboards, clear division of labour.**

1. **Coding Agent Insights (managed, AWS-owned).** Console → **GenAI Observability →
   Coding Agent Insights → Claude Code tab** (region `ap-southeast-2`). Auto-populates
   from the native OTLP metrics — you don't create or import it. Owns
   **usage / cost / token / adoption / productivity / per-turn-latency** slicing across
   the identity & org resource attributes (user, team/`user.groups`, org, model) with
   CSV export. This replaces the hand-built cost/token/adoption metric widgets we used
   to maintain.
2. **`<stack>-governance` (this stack).** A lean companion for the gateway-specific
   **governance/audit** signals Coding Agent Insights does not cover. All widgets are
   **Logs Insights** / gateway-log queries (they don't depend on the metrics data
   plane). Widgets:
   - Header text with a **deep-link** to Coding Agent Insights.
   - **Top users by tool rejections** and **blocked/asked actions by tool**
     (`/aws/claude-gateway/events`, `tool_decision`).
   - **Tool-decision enforcement source** (config vs hook vs user) — showcases the RBAC
     governance story.
   - **Authentication events** (gateway log `evt`) and **API errors**
     (`gateway.api_errors` metric + recent-errors table).
   - **Per-team spend** from `api_request` audit events, split by `user.groups`.

**Legacy EMF mode (`EnableCodingAgentInsights=false`) — the `<stack>-usage` dashboard.**
The original single dashboard, driven by EMF metrics in the `ClaudeGateway` namespace.
It relies on the gateway-stamped resource attributes that `awsemf`
`resource_to_telemetry_conversion` turns into CloudWatch dimensions. Sections: cost &
tokens (by user/team/model), adoption & productivity, tool decisions, and the same
Logs Insights governance widgets.

**Cardinality note (legacy EMF only).** In EMF mode `user.email` / `user.groups` are
promoted to metric dimensions only for `token.usage` / `cost.usage` — each distinct
value mints a custom metric. For high-cardinality, ad-hoc per-user / per-role forensics
prefer the **Logs Insights** widgets over `/aws/claude-gateway/events` rather than
adding more `metric_declarations` dimension sets. In native mode this trade-off goes
away: Coding Agent Insights slices identity/org attributes without minting per-value
custom metrics, and PromQL queries `sum by (@resource.user.email) (…)` on demand.

### Viewing Coding Agent Insights

1. Open the CloudWatch console in the collector's region (`ap-southeast-2`) →
   **GenAI Observability** (left nav) → **Coding Agent Insights** → **Claude Code** tab.
   The `CodingAgentInsightsConsoleUrl` stack output is a direct deep-link, and the
   `<stack>-governance` dashboard header repeats it.
2. It auto-populates a few minutes after metrics start flowing — there is nothing to
   create or import. If it's empty, confirm metrics are actually reaching the native
   endpoint: **Metrics → Query with PromQL** (Query Studio) and run
   `{"claude_code.cost.usage"}` or `sum by (@resource.user.email) ({"claude_code.token.usage"})`.
   Series there but an empty managed dashboard usually means the metric/attribute
   shape differs from what the feature expects (check a CLI/gateway version bump).
3. Slice by user / team (`user.groups`) / model / org, adjust the time range, and use
   **Export CSV** for reporting. Governance forensics (who was denied what, auth,
   upstream errors, per-team audit spend) live on the `<stack>-governance` dashboard,
   not here.

> **Region + availability.** Coding Agent Insights is in all commercial regions
> except ME (UAE), ME (Bahrain), and Israel (Tel Aviv). If your region isn't
> supported, deploy with `EnableCodingAgentInsights=false` for the legacy EMF
> `<stack>-usage` dashboard instead.

## Audit events & governance (`FORWARD_LOGS=true`)

When the gateway forwards logs, the structured events catalogued under **Events /
audit logs** in the OTEL reference above land in the **`/aws/claude-gateway/events`**
log group via the `awscloudwatchlogs` exporter. The dashboard's Logs Insights
widgets query them from there.

> **Event envelope (verified against CLI 2.1.203/204).** The exporter writes one
> JSON object per event with a top-level `body` and an `attributes.*` map. The
> event type lives in **`body`** as `claude_code.<name>` (e.g.
> `body = 'claude_code.tool_decision'`) — there is **no** `attributes.event_name`
> field. The catalogued name is also in `attributes.event.name`, but that key has
> a literal dot in it, so the widgets filter on `body` instead (and the
> `ApiErrorMetricFilter` uses `{ $.body = "claude_code.api_error" }`). Other event
> fields are plain dotted paths: `attributes.decision`, `attributes.tool_name`,
> `attributes.cost_usd`, `attributes.user.email`, `attributes.user.groups` — no
> backticks needed. If a future CLI/ADOT version changes this envelope, run one
> widget query via `aws logs start-query` and re-check these paths.

> **Auth events live in the gateway log, not the events pipeline.** `FORWARD_LOGS`
> forwards the **CLI's** OTLP telemetry (`claude_code.*`) — tool decisions,
> api_request, prompts, hooks. It carries **no** login/auth event. Gateway-side
> authentication (the OIDC device flow) is server-side and lands in the gateway's
> own container log **`/ecs/claude-gateway-gateway`** as structured JSON keyed by
> `evt`: `device.authorize`, `device.verify`, `session.mint`, `session.refresh`,
> and **`auth.denied`** (plus `spend.blocked`, `inference`, `managed.serve`).
> The dashboard's "Authentication events" widget therefore sources that log group
> directly (schema: `evt`, `result`, `email`, `client_ip`, `request_id`), not
> `/aws/claude-gateway/events`.
>
> **API errors are also gateway-side.** The CLI events pipeline never emits an
> `api_error` either — upstream (Bedrock) failures show up in
> `/ecs/claude-gateway-gateway` as `{evt:"inference", status:<http>}` with a 4xx/5xx
> `status`. The "API errors (recent)" widget queries that log for `status >= 400`,
> and `ApiErrorMetricFilter` derives the `gateway.api_errors` metric (which drives
> the `<stack>-api-errors` alarm) from the same pattern — so neither depends on
> `FORWARD_LOGS` at all.

> **Sensitivity.** Logs can carry commands, file paths, and prompts. `FORWARD_LOGS`
> forwards event metadata (decisions, tokens, cost, identity); it does **not**
> enable the gateway's most sensitive prompt/response body capture. Keep it that way
> unless you have a reason and the retention/compliance story to match.

## Alarms

The stack always creates an SNS topic (`<stack>-alarms`, output `AlarmTopicArn`)
and starter alarms that publish to it. In **native mode** the metric-based alarms
are **PromQL alarms** (`AWS::CloudWatch::Alarm` → `EvaluationCriteria.PromQLCriteria`);
the threshold is embedded in the query and the query reduces to a single series.
`EvaluationInterval` caps at 3600s, so daily windows re-evaluate hourly via
`sum_over_time(…[1d])`.

| Alarm | Fires when | PromQL query (native mode) |
|-------|------------|----------------------------|
| `<stack>-daily-cost` | total cost over 1 day > `DailyCostThresholdUsd` (default 500) | `sum(sum_over_time({"claude_code.cost.usage"}[1d])) > <thr>` |
| `<stack>-per-user-cost` | one user's daily cost > `PerUserDailyThresholdUsd` (opt-in) | `sum(sum_over_time({"claude_code.cost.usage", "@resource.user.email"="<addr>"}[1d])) > <thr>` |
| `<stack>-tool-rejections` | > 25 edit-tool rejections in an hour | `sum(sum_over_time({"claude_code.code_edit_tool.decision", "decision"="reject"}[1h])) > 25` |
| `<stack>-no-sessions` | no session metric for an hour | `absent_over_time({"claude_code.session.count"}[1h]) == 1` |
| `<stack>-api-errors` | > 10 `api_error` events in 5 min (needs `FORWARD_LOGS=true`) | *classic* — reads `gateway.api_errors` from the metric filter, unchanged |

Notes:
- The **no-sessions** alarm uses `absent_over_time(…) == 1`, not `< 1`: an absent
  series yields no contributor, so a `<` comparison could never fire.
- **`<stack>-cost-anomaly`** (ANOMALY_DETECTION_BAND) has no PromQL equivalent, so it
  exists **only in legacy EMF mode**.
- **`<stack>-api-errors`** is a classic alarm in *both* modes — it reads
  `gateway.api_errors`, derived by `ApiErrorMetricFilter` from the gateway container
  log, which is independent of the metrics data plane.
- In **legacy EMF mode** all of the above are the original classic metric-math alarms
  (same `AlarmName`s), so exactly one alarm per name exists in either mode.

Set **`AlarmEmail`** to subscribe an address (confirm the SNS email). Leave it
empty and the topic is created unsubscribed — wire it to Slack/PagerDuty yourself.
Set **`PerUserAlarmEmailAddress`** + **`PerUserDailyThresholdUsd`** to enable the
per-user cost alarm. Via `deploy-all.sh`, use `ALARM_EMAIL` / `DAILY_COST_THRESHOLD_USD`.

## Teardown

Delete `claude-gateway-collector` before the gateway stack (it references the
gateway's VPC/zone). Then set the gateway's `COLLECTOR_ENDPOINT` back to empty and
redeploy, or leave it — a missing collector just means telemetry POSTs fail
silently; the gateway keeps serving.

> **Generated PKI is secret.** `collector-pki/` is gitignored — never commit it.
