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
  --secret-id claude-gateway-admin-write --region ap-southeast-2 \
  --query SecretString --output text)

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

The `effective` endpoint is the "who is near their ceiling" view. For each
principal it returns the resolved cap alongside the spend so far in the period,
sorted with the top spender first. This is the live meter you re-run throughout
the demo — there is no Claude Code slash command involved, it is just this
`curl` against the spend-limits API:

```bash
curl -sS "$GW/v1/organizations/spend_limits/effective?period[]=daily&sort=spend_desc" \
  -H "x-api-key: $ADMIN_KEY" \
  | jq '.data[] | {user: .actor.email_address, spent: .period_to_date_spend, cap: .amount}'
```

The API field for spend so far is `period_to_date_spend`, and the resolved cap is
`amount` (in US cents; `null` means unlimited). A principal only appears in this
view after they have sent at least one request in the period, so `jiemying-target`
will not be listed until they spend. Note also that the unfiltered daily query
above returns the real figures; the `?q=<email>` filtered form returns hollow
rows and should not be used as the meter.

Now generate spend in **Terminal B**. The prompt below is deliberately verbose so
each turn produces a large completion (output tokens dominate the cost), and it
tells Claude to read files but never to write them, so your working tree stays
untouched:

```bash
claude -p "Analysis only — do not create, edit, or write any files. Read deploy.sh, deploy-all.sh, and infrastructure/claude-apps-gateway.yaml, then write an exhaustive, verbose architecture review of roughly 2000 words covering every CloudFormation resource and its purpose, the TLS mode precedence, the telemetry modes, the RBAC model, and the spend-cap enforcement path."
```

A single Opus turn is only a few cents, so you will usually need several turns to
cross the 50-cent ceiling. To avoid retyping, run a short loop — the iteration
number keeps each turn distinct so none of them is served from cache:

```bash
for i in 1 2 3 4 5; do
  claude -p "Analysis only — do not create, edit, or write any files. Iteration $i: write a fresh, detailed essay of roughly 2500 words on AWS networking best practices for private ALBs, VPC design, and TLS termination. Do not repeat earlier iterations."
done
```

Re-run the `effective` meter in Terminal A between turns and watch `spent` climb
toward `50`.

---

### Step 3 — Hit the wall  *(Terminal B)*

Once `jiemying-target` crosses 50 cents for the day, the **next request is refused**:

```
429  billing_error
"spend limit reached  Request a higher limit from platform."
```

In Claude Code the turn simply fails with that message. **This is the circuit
breaker** — one runaway contractor cannot drain the shared bill.

Token accounting can lag a turn behind the meter, so if the reported spend is
close to `50` but a request still succeeds, run one more turn rather than
assuming enforcement has stalled.

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
# Find your OIDC sub (the API keys on the sub, not the username). Query the
# unfiltered daily view and pick your row out with jq — the ?q= filter returns
# hollow rows without a user_id, so it cannot be used to resolve a sub:
curl -sS "$GW/v1/organizations/spend_limits/effective?period[]=daily" \
  -H "x-api-key: $ADMIN_KEY" \
  | jq '.data[] | {user_id: .actor.user_id, email: .actor.email_address}'

export MY_SUB="<sub-from-above>"

# Unlimited override — you're never blocked (but still tracked + alarmed):
curl -sS -X POST "$GW/v1/organizations/spend_limits" \
  -H "x-api-key: $ADMIN_KEY" -H "Content-Type: application/json" \
  -d "{\"scope\":{\"type\":\"user\",\"user_id\":\"$MY_SUB\"},\"amount\":null,\"period\":\"monthly\"}" | jq
```

The "alert-only" half (get *notified* when you spend a lot, without being
*stopped*) is the per-user CloudWatch alarm — see Part 3.

---

### Reset the quota cap  *(Terminal A)*

Delete the contractor cap as soon as you finish Part 1, so no real contractor is
left capped on the shared deployment:

```bash
# List caps, find the contractor cap's spl_ id, then delete it:
curl -sS "$GW/v1/organizations/spend_limits" -H "x-api-key: $ADMIN_KEY" \
  | jq '.data[] | {id, scope, amount, period}'
