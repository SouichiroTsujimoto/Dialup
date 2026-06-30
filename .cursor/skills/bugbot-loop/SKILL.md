---
name: bugbot-loop
description: >-
  Run Bugbot review, fix findings, and re-review in a loop until clean or
  oscillation is detected. Use when the user asks to loop bugbot, fix all
  bugbot findings, or iterate on review until green.
---

# Bugbot Loop

Review → fix → re-review until Bugbot reports no actionable findings,
**without** falling into an oscillation where fixes undo each other.

## Parse

Accept `/bugbot-loop [options]`.

- No arguments: default behavior (Medium+ auto-fix, branch changes).
- `uncommitted`: review only uncommitted changes.

## Core Mechanism: Finding Ledger

Maintain an in-memory **finding ledger** across rounds. Each finding is
fingerprinted as `severity | file:line-range | category-keyword` (e.g.
`High | lib/server.ex:120-125 | null-check`). The ledger tracks:

- `round_introduced`: which round first surfaced the finding
- `round_resolved`: which round the fix was applied (nil if still open)
- `status`: `open`, `fixed`, `wont_fix`, **`reappeared`**

## Workflow

### Round 0 — Baseline

1. Launch Bugbot subagent (`review-bugbot` skill rules) against the current branch.
2. Parse findings into the ledger. Record each fingerprint.
3. Print **Round 0 Summary** (see format below).
4. If zero findings: done. Report clean and stop.

### Round N — Fix & Re-review

1. **Pre-flight check** — Before fixing, review the ledger:
   - If any finding has `status: reappeared` → **oscillation**. Stop immediately.
   - If the previous round's fix produced **more** new findings than it resolved
     → **divergence**. Stop immediately.
2. **Filter** — Select findings to auto-fix:
   - Severity Medium or above → fix.
   - Severity Low / informational → mark `wont_fix`, report only.
3. **Fix** — Apply fixes for the selected findings. After all fixes:
   - Run `mix test` (or the project's test command) to verify no regressions.
   - Commit the fixes with message: `Fix Bugbot round N findings`.
4. **Re-review** — Launch Bugbot again.
5. **Reconcile** — Compare new findings against the ledger:
   - Finding fingerprint matches a `fixed` entry → set `status: reappeared`. 
     This is the **oscillation signal**.
   - Finding fingerprint is new (not in ledger) → add with `round_introduced: N`.
   - Previous finding not in new results → confirm `status: fixed`.
6. Print **Round N Summary**.
7. If all findings are `fixed` or `wont_fix`: done. Report clean.
8. Otherwise: go to Round N+1.

### Stopping Conditions

| Condition | Action |
|-----------|--------|
| Zero open findings | Report success |
| Oscillation (`reappeared`) | Stop. Print which findings are cycling. Ask the user to choose which version to keep. |
| Divergence (fixes create more issues than they solve) | Stop. Print the net-negative delta. Ask the user whether to continue or revert. |
| Test failure after fix | Stop. Do not re-review broken code. Print the failure and let the user decide. |

There is **no arbitrary round cap**. The ledger-based checks are the halting mechanism.

## Round Summary Format

Print after every round:

```
## Round N Summary

| # | Severity | Location | Finding | Status |
|---|----------|----------|---------|--------|
| 1 | High     | lib/foo.ex:42 | Missing null check | fixed |
| 2 | Medium   | lib/bar.ex:10 | Unused variable   | open  |

Resolved: 3 | New: 1 | Reappeared: 0 | Remaining: 2
Delta: -2 (net reduction from previous round)
```

This summary is the agent's self-check. Writing it forces comparison against
the ledger before proceeding.

## Anti-Oscillation Rules

These rules address the specific failure modes observed in practice:

1. **Never fix a finding whose fix was already reverted.** If A was fixed in
   round 1 and reappeared in round 2, the fix for A conflicts with something
   else. Escalate to the user.

2. **Scope fixes narrowly.** Each fix should touch only the lines Bugbot
   flagged. Do not refactor surrounding code. Smaller diffs produce fewer
   surprise findings.

3. **Do not chase cosmetic findings in a loop.** Low-severity style issues
   are reported once and marked `wont_fix`. They never trigger another round.

4. **Commit between rounds.** Each fix round gets its own commit. If
   oscillation is detected, `git revert HEAD` cleanly undoes the last round.

5. **One fix strategy per finding.** If the agent already tried approach X
   for a finding and it reappeared, do not try a different approach Y
   automatically. Report both approaches and let the user decide.

## Bugbot Subagent Invocation

Follow the `review-bugbot` skill for launching the subagent. Key points:

- `subagent_type: "bugbot"`, `readonly: true`, `run_in_background: false`
- Prompt: `Full Repository Path: <path>\nDiff: branch changes`
- On empty diff or subagent failure, follow the retry rules in `review-bugbot`.

## Output

When the loop terminates (success or stopped):

1. Final ledger table (all findings across all rounds, with final status).
2. Total rounds run.
3. If stopped: the specific reason and recommended next step.
4. List of commits created (for easy revert if needed).
