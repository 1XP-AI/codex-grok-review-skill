---
name: codex-review
description: Read Codex code-review findings on a GitHub pull request, and drive the @codex review re-review loop. Use whenever you need to check whether Codex reviewed a PR, read its findings with their P1/P2/P3 severity, decide if a PR is clear to merge, or request a re-review after pushing fixes. The obvious `gh` commands silently omit findings and drop severity — always use this skill instead of hand-rolling `gh pr view`.
---

# Codex review on GitHub PRs

Codex posts findings as **inline review comments** with severity badges. Reading them
naïvely loses information in four ways. Use `scripts/codex-review.sh` rather than
composing `gh` calls yourself.

## Quick reference

```bash
scripts/codex-review.sh status <pr>     # verdict + counts (exit code encodes it)
scripts/codex-review.sh findings <pr>   # open findings, with severity
scripts/codex-review.sh all <pr>        # incl. stale/outdated
scripts/codex-review.sh json <pr>       # machine-readable
scripts/codex-review.sh request <pr>    # post "@codex review"
scripts/codex-review.sh wait <pr>       # block until a review lands
```

Add `--repo OWNER/REPO` when outside a checkout.

Exit codes for `status` / `findings`:
`0` reviewed & clean · `2` open findings · `3` not reviewed yet · `4` findings all stale.

## What goes wrong without this

1. **`gh pr view --json comments` omits findings entirely.** They are review comments,
   not issue comments. Correct source: `gh api repos/O/R/pulls/N/comments`.
2. **Severity is a markdown image badge.** Stripping "markdown noise" deletes the
   `P1`/`P2`/`P3` you need to decide whether to merge — and it fails silently.
3. **No findings ⇒ no review object.** The verdict is an *issue* comment:
   `Codex Review: Didn't find any major issues. <random sign-off>` plus
   **`Reviewed commit: <sha>`**. Never match the sign-off (it varies); match
   `Didn't find any major issues`, then check that the SHA is the PR's newest commit —
   an older clean verdict does not vouch for code pushed since.
4. **Old findings get re-anchored to new line numbers** and look current. A finding is
   live only when `line != null` **and** its `created_at` is newer than the PR's newest
   commit.

## Procedure

1. **Check status first.** `status <pr>`. Exit `3` means nobody has reviewed — request
   one rather than waiting.
2. **Read open findings.** `findings <pr>`. Use `all <pr>` when you need to confirm an
   older finding was in fact addressed.
3. **Reproduce each finding before fixing it.** A finding is a hypothesis about the
   code, not a verdict. If you cannot reproduce it, report that with evidence — a
   well-argued rebuttal is a legitimate outcome, and "fixing" a phantom can mask the
   real cause.
4. **Fix, run the repo's own gates, push.**
5. **Re-request.** `request <pr>`. Findings do not clear themselves and a push does not
   notify Codex.
6. **Re-check before merging.** `status <pr>` again. If your merge policy is
   "no P1 blocks", gate on severity:

   ```bash
   scripts/codex-review.sh json <pr> \
     | jq '[.[] | select(.stale==false and .anchored==true and .severity=="P1")] | length'
   ```

## Reporting findings to a human

State each finding's **severity, file:line, and whether you reproduced it**. Never
report "review passed" from the absence of a review object alone — say whether you saw
a 👍, and whether it postdates your newest commit (reactions are untimestamped, so an
old 👍 does not vouch for new commits).
