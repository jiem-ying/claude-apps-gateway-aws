# Governance demo runbook

Copy-paste commands for the live demo that backs `claude-gateway-governance.pptx`.
Three acts: **Quota** (configure → track → cap → 429 → recover), **RBAC** (deny a
tool), **Observability** (the dashboard). Runs against a **deployed** gateway — spend
caps require `ENABLE_SPEND_CAPS=true` at deploy time (see below).

> Amounts in the spend API are **USD cents**, whole-number strings. `null` = unlimited,
> `"0"` = block everything. Caps are estimated from token counts at list price — a
> circuit breaker, not an invoice.

---

## 0. One-time setup

### 0a. Create the admin write key and deploy with caps on

```bash
# The admin write key is the x-api-key for the spend-limits API. Store it in Secrets Manager.
aws secretsmanager create-secret \
  --name claude-gateway-admin-write \
  --secret-string "$(openssl rand -base64 32)"

# Grab the ARN and the raw value (you'll send the value as x-api-key):
export GATEWAY_ADMIN_WRITE_KEY_ARN=$(aws secretsmanager describe-secret \
  --secret-id claude-gateway-admin-write --query ARN --output text)
export ADMIN_KEY=$(aws secretsmanager get-secret-value \
  --secret-id claude-gateway-admin-write --query SecretString --output text)

# Deploy (or redeploy) the gateway with hard enforcement enabled:
export ENABLE_SPEND_CAPS=true
export SPEND_CAP_FAIL_CLOSED=false          # keep inference up if Postgres blips
export ADMIN_GROUPS="platform-finops"       # (optional) who can manage caps via their JWT
./deploy.sh                                  # or ./deploy-all.sh for the bundled profile
```

### 0b. Point the shell at the gateway

```bash
export GW="https://claude-gateway.internal.example.com"   # your gateway public_url

# Sanity: the admin API is live (empty list on a fresh deploy)
curl -sS "$GW/v1/organizations/spend_limits" -H "x-api-key: $ADMIN_KEY" | jq
```

---

## Act 1 — Quota: configure → track → cap → 429 → recover

### 1. Configure — set an org default, then a tight demo cap

```bash
# Org-wide default: $500 / developer / month
curl -sS -X POST "$GW/v1/organizations/spend_limits" \
  -H "x-api-key: $ADMIN_KEY" -H "Content-Type: application/json" \
  -d '{"scope":{"type":"organization"},"amount":"50000","period":"monthly"}' | jq

# The demo cap: $1 / DAY on a test group so we can trip it fast (amount = 100 cents)
curl -sS -X POST "$GW/v1/organizations/spend_limits" \
  -H "x-api-key: $ADMIN_KEY" -H "Content-Type: application/json" \
  -d '{"scope":{"type":"rbac_group","rbac_group_id":"demo-capped"},"amount":"100","period":"daily"}' | jq
```

> Put your demo user in the `demo-capped` IdP group (e.g. Cognito:
> `aws cognito-idp admin-add-user-to-group --group-name demo-capped --username <user> --user-pool-id <pool>`),
> then have that user `/logout` + `/login` so the new group lands in their token.

### 1b. Per-user example — protect yourself, cap a teammate

**Important: the spend API only *blocks* (429); it has no alert-only mode.** "Alert
only" for a person = they have **no hard cap** in the spend API, and the CloudWatch
cost alarms (Act 3) watch their spend instead. A **per-user override beats any group
or org cap**, so an explicit `null` (unlimited) guarantees that person is never locked
out — even under an org-wide default.

The API keys on the OIDC **`sub`**, not the username. Resolve each `sub` first (the
`q=` filter matches sub + last-seen email + display name):

