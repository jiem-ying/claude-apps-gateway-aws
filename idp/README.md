# Identity (OIDC IdP)

The gateway is a **confidential OIDC web application**. It works with any OIDC
provider. All it needs from your IdP is:

- an **issuer** URL that serves `/.well-known/openid-configuration`,
- a confidential **client_id** + **client_secret**, and
- a redirect URI of exactly `https://<gateway-hostname>/oauth/callback`.

Pick the path that matches what you already have.

## Path 1 — I already run a Cognito user pool (reuse)

Use **`cognito-existing-pool.yaml`**. It adds a confidential app client to your
existing pool and stores the generated secret in Secrets Manager. It references
the pool by id only — it never modifies the pool.

```bash
aws cloudformation deploy --stack-name claude-gateway-cognito-client \
  --template-file idp/cognito-existing-pool.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    UserPoolId=<region>_xxxxxxxxx \
    GatewayHostname=claude-gateway.internal.example.com
```

Outputs `ClientId`, `ClientSecretArn`, `Issuer` — feed these to the gateway
stack as `OidcClientId`, `OidcClientSecretArn`, `OidcIssuer`.

## Path 2 — I have no IdP yet (create a fresh Cognito pool)

Use **`cognito-create-pool.yaml`**. It stands up a new pool, a hosted-UI domain,
a confidential client, and an initial invite-only admin user.

```bash
aws cloudformation deploy --stack-name claude-gateway-cognito-client \
  --template-file idp/cognito-create-pool.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    GatewayHostname=claude-gateway.example.com \
    HostedUiDomainPrefix=my-org-claude-gw \
    AdminEmail=admin@example.com \
    AdminUsername=admin
```

**Usernames vs. emails.** This template uses `AliasAttributes: [email]`
(not `UsernameAttributes: [email]`), so `Username` is a literal handle you
pick (e.g. `alice`) and email is a **sign-in alias**. That means:
- Users log in with either their `Username` or their email
- Admin tooling like `make-peer-bundle.sh` references users by short
  username (`alice`, `bob`), which reads cleanly in the console.

The initial admin user is created with `Username=$AdminUsername` (default
`admin`) and receives a temp-password email at `$AdminEmail`.

Outputs `UserPoolId`, `ClientId`, `ClientSecretArn`, `Issuer`, `HostedUiDomain`.
The pool is created with `DeletionPolicy: Retain` so you won't lose users if you
tear the stack down.

### Groups & RBAC

`cognito-create-pool.yaml` also creates two demo groups — `platform` (full access)
and `partners` (restricted) — via `FullAccessGroupName` / `RestrictedGroupName`.
Group **membership** is what the gateway's `managed.policies` match on; it flows to
the gateway automatically through the `cognito:groups` claim once a user is assigned
— **no app-client, scope, or schema change is needed** (Cognito injects the claim
for any user in ≥1 group; the gateway reads it via `groups_claim: cognito:groups` +
`userinfo_fallback: true`).

Create groups and assign users (all **live**, no redeploy):

```bash
POOL=<region>_xxxxxxxxx
# Groups (already created by the template above; shown for an existing pool):
aws cognito-idp create-group --user-pool-id $POOL --group-name platform
aws cognito-idp create-group --user-pool-id $POOL --group-name partners
# Assign users:
aws cognito-idp admin-add-user-to-group --user-pool-id $POOL --username alice --group-name platform
aws cognito-idp admin-add-user-to-group --user-pool-id $POOL --username bob   --group-name partners
```

`make-peer-bundle.sh <user> <email> [group]` takes an optional third arg that runs
the assignment for you during onboarding.

> **Re-login required.** A user picks up new group membership only on a **fresh
> token** — they must `/logout` then `/login`. This Cognito app client issues no
> refresh token, so the new `cognito:groups` claim is minted only at next sign-in.
> Editing the *policy* itself (not membership) requires a **gateway redeploy** (its
> config lives in the ECS task-def). See [`../docs/CONFIG.md`](../docs/CONFIG.md) →
> *Group-based policy* and the [`weather-mcp`](../examples/weather-mcp/) demo.

## Path 3 — Okta / Entra ID / Google Workspace / Keycloak / other

No template needed here. In your IdP, create a **confidential OIDC web app** with
redirect URI `https://<gateway-hostname>/oauth/callback`. Then:

1. Put the client secret in Secrets Manager (raw string value) and note its ARN.
2. Pass to the gateway stack:
   - `OidcIssuer` — your provider's issuer (mind the exact format; e.g. Auth0
     requires a trailing slash, Azure must **not** have one).
   - `OidcClientId` — the app's client id.
   - `OidcClientSecretArn` — the Secrets Manager ARN from step 1.
   - `GroupsClaim` — your IdP's groups claim: `groups` for Okta/custom,
     `roles` for some Entra tenants, `cognito:groups` for Cognito.

The gateway design is identical across providers — only these four inputs change.
