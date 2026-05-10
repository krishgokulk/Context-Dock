# Repository Protection Checklist (Implementation Runbook)

This runbook implements the security/access items that cannot be enforced from code alone.

## 1) Set repository visibility to private (manual)
- GitHub → Repository → **Settings** → **General** → **Danger Zone** → **Change repository visibility**.
- Confirm visibility is **Private**.

## 2) Review collaborators (manual)
- GitHub → **Settings** → **Collaborators and teams**.
- Remove accounts that do not have a current business need.
- Use least privilege (Read/Triage/Write/Admin).

## 3) Enforce strong authentication (manual)
- Ensure account-level 2FA is enabled.
- For org-owned repos, enforce org 2FA and SSO policy.

## 4) Rotate secrets/tokens (manual + code)
- Rotate all API keys, DB URLs, OAuth secrets, and app tokens in provider dashboards.
- Update GitHub Actions/repository secrets after rotation.
- Revoke old credentials after validation.

## 5) Scan git history for leaked secrets (manual command)
Use a local scan before every release and after major merges:

```bash
git --no-pager log --all --name-only
# plus your preferred secret scanner against full history
```

If a leak is found:
1. Revoke/rotate credential immediately.
2. Rewrite history with approved tooling.
3. Force-push rewritten history and notify collaborators to re-clone.
4. Document incident + remediation date.

## 6) Public showcase strategy
- Keep this core repository private.
- Publish only a separate showcase repository with non-sensitive materials.
- Never publish production secrets, internal architecture details, or proprietary logic.
