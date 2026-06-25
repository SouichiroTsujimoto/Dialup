# Cursor Automations MVP Setup

This repository includes draft payloads for two Cursor Automations:

- `.cursor/automations/pr-review-and-repair.json`
- `.cursor/automations/issue-implementation.json`

## 1. PR Review and Repair

Trigger:

- PR opened
- PR pushed
- CI completed

Behavior:

- Review the PR
- Fix clear issues directly on the PR branch
- Comment with `Blocking`, `Fixed`, `Needs human decision`, `Verified`, and `Not run`

Setup:

1. Delete the empty placeholder automation if one already exists.
2. Open a new automation draft from `.cursor/automations/pr-review-and-repair.json`.
3. Confirm these fields are populated before saving:
   - Repository: `SouichiroTsujimoto/Dialup`
   - Triggers: PR opened, PR pushed, CI completed
   - Tool: Comment on pull request
   - Instructions: contents of `.cursor/automations/pr-review-and-repair.prompt.md`
4. Save and activate the automation.

If the editor opens empty, the JSON prefill was dropped. Use the manual checklist above and copy the prompt file into Agent Instructions.

## 2. Issue Implementation

Trigger:

- Webhook from GitHub Actions when an issue has the `agent-implement` label

Behavior:

- Read the issue
- Implement when requirements are clear
- Open a PR and comment on the issue
- Stop with a decision request when human judgment is required

Setup:

1. Open a new automation draft from `.cursor/automations/issue-implementation.json`.
2. Confirm these fields are populated before saving:
   - Repository: `SouichiroTsujimoto/Dialup`
   - Trigger: Webhook
   - Tool: Comment on pull request
   - Instructions: contents of `.cursor/automations/issue-implementation.prompt.md`
3. Save the automation once to generate the webhook URL and API token.
4. Add GitHub repository secrets:
   - `CURSOR_ISSUE_WEBHOOK_URL`: webhook URL from the saved automation
   - `CURSOR_AUTOMATION_TOKEN`: webhook auth token from the saved automation
5. Activate the automation.

The GitHub workflow is already in `.github/workflows/cursor-issue-webhook.yml`.

Note: GitHub only runs issue-triggered workflows from the default branch. Merge the setup PR to `master` before expecting issue webhooks to fire.

After saving the Issue Implementation automation:

Recommended labels:

- `agent-implement`: issue should trigger implementation
- `needs-human`: automation stopped for owner decision
- `agent-touched`: optional marker for automation-created or automation-modified work

Create them once:

```bash
gh label create agent-implement --color 0E8A16 --description "Trigger Cursor issue implementation automation" --force
gh label create needs-human --color B60205 --description "Automation paused for human decision" --force
gh label create agent-touched --color 1D76DB --description "Touched by Cursor automation" --force
```

## Smoke Test

PR automation:

1. Open a test PR against `master`.
2. Confirm the PR automation runs and leaves a structured comment.
3. If CI fails, confirm the agent attempts a fix or leaves a `Needs human decision` note.

Issue automation:

1. Create an issue with the `agent-implement` label.
2. Confirm the GitHub workflow posts to the Cursor webhook.
3. Confirm a branch/PR is created or a decision comment is posted on the issue.

## Human Decision Rules

Automations should stop and ask when the work involves:

- product/spec ambiguity
- auth, billing, secrets, or security policy
- database migrations or persistent data compatibility
- public API or backward compatibility
- destructive deletes or large architectural rewrites
- release, licensing, or compliance decisions
- CI failures with unclear root cause

For this personal project, local and reversible fixes should be applied directly rather than waiting for approval.
