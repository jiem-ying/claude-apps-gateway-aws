---
name: Bug report
about: Something in this repo doesn't work as documented
title: "[bug] "
labels: bug
assignees: ''
---

<!--
⚠️  For security-related issues (credential leaks, OIDC secret handling,
    telemetry-endpoint SSRF, self-signed CA trust) — DO NOT open a public
    issue. See SECURITY.md for private reporting.
-->

## Deployment context
- **Deployment mode**: managed public ACM / BYO cert / self-signed  <!-- pick one -->
- **Profile used (if any)**: e.g. `config/managed-newcognito-collector-vpn.env` or "custom env vars"
- **AWS region**: e.g. `us-east-1`
- **Claude Code CLI version**: `claude --version`
- **Repo commit/tag**: `git rev-parse --short HEAD` or a tag

## Toggles
- IDP_MODE = ...
- ENABLE_COLLECTOR = ...
- ENABLE_VPN = ...
- BUILD_IMAGE = ...

## What happened
<!-- What you did, what you saw, what you expected. -->

## Repro
<!-- Minimum steps. Redact anything sensitive. -->
```
1. ...
2. ...
```

## Logs / errors
<!-- deploy.sh output, CFN stack events, ECS task logs (/ecs/claude-gateway-gateway), etc. Redact ARNs/IPs if sensitive. -->
```
```

## Anything else
<!-- Related issues, workarounds tried, etc. -->