curl -sS -X DELETE "$GW/v1/organizations/spend_limits/<spl_id>" -H "x-api-key: $ADMIN_KEY" | jq
```

The full teardown for everything the demo changes — this cap plus the RBAC deny
and the demo login — is collected in [Cleanup](#cleanup-after-the-demo) at the end.

---

## Part 2 — RBAC: deny a tool to one team

Unlike the quota cap, group access is set at **deploy time** through the
`DENY_TOOL_GROUP` and `DENY_TOOLS` variables, so it involves a gateway redeploy
rather than a live API call — which is exactly why it is **pre-staged, not run
live in the demo**. On this deployment the `contractor` group already has the
built-in `WebFetch` tool denied (every other group is untouched), so in the room
you skip straight to showing the refusal. There is no waiting on an ECS cycle in
front of the audience.

The rest of this section documents how that deny was deployed, for reference and
for reproducing it on another environment.

**Reuse the deployment's existing environment, then add the two deny variables.**
A bare `./deploy.sh` will fail on the first missing required variable, and if some
variables happen to be set but `ENABLE_SPEND_CAPS` is not, the redeploy would turn
the Part 1 enforcement back off. Source the same profile this gateway was deployed
from and keep spend caps enabled:

```bash
source config/<profile-you-deployed-with>.env   # restores OIDC, cert, image, etc.
export ENABLE_SPEND_CAPS=true                    # keep the Part 1 enforcement on
export GATEWAY_ADMIN_WRITE_KEY_ARN=<same ARN used originally>
export DENY_TOOL_GROUP=contractor
export DENY_TOOLS="WebFetch"                      # a bare mcp__<server> denies a whole MCP server
./deploy.sh
```

The deny policy is rendered into the task definition, which means it takes effect
in two stages rather than instantly (this is why it is pre-staged):

1. The redeploy creates a new task-definition revision and ECS cycles the task,
   which takes a few minutes.
2. A signed-in CLI then only adopts the new policy on its roughly hourly
   managed-settings poll. To show the change inside a demo window, have the user
   restart Claude Code (or `/logout` then `/login`) so it re-fetches settings
   immediately instead of waiting for the next poll.

Once it has propagated:

- A **contractor** user (for example `jiemying-target`) no longer has `WebFetch`
  in the session — the policy removes it — whereas a user in another group (such
  as your own `platform` group) still has it. Note that the tool is *filtered out*
  of the contractor's session rather than rejected mid-call, so the model will
  happily reach the same goal another way (for example `curl` via Bash) unless you
  either deny those tools too or instruct it not to substitute. For a clean
  refusal in a demo, tell it explicitly not to route around the missing tool:
  ```bash
  claude -p "Use the WebFetch tool to retrieve https://example.com and summarize it. Do not use Bash, curl, wget, or any other tool as a substitute — if WebFetch is unavailable, stop and tell me it was denied."
  ```
  A denied **model**, by contrast, is rejected at the API with a `400` rather than
  merely hidden in the picker, so a patched client cannot reach around it.
- **Every other group** is unchanged.
- **Propagation:** a policy edit reaches signed-in CLIs on their next hourly poll
  after the redeploy, and a change of team membership takes effect at the user's
  next `/login`.

Per-team model allowlists work the same way (`availableModels` and
`enforceAvailableModels: true` in the policy — see `docs/CONFIG.md`).

---

## Part 3 — Observability: the dashboard

This follows naturally from Part 2: the same contractor whose spend you capped
and whose tool you denied is now a labelled line in the cost views. Open
**CloudWatch → Dashboards → `claude-gateway-collector-usage`** and set the time
picker (top-right) to a window that covers the demo — **the last 1–3 hours** for
data you just generated, or **1 week** for a fuller history.

- **Cost by user / team / model / agent** — one labeled bar each, totalling over
  the selected range. `contractor` (`jiemying-target`) shows as its own bar next
  to `platform` (you). This is the "every number carries a name" attribution
  story, and it is driven by the metrics stream, which is live and populated.
- **Token usage by type and model** — the time-series trends.

> **Audit (events) widgets — know before you demo.** The tool accept-vs-reject,
> top-rejections, and auth widgets read the `/aws/claude-gateway/events` log, which
> is separate from the metrics stream. Two things make it easy to over-promise:
> a group tool-deny is enforced by removing the tool from the session (the client
> never issues a rejected call, so it may not emit a `tool_decision` event at all),
> and the events pipeline has to be fully wired end to end before anything lands
> there. Verify the log group has a non-zero `storedBytes` **before** you rely on
> these widgets in front of an audience — if it is empty, narrate the tool deny
> from Part 2 instead and keep the dashboard portion on the cost views.

**Alarms** (CloudWatch → Alarms) fire into SNS → email / Slack / PagerDuty:
daily-cost threshold, cost anomaly, tool-rejection bursts, API errors, plus an
optional **per-user cost alarm** — the "alert-only" complement to a hard cap
(notify when someone spends a lot, without ever blocking them). That SNS topic is
also a clean hook point for a Lambda that could, say, auto-adjust a cap.

> The gateway never logs prompt or completion content. Metrics carry counts; audit
> logs carry commands and file paths, which is why they're opt-in.

---

## Cleanup after the demo

The demo changes three pieces of live state on a shared deployment. Only the first
needs to be reverted; the other two are intentional and stay.

**1. Delete the quota cap — required.**  The 50-cent contractor cap is a hard
`429` on a real IdP group. Remove it as soon as Part 1 is done so no genuine
contractor is left capped:

```bash
# List caps, copy the contractor cap's spl_ id, then delete it:
curl -sS "$GW/v1/organizations/spend_limits" -H "x-api-key: $ADMIN_KEY" \
  | jq '.data[] | {id, scope, amount, period}'
