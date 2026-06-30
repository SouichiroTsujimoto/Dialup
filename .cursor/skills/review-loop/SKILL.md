---
name: review-loop
description: >-
  Review → fix → re-review in a loop until no actionable Medium+ findings remain,
  without oscillation. Uses the /code-review mindset (bugs, regressions, security,
  missing tests). Works on Cursor iOS, Desktop, and Cloud Agents. Use when the user
  asks for review loop, iterate on review until clean, or fix review findings.
---

# Review Loop

Review → fix → re-review until there are no actionable **Medium+** findings,
**without** falling into an oscillation where fixes undo each other.

This skill replaces the older **bugbot-loop** pattern. It does **not** depend on
`subagent_type: "bugbot"` or `/review-bugbot` (those are not available on all
platforms, e.g. Cursor iOS). The review rubric matches **`/code-review`**:

- Prioritize bugs, behavioral regressions, security issues, and missing tests
- Order findings by severity
- Round 0 is review-only; fixes happen in Round N+

## Parse

Accept `/review-loop [options] [target]`.

| Input | Meaning |
|-------|---------|
| (none) | Review branch changes vs default base (`master` or `main`) |
| `uncommitted` | Review only unstaged + staged changes |
| `PR <n>` or PR URL | Review that pull request's head branch vs base |
| `branch <name>` | Review named branch vs base |

When the target is a PR (explicit `PR <n>` or the current branch has an open PR),
record the PR number at loop start and **post a comment after every round** (see
**PR comments** below). If no PR exists yet, skip PR comments and note that in the
final chat summary.

## Review Rubric (same as /code-review)

Apply on every round:

1. **Bugs** — logic errors, nil handling, stale state, race conditions
2. **Behavioral regressions** — breaking changes, routing/shadowing, UX regressions
3. **Security** — validation gaps, atom table pressure, auth bypass
4. **Missing tests** — real failure modes without coverage

For each finding record:

- **Severity:** Critical / High / Medium / Low / Informational
- **Location:** `file:line-range`
- **Category:** short keyword (e.g. `null-check`, `stale-state`)
- **Description:** what is wrong and suggested fix

## Core Mechanism: Finding Ledger

Maintain an in-memory **finding ledger** across rounds. Fingerprint each finding as
`severity | file:line-range | category-keyword`.

Track per finding:

- `round_introduced`
- `round_resolved` (nil if open)
- `status`: `open`, `fixed`, `wont_fix`, `reappeared`

## Workflow

### Round 0 — Baseline (review only)

1. Determine diff scope (see **Gather diff** below).
2. If target is a PR, resolve PR number (`gh pr view --json number` on the head
   branch) and keep it for the whole loop.
3. Review using the **Review Rubric**. Do **not** edit code in Round 0 unless the
   user explicitly asked to fix in the same turn.
4. Parse findings into the ledger.
5. Print **Round 0 Summary** (format below).
6. **Post Round 0 Summary to the PR** when a PR is in scope (see **PR comments**).
7. If zero Medium+ findings: report clean and stop (Low/Info may be listed as
   `wont_fix` or noted once).

### Round N — Fix & Re-review

1. **Pre-flight** — Before fixing:
   - Any `status: reappeared` → **oscillation**. Stop immediately.
   - Previous round fixed fewer than it introduced new Medium+ → **divergence**. Stop.
2. **Filter** — Auto-fix: Medium+. Mark Low/Informational as `wont_fix`.
3. **Fix** — Narrow diffs; touch only flagged lines.
4. **Verify** — Run project tests (`MIX_ENV=test mix test` at repo root, or the
   smallest relevant subset).
5. **Commit** — Message: `Fix review loop round N findings`
6. **Re-review** — Same rubric on updated diff.
7. **Reconcile** ledger (fixed → reappeared = oscillation signal).
8. Print **Round N Summary**.
9. **Post Round N Summary to the PR** when a PR is in scope (see **PR comments**).
10. All `fixed` or `wont_fix` → done. Else Round N+1.

### Stopping Conditions

