# Observability — optional self-hosted OTEL collector + CloudWatch

An **optional** module for orgs that have **no third-party observability platform**
(Datadog, Splunk, etc.) and want Claude Apps Gateway usage metrics in **CloudWatch**.
It provisions an ECS Fargate [AWS Distro for OpenTelemetry](https://aws-otel.github.io/)
(ADOT) collector behind an **internal HTTPS ALB**, exports metrics to CloudWatch via
the `awsemf` exporter, and ships a ready-made CloudWatch **dashboard**.

**Toggle:** deploy this stack to turn gateway telemetry on; don't deploy it and the
gateway runs fine with no telemetry. There is no hard dependency either way.

```
gateway (ECS) ──OTLP/HTTPS──▶ collector ALB (443) ──▶ ADOT (4318) ──┬─awsemf───────────▶ CloudWatch metrics (ns: ClaudeGateway)
                                                                    └─awscloudwatchlogs▶ CloudWatch Logs (/aws/claude-gateway/events)
                                                                                          ├─ dashboard (metrics + Logs Insights)
                                                                                          └─ alarms ─▶ SNS topic
```

Metrics are always forwarded when telemetry is on. **Audit events** (governance
logs — tool decisions, auth, api_request/error) are **opt-in**: set
`FORWARD_LOGS=true` on the gateway deploy so its telemetry block requests
`logs: true`. The logs pipeline sits idle and harmless until then.

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
| `collector.yaml` | ECS Fargate ADOT collector + internal HTTPS ALB (443→4318) + `awsemf`→CloudWatch + CloudWatch dashboard. Deploys into the gateway VPC. |
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

Once developers run inference through the gateway, metrics land in the
`ClaudeGateway` CloudWatch namespace and the `claude-gateway-collector-usage`
dashboard populates.

## Metrics & dashboard

The gateway stamps each OTLP export with the signed-in user's identity as resource
attributes (`user.email`, `user.id`, `user.groups`), so `awsemf`
`resource_to_telemetry_conversion` turns them into CloudWatch dimensions with no
header-extraction processors. The dashboard is sectioned:

- **Cost & tokens** — cost by user, cost by team/role (`user.groups`), token split
  by type (input/output/cache), tokens by model. Metric widgets use `SEARCH()`
  expressions so they auto-expand across whatever user/team/model values appear.
- **Adoption & productivity** — sessions, active time, lines of code, commits, PRs.
- **Governance — tool decisions** — edit-tool accept vs reject, plus API errors.
- **Governance — audit events (Logs Insights)** — top users by tool rejections,
  blocked/asked actions by tool, auth outcomes, recent API errors, per-team spend.

**Cardinality note (costs real money at scale).** `user.email` / `user.groups` are
promoted to metric dimensions only for `token.usage` / `cost.usage` — each distinct
value mints a custom metric. For high-cardinality, ad-hoc per-user / per-role
forensics prefer the **Logs Insights** widgets over `/aws/claude-gateway/events`
rather than adding more `metric_declarations` dimension sets.

**`user.groups` is an OIDC list.** `resource_to_telemetry_conversion` stringifies
the whole array, so the `[[user.groups]]` metric dimension keys on the entire
group-*set*, not one value per group. True per-team/per-role slicing is done by the
Logs Insights `stats … by attributes.user.groups` widgets, which split it cleanly.

## Audit events & governance (`FORWARD_LOGS=true`)

When the gateway forwards logs, structured events land in the
**`/aws/claude-gateway/events`** log group via the `awscloudwatchlogs` exporter:
`tool_decision` (accept/reject/ask), `auth`, `api_request`, `api_error`,
`user_prompt`. The dashboard's Logs Insights widgets query them by
`attributes.event_name`.

> **Field-path caveat.** The widget queries assume the exporter's JSON envelope
> exposes event fields under `attributes.*`. The exact nesting is ADOT-version
> dependent — after your first traffic, run one widget query via
> `aws logs start-query` and adjust the `attributes.` prefixes (and the
> `ApiErrorMetricFilter` pattern) if they differ. This is the single most likely
> thing to need a tweak.

> **Sensitivity.** Logs can carry commands, file paths, and prompts. `FORWARD_LOGS`
> forwards event metadata (decisions, tokens, cost, identity); it does **not**
> enable the gateway's most sensitive prompt/response body capture. Keep it that way
> unless you have a reason and the retention/compliance story to match.

## Alarms

The stack always creates an SNS topic (`<stack>-alarms`, output `AlarmTopicArn`)
and five starter alarms that publish to it:

| Alarm | Fires when |
|-------|------------|
| `<stack>-daily-cost` | total `cost.usage` over 1 day > `DailyCostThresholdUsd` (default 500) |
| `<stack>-cost-anomaly` | hourly cost leaves its `ANOMALY_DETECTION_BAND` |
| `<stack>-tool-rejections` | > 25 edit-tool rejections in an hour |
| `<stack>-api-errors` | > 10 `api_error` events in 5 min (needs `FORWARD_LOGS=true`) |
| `<stack>-no-sessions` | no sessions for 3 consecutive hours |

Set **`AlarmEmail`** to subscribe an address (confirm the SNS email). Leave it
empty and the topic is created unsubscribed — wire it to Slack/PagerDuty yourself.
Via `deploy-all.sh`, use `ALARM_EMAIL` / `DAILY_COST_THRESHOLD_USD`.

## Teardown

Delete `claude-gateway-collector` before the gateway stack (it references the
gateway's VPC/zone). Then set the gateway's `COLLECTOR_ENDPOINT` back to empty and
redeploy, or leave it — a missing collector just means telemetry POSTs fail
silently; the gateway keeps serving.

> **Generated PKI is secret.** `collector-pki/` is gitignored — never commit it.
