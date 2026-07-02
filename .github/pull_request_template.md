# Pull request

## What
<!-- One-line summary of the change. -->

## Why
<!-- What problem does this solve? Link an issue if one exists. -->

## Testing done
<!-- Which paths did you verify? Delete rows that don't apply. -->
- [ ] `cfn-lint` clean on any touched YAML
- [ ] `bash -n` on any touched shell script
- [ ] Deployed against a personal account (managed cert / BYO / self-signed — circle one)
- [ ] Ran `claude /login` + `claude -p "..."` end-to-end
- [ ] Verified backward compat (existing env-var deploys still work)

## Notes for reviewers
<!-- Anything non-obvious: template gotchas, CFN blocking behavior, cost implications, etc. -->

---
By submitting this PR you certify you have the right to contribute the code
under the license in `LICENSE` (MIT-0) and that you haven't included any
site-specific secrets or ARNs.
