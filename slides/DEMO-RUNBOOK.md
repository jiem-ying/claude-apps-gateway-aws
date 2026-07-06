# Governance demo — runbook

A copy-paste demo of the three governance pillars, backing
`claude-gateway-governance.pptx`:

1. **Quota** — set a budget, spend it, hit the `429`, raise it, recover.
2. **RBAC** — deny a tool to one team.
3. **Observability** — the cost dashboard and audit trail.

The **quota demo (Part 1) is the star** — it's ~5 minutes and needs nothing but a
terminal. Parts 2 and 3 are shorter follow-ons.

---

## This environment (already set up)

Everything below is live in this deployment — no setup needed to run the demo:

| Thing | Value |
|---|---|
| Gateway URL | `https://claude-gateway.jiemying.people.aws.dev` |
| Admin API | **enabled** (spend caps enforce; `429` on over-cap) |
| Demo user | `jiemying-target`  ·  password `<demo-password>` (shared out-of-band) |
| Demo user's group | `contractor` |
| Admin key secret | `claude-gateway-admin-write` (Secrets Manager, ap-southeast-2) |

> **Amounts are in US cents** (whole-number strings): `"500"` = $5.00, `"50"` = $0.50.
> `null` = unlimited, `"0"` = block everything.

If you're setting this up from scratch on a *different* deployment, see
[Appendix: first-time setup](#appendix-first-time-setup) at the end.

---

## Part 1 — Quota demo (the main event)

### Step 0 — Open two terminals

- **Terminal A (admin):** you, setting and raising caps.
- **Terminal B (developer):** signed in as `jiemying-target`, doing the spending.

**Terminal A — point at the gateway and load the admin key:**

```bash
export GW="https://claude-gateway.jiemying.people.aws.dev"
export AWS_PROFILE=sso-management
export ADMIN_KEY=$(aws secretsmanager get-secret-value \
  --secret-id claude-gateway-admin-write --query SecretString --output text)

# Sanity check — should return the current list of caps (may be empty):
curl -sS "$GW/v1/organizations/spend_limits" -H "x-api-key: $ADMIN_KEY" | jq
```

**Terminal B — sign in as the demo developer:**

```bash
claude          # then: /login  → sign in as jiemying-target (password shared out-of-band)
                # confirm with: /status
```

---

### Step 1 — Set a tight cap on the contractor team  *(Terminal A)*

A **50-cent daily cap** on the whole `contractor` group, so we can trip it in a
couple of turns:

```bash
curl -sS -X POST "$GW/v1/organizations/spend_limits" \
  -H "x-api-key: $ADMIN_KEY" -H "Content-Type: application/json" \
  -d '{"scope":{"type":"rbac_group","rbac_group_id":"contractor"},"amount":"50","period":"daily"}' | jq
```

Say out loud: *"Every contractor now has a 50-cent-per-day ceiling on a credential
the whole org shares."*

---

### Step 2 — Watch the spend climb  *(Terminal A)*

This is the "who's near their ceiling" view — resolved cap + spend-to-date, top
spender first:

```bash
curl -sS "$GW/v1/organizations/spend_limits/effective?period[]=daily&sort=spend_desc" \
  -H "x-api-key: $ADMIN_KEY" \
  | jq '.data[] | {user: .actor.email_address, spent: .current_spend, cap: .limit_amount}'
```

Now spend against it in **Terminal B** (a couple of real turns):

```bash
claude -p "Explain this repository's deploy flow in detail, then draft a README section for it."
```

Re-run the `/effective` command in Terminal A between turns to show the number
climbing toward `50`.

---

### Step 3 — Hit the wall  *(Terminal B)*

Once `jiemying-target` crosses 50 cents for the day, the **next request is refused**:

```
429  billing_error
"spend limit reached  Request a higher limit from platform."
```

In Claude Code the turn simply fails with that message. **This is the circuit
breaker** — one runaway contractor can't drain the shared bill.

---

### Step 4 — Raise the cap, recover instantly  *(Terminal A)*

Lift the contractor ceiling to $5.00. `POST` replaces the cap for that
`{scope, period}`:

```bash
curl -sS -X POST "$GW/v1/organizations/spend_limits" \
  -H "x-api-key: $ADMIN_KEY" -H "Content-Type: application/json" \
  -d '{"scope":{"type":"rbac_group","rbac_group_id":"contractor"},"amount":"500","period":"daily"}' | jq
```

Back in **Terminal B**, the developer's **very next request succeeds** — no
redeploy, no restart. The cap change is live.

---

### Step 5 — Show the audit trail  *(Terminal A)*

Every cap change is recorded — who changed what, and when:

```bash
curl -sS "$GW/v1/organizations/spend_limits/audit?limit=5" -H "x-api-key: $ADMIN_KEY" | jq
```

---

### Bonus — protect yourself while capping others  *(optional)*

A **per-user cap always wins** over any group/org cap. To make sure *you*
(`jiemying`) are never locked out, give yourself an explicit "unlimited":

```bash
# Find your OIDC sub (the API keys on sub, not username):
curl -sS "$GW/v1/organizations/spend_limits/effective?q=jiemying%40amazon.com" \
  -H "x-api-key: $ADMIN_KEY" | jq '.data[] | {user_id, email: .actor.email_address}'

export MY_SUB="<sub-from-above>"

# Unlimited override — you're never blocked (but still tracked + alarmed):
curl -sS -X POST "$GW/v1/organizations/spend_limits" \
  -H "x-api-key: $ADMIN_KEY" -H "Content-Type: application/json" \
  -d "{\"scope\":{\"type\":\"user\",\"user_id\":\"$MY_SUB\"},\"amount\":null,\"period\":\"monthly\"}" | jq
```

The "alert-only" half (get *notified* when you spend a lot, without being
*stopped*) is the per-user CloudWatch alarm — see Part 3.

---

### Reset the demo  *(Terminal A)*

```bash
# List caps, find the contractor cap's spl_ id, then delete it:
curl -sS "$GW/v1/organizations/spend_limits" -H "x-api-key: $ADMIN_KEY" \
  | jq '.data[] | {id, scope, amount, period}'
curl -sS -X DELETE "$GW/v1/organizations/spend_limits/<spl_id>" -H "x-api-key: $ADMIN_KEY" | jq
```

---

## Part 2 — RBAC: deny a tool to one team

Group access is set at deploy time (`DENY_TOOL_GROUP` / `DENY_TOOLS`). Example —
take the weather tool away from the `partners` group, leave everyone else alone:

```bash
export DENY_TOOL_GROUP=partners
export DENY_TOOLS="mcp__weather"     # whole server; or mcp__weather__get_weather for one tool
./deploy.sh
```

- A **partners** user loses that tool. A denied **model** is rejected at the API
  (`400`) — not just hidden in the picker, so a patched client can't get around it.
- **Everyone else** is unchanged.
- **Propagation:** a policy edit reaches signed-in CLIs on their next hourly poll
  after redeploy; a **change of team membership** takes effect at the user's next
  `/login`.

Per-team model allowlists work the same way (`availableModels` +
`enforceAvailableModels: true` in the policy — see `docs/CONFIG.md`).

---

## Part 3 — Observability: the dashboard

Open **CloudWatch → Dashboards → `claude-gateway-collector-usage`**. Set the time
picker (top-right) to **1 week** so the bars have data.

- **Cost by user / team / model / agent** — one labeled bar each, totalling over
  the selected range. `contractor` shows as its own bar next to `platform`.
- **Token usage by type and model** — the time-series trends.
- **Governance (audit) widgets** — tool accept-vs-reject, top rejections by user,
  auth events. These read the events log; they populate as new traffic runs
  through the log-forwarding tasks.

**Alarms** (CloudWatch → Alarms) fire into SNS → email / Slack / PagerDuty:
daily-cost threshold, cost anomaly, tool-rejection bursts, API errors, plus an
optional **per-user cost alarm** — the "alert-only" complement to a hard cap
(notify when someone spends a lot, without ever blocking them). That SNS topic is
also a clean hook point for a Lambda that could, say, auto-adjust a cap.

> The gateway never logs prompt or completion content. Metrics carry counts; audit
> logs carry commands and file paths, which is why they're opt-in.

---

## One-page cheat sheet

```bash
# setup (Terminal A)
export GW="https://claude-gateway.jiemying.people.aws.dev"
export AWS_PROFILE=sso-management
export ADMIN_KEY=$(aws secretsmanager get-secret-value --secret-id claude-gateway-admin-write --query SecretString --output text)

# 1. cap contractor at $0.50/day
curl -sS -X POST "$GW/v1/organizations/spend_limits" -H "x-api-key: $ADMIN_KEY" -H "Content-Type: application/json" \
  -d '{"scope":{"type":"rbac_group","rbac_group_id":"contractor"},"amount":"50","period":"daily"}'

# 2. watch spend (re-run between turns)
curl -sS "$GW/v1/organizations/spend_limits/effective?period[]=daily&sort=spend_desc" -H "x-api-key: $ADMIN_KEY" \
  | jq '.data[] | {user:.actor.email_address, spent:.current_spend, cap:.limit_amount}'

# 3. (Terminal B) spend as jiemying-target until 429
claude -p "Explain this repo's deploy flow, then draft a README section."

# 4. raise to $5/day → next request works
curl -sS -X POST "$GW/v1/organizations/spend_limits" -H "x-api-key: $ADMIN_KEY" -H "Content-Type: application/json" \
  -d '{"scope":{"type":"rbac_group","rbac_group_id":"contractor"},"amount":"500","period":"daily"}'

# 5. audit trail
curl -sS "$GW/v1/organizations/spend_limits/audit?limit=5" -H "x-api-key: $ADMIN_KEY" | jq
```

---

## Appendix: first-time setup

Only needed on a **fresh** deployment where the admin API isn't enabled yet (this
environment already has it). Two one-time steps:

```bash
# 1. Create the admin write key secret (the x-api-key for the caps API):
aws secretsmanager create-secret --name claude-gateway-admin-write \
  --secret-string "$(openssl rand -base64 32)"

# 2. Redeploy the gateway with enforcement on:
export ENABLE_SPEND_CAPS=true
export GATEWAY_ADMIN_WRITE_KEY_ARN=$(aws secretsmanager describe-secret \
  --secret-id claude-gateway-admin-write --query ARN --output text)
export SPEND_CAP_FAIL_CLOSED=false     # keep inference up if Postgres blips
./deploy.sh
```

Then set caps via the API exactly as in Part 1. Full option reference:
`docs/CONFIG.md` → "Spend caps".