curl -sS -X DELETE "$GW/v1/organizations/spend_limits/<spl_id>" -H "x-api-key: $ADMIN_KEY" | jq

# Confirm it is gone (the list no longer shows a contractor cap):
curl -sS "$GW/v1/organizations/spend_limits" -H "x-api-key: $ADMIN_KEY" \
  | jq '.data[] | {id, scope, amount, period}'
```

If you added the per-user `amount:null` override for yourself in the Bonus step,
delete that the same way (find its `spl_` id in the list, then `DELETE` it).

**2. The contractor `WebFetch` deny — leave it live.**  This is now the intended
steady state of the deployment, not demo scaffolding, so there is nothing to
revert. It only reverts if you redeploy without `DENY_TOOL_GROUP`/`DENY_TOOLS`;
don't do that unless you actually want contractors to regain `WebFetch`.

**3. The demo login — rotate when the demo run is over.**  `jiemying-target` is a
real Cognito user. When you are finished demoing, reset its password (and, if it
was created only for this, consider disabling the user) so the shared password is
no longer valid:

```bash
aws cognito-idp admin-set-user-password --region ap-southeast-2 \
  --user-pool-id ap-southeast-2_YpOBNdHPj --username jiemying-target \
  --password "$(openssl rand -base64 18)" --permanent
```

---

## One-page cheat sheet

```bash
# setup (Terminal A)
export GW="https://claude-gateway.jiemying.people.aws.dev"
export AWS_PROFILE=sso-management
export ADMIN_KEY=$(aws secretsmanager get-secret-value --secret-id claude-gateway-admin-write --region ap-southeast-2 --query SecretString --output text)

# 1. cap contractor at $0.50/day
curl -sS -X POST "$GW/v1/organizations/spend_limits" -H "x-api-key: $ADMIN_KEY" -H "Content-Type: application/json" \
  -d '{"scope":{"type":"rbac_group","rbac_group_id":"contractor"},"amount":"50","period":"daily"}'

# 2. watch spend (re-run between turns)
curl -sS "$GW/v1/organizations/spend_limits/effective?period[]=daily&sort=spend_desc" -H "x-api-key: $ADMIN_KEY" \
  | jq '.data[] | {user:.actor.email_address, spent:.period_to_date_spend, cap:.amount}'

# 3. (Terminal B) spend as jiemying-target until 429 (read-only, no file writes)
for i in 1 2 3 4 5; do
  claude -p "Analysis only — do not create, edit, or write any files. Iteration $i: write a detailed essay of roughly 2500 words on AWS networking best practices for private ALBs, VPC design, and TLS termination. Do not repeat earlier iterations."
done

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

Create the secret in the **same region as the gateway deployment** (this one is
`ap-southeast-2`); pass `--region` on every `secretsmanager` call, or set
`AWS_REGION`, so reads later resolve to the right region.

```bash
# 1. Create the admin write key secret (the x-api-key for the caps API):
aws secretsmanager create-secret --name claude-gateway-admin-write \
  --region ap-southeast-2 --secret-string "$(openssl rand -base64 32)"

# 2. Redeploy the gateway with enforcement on:
export ENABLE_SPEND_CAPS=true
export GATEWAY_ADMIN_WRITE_KEY_ARN=$(aws secretsmanager describe-secret \
  --secret-id claude-gateway-admin-write --region ap-southeast-2 --query ARN --output text)
export SPEND_CAP_FAIL_CLOSED=false     # keep inference up if Postgres blips
./deploy.sh
```

Then set caps via the API exactly as in Part 1. Full option reference:
`docs/CONFIG.md` → "Spend caps".
