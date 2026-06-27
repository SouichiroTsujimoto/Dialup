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
- Coolify Web UI login and redeploy operations are handled by the user, not the agent.

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
6. After the workflow succeeds, stop and ask the user to redeploy the Coolify app:
   - Tell the user to trigger `Redeploy` or `Pull latest image & restart` for the app using `ghcr.io/souichirotsujimoto/dialup:latest`.
   - Do not log into Coolify or operate the Coolify Web UI.
7. After the user says redeploy is complete, verify production:
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
- Coolify redeploy is a user-owned manual step because it requires Web UI login and operation.