```bash
# Find the sub for each person (they must have signed in at least once):
curl -sS "$GW/v1/organizations/spend_limits/effective?q=jiemying" -H "x-api-key: $ADMIN_KEY" \
  | jq '.data[] | {user_id, name: .actor.name, email: .actor.email_address}'
curl -sS "$GW/v1/organizations/spend_limits/effective?q=jpiao" -H "x-api-key: $ADMIN_KEY" \
  | jq '.data[] | {user_id, name: .actor.name, email: .actor.email_address}'

export JIEMYING_SUB="<sub-from-above>"
export JPIAO_SUB="<sub-from-above>"

# jiemying: ALERT-ONLY — explicit unlimited so no group/org cap can ever lock me out.
# amount:null = unlimited. My spend still shows in /effective and trips the cost alarms.
curl -sS -X POST "$GW/v1/organizations/spend_limits" \
  -H "x-api-key: $ADMIN_KEY" -H "Content-Type: application/json" \
  -d "{\"scope\":{\"type\":\"user\",\"user_id\":\"$JIEMYING_SUB\"},\"amount\":null,\"period\":\"monthly\"}" | jq

# jpiao: HARD CAP — $1888 / month (188800 cents). Over it -> 429 until the month resets.
curl -sS -X POST "$GW/v1/organizations/spend_limits" \
  -H "x-api-key: $ADMIN_KEY" -H "Content-Type: application/json" \
  -d "{\"scope\":{\"type\":\"user\",\"user_id\":\"$JPIAO_SUB\"},\"amount\":\"188800\",\"period\":\"monthly\"}" | jq

# Confirm both resolved the way you intend (jiemying: null/unlimited; jpiao: 188800):
curl -sS "$GW/v1/organizations/spend_limits/effective?period[]=monthly" -H "x-api-key: $ADMIN_KEY" \
  | jq '.data[] | {user: .actor.email_address, cap: .limit_amount, spent: .current_spend}'
```

> Why the explicit `null` and not "just leave jiemying out"? If an org or group default
> exists (e.g. the `$500/mo` org cap in step 1), *not* having a per-user row means you
> inherit that cap and could be blocked. The `null` override is what makes you truly
> alert-only. Pair it with a CloudWatch alarm on your `user.email` cost metric so you're
> still *notified* — you just never get *stopped*.

### 2. Track — watch spend climb toward the ceiling

```bash
# Resolved cap + period-to-date spend per principal (the slide-7 view).
# Top spenders first, daily window:
curl -sS "$GW/v1/organizations/spend_limits/effective?period[]=daily&sort=spend_desc" \
  -H "x-api-key: $ADMIN_KEY" | jq '.data[] | {user_id, spend: .current_spend, cap: .limit_amount}'
```

Now, as the demo user, run a couple of Claude Code turns to burn the $1:

```bash
claude -p "Explain this repo's deploy flow in detail, then draft a README section."
# re-run /effective above between turns to show the counter moving
```

### 3. Cap — hit the wall

Once the demo user crosses $1 for the day, their **next request** returns:

```
HTTP/1.1 429 Too Many Requests
x-should-retry: false
{"type":"error","error":{"type":"billing_error",
 "message":"spend limit reached Contact your platform team to request a higher limit."}}
```

In Claude Code the turn fails with the billing_error message (your
`SPEND_BLOCKED_MESSAGE` is appended verbatim). That's the circuit breaker.

### 4. Recover — raise the cap, no redeploy

```bash
# Raise the group's daily cap to $50 (5000 cents). POST replaces the cap for {scope, period}.
curl -sS -X POST "$GW/v1/organizations/spend_limits" \
  -H "x-api-key: $ADMIN_KEY" -H "Content-Type: application/json" \
  -d '{"scope":{"type":"rbac_group","rbac_group_id":"demo-capped"},"amount":"5000","period":"daily"}' | jq
```

The demo user's **very next request succeeds** — enforcement is live, no redeploy.

### 5. Show the audit trail (who changed the cap)

```bash
curl -sS "$GW/v1/organizations/spend_limits/audit?limit=5" -H "x-api-key: $ADMIN_KEY" | jq
```

### Cleanup (reset the demo)

```bash
# List, then delete the demo cap by its spl_ id:
curl -sS "$GW/v1/organizations/spend_limits" -H "x-api-key: $ADMIN_KEY" | jq '.data[] | {id, scope, amount, period}'
curl -sS -X DELETE "$GW/v1/organizations/spend_limits/<spl_id>" -H "x-api-key: $ADMIN_KEY" | jq
```

---

## Act 2 — RBAC: deny a tool to a group

Group RBAC renders from `DENY_TOOL_GROUP` / `DENY_TOOLS` in `deploy.sh` (or hand-edit
`managed.policies`). Deny the weather MCP tool to a `partners` group, everyone else
unrestricted:

