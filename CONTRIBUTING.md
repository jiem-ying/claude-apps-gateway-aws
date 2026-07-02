# Contributing

Thanks for helping improve this deployment guide. Contributions welcome — big or
small, docs or code.

## Scope of this repo

This repo is the **AWS-native deployment** for the [Claude Apps Gateway](https://code.claude.com/docs/en/claude-apps-gateway).
It packages CloudFormation templates, shell orchestration, and docs. It is
**not** the gateway binary itself — that ships in the `claude` CLI (see
`gateway/Dockerfile` for how it's pulled + GPG-verified).

Good contributions:
- New deployment profiles under `config/`
- Bug fixes in `deploy.sh` / `deploy-all.sh` / templates
- Additional IdP examples (Okta / Entra / Google / Keycloak) beyond Cognito
- Docs improvements, especially gotchas that bit you
- Cross-region / cross-cloud (Foundry, Agent Platform) upstream profiles

Out of scope for issues/PRs here:
- Bugs in the gateway server binary → upstream at [anthropics/claude-code](https://github.com/anthropics/claude-code)
- Bedrock model availability / access → AWS Support

## Dev loop

```bash
# Lint every CFN template you touch
cfn-lint infrastructure/claude-apps-gateway.yaml
cfn-lint infrastructure/distribution.yaml
cfn-lint observability/collector.yaml
cfn-lint idp/*.yaml
cfn-lint infrastructure/network-access/client-vpn.yaml

# Syntax-check every shell script you touch
bash -n deploy.sh deploy-all.sh \
       make-peer-bundle.sh distribute-peer-bundle.sh \
       gateway/build-and-push.sh \
       infrastructure/network-access/make-vpn-certs.sh \
       observability/make-collector-cert.sh
```

Before opening a PR: deploy your change against your own AWS account (any
profile in `config/` works) and run `claude /login` + one `claude -p` prompt
end-to-end. The [`docs/GUIDE.md`](docs/GUIDE.md) Verification section covers what
"working" looks like.

## Repo hygiene

- **No site-specific values in commits.** No account IDs, real ARNs, real
  hostnames, real Cognito pool ids, real profile names. Use placeholders like
  `Zxxxxxxxxxxxxx`, `example.com`, `admin@example.com`. `.gitignore` already
  covers generated PKI (`vpn-pki/`, `collector-pki/`, `*.ovpn`, `*.pem`).
- **All new params need a `Default: ""`** (or a benign default). Old stacks
  must upgrade cleanly.
- **Backward-compat.** `deploy.sh` and existing env-var-based flows should keep
  working unchanged. New behavior goes behind an opt-in toggle.
- **Conditional resource refs go inside `!If [Condition, ...]`** or cfn-lint
  E1 flags them.

## Commit / PR style

- Small, focused commits. One concern per PR.
- PR title in imperative present: `fix(vpn): ...`, `feat(orchestration): ...`,
  `docs: ...`. See existing commits for examples.
- Fill in the [pull request template](.github/pull_request_template.md);
  especially the "Testing done" checklist.

## License

This repo is [MIT-0](LICENSE). By submitting a PR you certify you have the
right to contribute the code under that license.
