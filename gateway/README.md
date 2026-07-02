# Claude Apps Gateway — container image and config

Reusable, IdP-agnostic building blocks for deploying the
[Claude Apps Gateway](https://code.claude.com/docs/en/claude-apps-gateway) on AWS
ECS Fargate with an Amazon Bedrock upstream. The full step-by-step walkthrough is
in [`../docs/GUIDE.md`](../docs/GUIDE.md).

| File | Purpose |
|------|---------|
| `Dockerfile` | Image around the pinned, GPG-verified native `claude` Linux (glibc) binary; runs `claude gateway`. |
| `entrypoint.sh` | Writes the injected config and assembles the Postgres URL from ECS-injected secrets, then `exec claude gateway`. |
| `build-and-push.sh` | Build + push the image to ECR (`./build-and-push.sh <version>`). |
| `gateway.yaml.example` | Annotated, IdP-agnostic `gateway.yaml` template (placeholders rendered at deploy time). For a prose walkthrough of every section and *why* it's set the way it is, see [`../docs/CONFIG.md`](../docs/CONFIG.md). |
| `extra-ca/` | **Optional**: `.crt` files here are baked into the image's system trust store via `update-ca-certificates`. Set `COLLECTOR_CA_PEM=<path>` when running `build-and-push.sh` to trust a self-signed OTEL collector or a corporate PKI. Widens the trust surface for all outbound TLS — prefer public ACM certs where possible. |

The CloudFormation stack that consumes these lives at
[`../infrastructure/claude-apps-gateway.yaml`](../infrastructure/claude-apps-gateway.yaml):
a self-contained, parameterized deployment (VPC + RDS PostgreSQL + ECS Fargate +
IPv4 internal ALB + regional NAT + private DNS + ECS auto-scaling), with optional
OTLP telemetry forwarding and **no dependency on any other stack**.

## At a glance

- **Standalone**: deploys with no other stacks or moving parts — just SSO
  sign-in and inference through Bedrock.
- **IdP-agnostic**: any OIDC provider (Cognito, Okta, Entra, Google, Keycloak…)
  via parameters (`OidcIssuer`, `OidcClientId`, `OidcClientSecretArn`, `GroupsClaim`).
- **Private-only**: internal IPv4 ALB + private hosted zone (Claude Code's `/login`
  rejects gateways that resolve to public IPs).
- **HA + autoscaling by default**: ≥2 tasks across AZs, regional NAT, ECS
  auto-scaling on CPU + ALB request count, deployment circuit breaker.
- **Optional telemetry**: forward OTLP/HTTP to an existing collector, or none.
