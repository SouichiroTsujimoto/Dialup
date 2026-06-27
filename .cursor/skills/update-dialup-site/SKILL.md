---
name: update-dialup-site
description: Update and deploy the Dialup official site at dialup-framework.org. Use when the user asks to update, deploy, publish, redeploy, or refresh the Dialup site.
---

# Update Dialup Site

Use this skill to publish changes to the Dialup official site.

## Production Model

- Site app: `site/`
- Public URL: `https://dialup-framework.org`
- Default branch: `master`
- Image: `ghcr.io/souichirotsujimoto/dialup:latest`
- Pipeline: `master` push -> GitHub Actions `Docker Publish` -> GHCR -> Coolify manual redeploy
- Coolify does not auto-deploy from GitHub for this app.

## Workflow

1. Inspect the working tree:
   - `git status --short --branch`
   - `git diff --stat`
   - `git diff`
   - `git log --oneline -5`
2. Verify locally from `site/`:
   - `mix deps.get` if dependencies may be missing
   - `mix compile`
3. Commit only relevant changes. Do not include secrets or unrelated local files.
4. Push to `master`:
   - `git push origin master`
5. Watch the publish workflow:
   - `gh run list --workflow "Docker Publish" --branch master --limit 1`
   - `gh run watch <run-id> --exit-status`
6. After the workflow succeeds, redeploy the Coolify app:
   - Open Coolify if browser access is available.
   - Trigger `Redeploy` or `Pull latest image & restart` for the app using `ghcr.io/souichirotsujimoto/dialup:latest`.
   - If Coolify access is not available, stop and tell the user the exact manual action still needed.
7. Verify production:
   - Fetch or open `https://dialup-framework.org`
   - Check at least the changed page path.
   - For MCP/session changes, also verify that the page can issue an agent handoff endpoint.

## Commit Message

Use a concise sentence in the repository style. Prefer:

```text
Update Dialup site <short purpose>.
```

## Notes

- Do not force push.
- Do not change git config.
- If not on `master`, ask whether to merge through a PR or switch to `master`; do not deploy a feature branch as production.
- A successful GitHub Action only publishes the GHCR image. The live site is updated after Coolify pulls and restarts the image.