| Condition | Action |
|-----------|--------|
| Zero open Medium+ | Success |
| Oscillation (`reappeared`) | Stop; ask user which version to keep |
| Divergence | Stop; ask continue or revert |
| Test failure after fix | Stop; do not re-review broken code |

No arbitrary round cap — ledger checks are the halting mechanism.

## Gather Diff

```bash
# Branch vs base (default)
git fetch origin
git diff origin/master...HEAD
# or origin/main...HEAD if main is default

# Uncommitted only
git diff && git diff --cached

# Specific PR
gh pr diff <n>
```

Read changed files as needed; do not review from diff hunks alone when logic spans files.

## Review Execution by Platform

### Cursor iOS / Desktop (no Task subagent)

Run Round 0 yourself using the **Review Rubric** — same instructions as invoking
`/code-review` on the gathered diff. Proceed to fix rounds only when the user
wants the full loop or said "fix findings".

### Cloud Agent (Task tool available)

Optional parallel gather (readonly):

- `subagent_type: "explore"` — locate related files and call sites
- Parent agent still applies the **Review Rubric** for findings (do not delegate
  severity judgments to explore alone)

Optional deep pass for large diffs:

- `subagent_type: "thermo-nuclear-code-quality-review"` with diff + file contents
  in the prompt (maintainability; merge with code-review findings, dedupe)

There is **no** `subagent_type: "bugbot"`. Do not reference bugbot-loop or
review-bugbot subagents.

## Round Summary Format

Use this format in chat **and** in PR comments.

```
## Review Loop — Round N

**Target:** PR #26 (or branch name)
**Verdict:** CLEAN | N Medium+ remaining | STOPPED (reason)

| # | Severity | Location | Finding | Status |
|---|----------|----------|---------|--------|
| 1 | High     | lib/foo.ex:42 | Missing null check | fixed |
| 2 | Medium   | lib/bar.ex:10 | Unused variable   | open  |

Resolved: 3 | New: 1 | Reappeared: 0 | Remaining: 2
Delta: -2 (net reduction from previous round)
```

Round 0 uses `Verdict: N Medium+ remaining` or `CLEAN`. Fix rounds add commits
under **Fixed this round** when applicable:

```
### Fixed this round
- `abc1234` — short description of fixes (Round N only)
```

When the loop stops early (oscillation, divergence, test failure), set
`Verdict: STOPPED (...)` and include **Recommended next step**.

## PR Comments

**Required:** after printing each round summary, post the same content to the PR.

1. Resolve PR number once at loop start:
   ```bash
   gh pr view --json number,url --jq '.number'
   # or use the number from `PR <n>` in the user prompt
   ```
2. Post after **every** round (0, 1, 2, …), including the final round:
   ```bash
   gh pr comment <number> --body "$(cat <<'EOF'
   ## Review Loop — Round N
   ...
   EOF
   )"
   ```
3. One comment per round — do **not** edit previous round comments; the PR thread
   is an append-only audit trail.
4. If `gh pr comment` fails (permissions, no PR), retry once, then report the
   failure in chat and continue the loop locally.
5. Branch-only reviews (no open PR): skip PR comments; mention in chat only.

Cloud Agents should post comments **before** starting the next fix round or
before giving the final chat summary.

## Anti-Oscillation Rules

1. Never re-apply a fix that was reverted because it reappeared — escalate.
2. Scope fixes narrowly; no drive-by refactors.
3. Low-severity style issues: `wont_fix` once; never trigger another round.
4. Commit between rounds (`git revert HEAD` undoes last round).
5. One fix strategy per finding; if X failed and reappeared, do not try Y automatically.

## Output (when loop ends)

1. Final ledger table (all findings, final status)
2. Total rounds run
3. If stopped: reason and recommended next step
4. Commits created (for easy revert)
5. Link to PR comment thread when comments were posted (`gh pr view <n> --json url`)

## Relation to GitHub Bugbot

- **This skill** — interactive review/fix loop in Agent (iOS, Desktop, Cloud)
- **GitHub Bugbot** — PR comments on push; enable in Cursor dashboard
- **/review-bugbot** — Desktop 3.7+ pre-push skill; optional, not required here

Use review-loop before opening a PR; use GitHub Bugbot after the PR exists.
