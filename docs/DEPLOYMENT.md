# DEPLOYMENT.md — the live deployment of THIS repo

Concrete facts about the actual running gateway, so you don't have to rediscover
them. `CONFIG.md` explains the knobs; this file records **how they're currently
set in production** and how to push a change safely.

## The live stack (as deployed)

| | |
|---|---|
| **AWS profile** | `sso-management` (`AWSAdministratorAccess`, account `126672810070`) |
| **Region** | `ap-southeast-2` |
| **CloudFormation stack** | `claude-gateway` |
| **Template** | `infrastructure/claude-apps-gateway.yaml` |
| **Gateway URL** | `https://claude-gateway.jiemying.people.aws.dev` |
| **ECS cluster/service** | `claude-gateway-Service-*` (gateway), `claude-gateway-collector-Service-*` (ADOT) |
| **Gateway task-def family** | `claude-gateway-gateway` |
| **Image** | `…dkr.ecr.ap-southeast-2.amazonaws.com/claude-apps-gateway:2.1.196-clean` |

> The federated **Bedrock** role you land in by default (`BedrockCognitoFederatedRole`)
> has **no** ECS/CFN permissions. Always deploy/inspect with `--profile sso-management`
> (or `export AWS_PROFILE=sso-management AWS_REGION=ap-southeast-2`).

## TLS / IdP / features currently in effect

- **TLS mode:** managed public ACM cert — `DomainName=claude-gateway.jiemying.people.aws.dev`,
  `PublicHostedZoneId=Z081944822ZCAUD5293Y9`. (BYO/self-signed vars are empty.)
- **IdP:** new Cognito — issuer `…/ap-southeast-2_YpOBNdHPj`, client `2m67v9h3427rbjr25fjiq3t6if`,
  `AllowedEmailDomains=amazon.com`, `GroupsClaim=cognito:groups`.
- **Telemetry:** ON → `CollectorEndpoint=https://claude-otel.jiemying.people.aws.dev`, metrics + logs.
  Collector runs the **native default** (`EnableCodingAgentInsights=true`) — metrics go over
  native OTLP to CloudWatch and auto-populate the managed **GenAI Observability → Coding Agent
  Insights → Claude Code** dashboard (`ap-southeast-2` is a supported region); the stack also
  ships the `claude-gateway-collector-governance` dashboard for governance/audit. Cost/usage
  alarms are PromQL alarms.
- **Spend caps:** ON (`EnableSpendCaps=true`, `AdminWriteKeyArn=…claude-gateway-admin-write-*`,
  fail-open). Caps themselves are set via the Admin API, not the stack.
- **ALB idle timeout:** 4000s. **Min/Max tasks:** 2 / 10.

## Governance policy currently enforced (`managed.policies`)

1. Group `contractor` → denied `WebFetch` (keeps all models).
2. `match: {}` catch-all → **org-wide model allowlist, server-enforced**
   (`enforceAvailableModels: true`). The full shipped 12-id allowlist (both
   `global.anthropic.*` and short-alias forms). This makes the gateway
   authoritative over models: a developer's local `settings.json` model pin
   **cannot** select anything off-list — the gateway returns a 400. It does
   **not** force a default model. Driven by `ENFORCE_MODELS` in `deploy.sh`.

## How to deploy a change

### Preferred: `deploy.sh` (re-renders config from the template)

Source the profile file you use for this stack, then run. To reproduce the
**current** governance state, set both:

```bash
export AWS_PROFILE=sso-management AWS_REGION=ap-southeast-2
# full shipped allowlist, both id forms (see gateway/gateway.yaml.example):
export ENFORCE_MODELS="global.anthropic.claude-opus-4-7,global.anthropic.claude-opus-4-8,global.anthropic.claude-sonnet-4-6,global.anthropic.claude-sonnet-5,global.anthropic.claude-haiku-4-5-20251001-v1:0,global.anthropic.claude-fable-5,claude-opus-4-7,claude-opus-4-8,claude-sonnet-4-6,claude-sonnet-5,claude-haiku-4-5,claude-fable-5"
export DENY_TOOL_GROUP=contractor DENY_TOOLS=WebFetch
# …plus the OIDC_*, DOMAIN_NAME, PUBLIC_HOSTED_ZONE_ID, ENABLE_SPEND_CAPS=true,
#    GATEWAY_ADMIN_WRITE_KEY_ARN, COLLECTOR_ENDPOINT, GATEWAY_IMAGE_URI values
#    from the table above (deploy.sh reads them as env vars).
./deploy.sh
```

`deploy.sh` shells out to `cfn deploy` (the Builder Toolbox `cfn` wrapper). If
`cfn` isn't on PATH in your shell, use the config-only path below.

### Config-only change without `cfn` on PATH (what was used to ship enforcement)

When you only need to change `GatewayConfigContent` (e.g. the managed policy),
update the stack in place and keep every other parameter at its previous value:

```bash
export AWS_PROFILE=sso-management AWS_REGION=ap-southeast-2
# 1. pull the current config, edit the managed: block (keep comments stripped so
#    the render matches deploy.sh; must stay < 4096 bytes)
aws cloudformation describe-stacks --stack-name claude-gateway \
  --query "Stacks[0].Parameters[?ParameterKey=='GatewayConfigContent'].ParameterValue|[0]" --output text
# 2. build a params file: GatewayConfigContent=<new>, all others UsePreviousValue:true
# 3. push:
aws cloudformation update-stack --stack-name claude-gateway --use-previous-template \
  --capabilities CAPABILITY_NAMED_IAM CAPABILITY_IAM --parameters file:///tmp/cfn-params.json
aws cloudformation wait stack-update-complete --stack-name claude-gateway
```

### ENFORCE_MODELS `deploy.sh` env var

`deploy.sh` renders `ENFORCE_MODELS` (comma-separated ids) onto the `match: {}`
catch-all as `availableModels: […], enforceAvailableModels: true`. Empty = no
model enforcement (backward-compatible). Composes with `DENY_TOOL_GROUP` /
`DENY_TOOLS`. See `CONFIG.md` → "Org-wide model allowlist".

## After ANY managed-policy change — REQUIRED

Config lives in the task-def, so a change is a new task-def revision → ECS
auto-cycles the service (no manual restart). But it only reaches users when:

1. **CLIs poll managed-settings (~hourly)** after the new revision is running, and
2. **each user `/logout` + `/login`** — this Cognito client has **no refresh
   token**, so a new/changed policy or `cognito:groups` claim is only minted at
   next login.

Tell testers to re-login, or they'll keep the pre-change policy for up to the
session TTL (8h).

## Verify a deploy landed

```bash
export AWS_PROFILE=sso-management AWS_REGION=ap-southeast-2
# stack ok?
aws cloudformation describe-stacks --stack-name claude-gateway --query 'Stacks[0].StackStatus' --output text
# running task-def carries the change?
aws ecs describe-task-definition --task-definition claude-gateway-gateway \
  --query "taskDefinition.containerDefinitions[0].environment[?name=='GATEWAY_CONFIG_CONTENT'].value|[0]" \
  --output text | grep -A6 '^managed:'
# service healthy?
aws ecs describe-services --cluster <claude-gateway cluster> --services <gateway service> \
  --query 'services[0].{running:runningCount,rollout:deployments[0].rolloutState}'
```