```bash
export DENY_TOOL_GROUP=partners
export DENY_TOOLS="mcp__weather"     # whole server; or mcp__weather__get_weather for one tool
./deploy.sh                          # config lives in the task-def -> new revision -> ECS cycles
```

- A **partners** user: the weather tool is denied (and a denied *model* would 400 at
  the API — not just hidden in the `/model` picker).
- **Everyone else:** unchanged.
- **Propagation:** policy edits reach logged-in CLIs on the next managed-settings poll
  (~hourly) after redeploy; a **new group membership** needs the user to re-login.

Model allowlist per group is the same mechanism — set `availableModels` +
`enforceAvailableModels: true` in the policy (see `docs/CONFIG.md`).

---

## Act 3 — Observability: the governance dashboard

Deploy with the bundled collector + audit events forwarded:

```bash
export ENABLE_COLLECTOR=true        # ADOT -> CloudWatch
export FORWARD_LOGS=true            # forward audit events (tool_decision, auth, api_request/error)
export ALARM_EMAIL="you@example.com"          # (optional) subscribe to alarms
export DAILY_COST_THRESHOLD_USD=500           # daily cost alarm
# Per-user real-time alert (alert-only — never blocks). Pairs with jiemying's
# amount:null spend override from Act 1b: notified, never locked out.
export PER_USER_ALARM_EMAIL="jiemying@example.com"
export PER_USER_DAILY_THRESHOLD_USD=88        # notify-only; never caps
./deploy-all.sh
```

Then, in the console:

1. **CloudWatch → Dashboards → `ClaudeGateway-usage`** — top spenders by user and by
   team, token usage by model, edit-tool accept-vs-reject.
2. **Logs Insights → `/aws/claude-gateway/events`** — per-user tool rejections, auth
   failures, per-team spend. Example query:
   ```
   fields @timestamp, `user.email`, decision, tool_name
   | filter event_name = 'tool_decision' and decision = 'reject'
   | stats count() by `user.email`
   ```
3. **CloudWatch → Alarms** — daily-cost threshold, cost anomaly, tool-rejection burst,
   API errors → SNS (`AlarmTopic`) → email / Slack / PagerDuty.

### 3b. Per-user real-time alert (the "alert-only" governance path)

`PER_USER_ALARM_EMAIL` provisions a dedicated alarm + SNS topic for one developer's own
daily spend. This is the notify half — no `429`, no lockout — the exact complement to
`jiemying`'s `amount: null` spend override:

- **Alarm:** `<stack>-user-cost-<email>` on `claude_code.cost.usage` filtered to the
  `user.email` dimension, `Sum` over 1 day > threshold.
- **Topic:** `<stack>-user-cost` — the developer is subscribed by email, and it's a
  clean **hook point for downstream actionables**. Add subscriptions to trigger:
  - a **Lambda** that auto-raises (or tightens) their spend cap via the Admin API,
  - a **Slack** chatbot / **PagerDuty** / **HTTPS webhook** into your workflow engine,
  - a ticket in your ITSM.
  ```bash
  # Example: also fan the per-user alert out to a Lambda for auto-remediation
  aws sns subscribe --topic-arn <PerUserAlarmTopic-arn> \
    --protocol lambda --notification-endpoint <lambda-arn>
  ```
- **Why daily, not monthly:** CloudWatch alarm periods cap at 1 day, so this fires on a
  daily run-rate ($88/day here — notify-only, never a cap). The monthly *hard* number,
  when you want one, lives in the spend API — here we deliberately keep `jiemying` alert-only.

> The gateway never logs prompt or completion content. `metrics` carry counts;
> `logs` carry commands and file paths (that's why they're opt-in via `FORWARD_LOGS`).

---

## The 5-minute script (matches slide 13)

1. Set the `$1/day` group cap (Act 1 step 1).
2. Run two Claude Code turns; show `/effective` climbing (step 2).
3. Third turn → **429 billing_error** (step 3).
4. Raise the cap; next turn succeeds (step 4).
5. Show the `partners` tool-deny (Act 2) and the top-spenders dashboard (Act 3).
