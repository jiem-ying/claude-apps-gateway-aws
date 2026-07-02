# Observability — optional self-hosted OTEL collector + CloudWatch

An **optional** module for orgs that have **no third-party observability platform**
(Datadog, Splunk, etc.) and want Claude Apps Gateway usage metrics in **CloudWatch**.
It provisions an ECS Fargate [AWS Distro for OpenTelemetry](https://aws-otel.github.io/)
(ADOT) collector behind an **internal HTTPS ALB**, exports metrics to CloudWatch via
the `awsemf` exporter, and ships a ready-made CloudWatch **dashboard**.

**Toggle:** deploy this stack to turn gateway telemetry on; don't deploy it and the
gateway runs fine with no telemetry. There is no hard dependency either way.

```
gateway (ECS) ──OTLP/HTTPS──▶ collector ALB (443) ──▶ ADOT (4318) ──awsemf──▶ CloudWatch
                                                                               ├─ metrics (ns: ClaudeGateway)
                                                                               └─ dashboard
```

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
header-extraction processors. The dashboard shows token usage, cost, and sessions;
extend `metric_declarations` in `collector.yaml` and the `Dashboard` body for more.

## Teardown

Delete `claude-gateway-collector` before the gateway stack (it references the
gateway's VPC/zone). Then set the gateway's `COLLECTOR_ENDPOINT` back to empty and
redeploy, or leave it — a missing collector just means telemetry POSTs fail
silently; the gateway keeps serving.

> **Generated PKI is secret.** `collector-pki/` is gitignored — never commit it.
