---
name: codex-review
description: Read Codex and Grok code-review findings on a GitHub pull request, and drive the @codex review re-review loop. Use whenever you need to check whether Codex or Grok reviewed a PR, read its findings with their P0–P4 severity, decide if a PR is clear to merge, or request a re-review after pushing fixes. The obvious `gh` commands silently omit findings and drop severity — always use this skill instead of hand-rolling `gh pr view`.
---

# Codex / Grok review on GitHub PRs

Codex and Grok post findings as **inline review comments** with severity badges. Reading them
naïvely loses information in four ways. Use `scripts/codex-review.sh` rather than
composing `gh` calls yourself.

## Quick reference

```bash
scripts/codex-review.sh status <pr>     # verdict + counts (exit code encodes it)
scripts/codex-review.sh findings <pr>   # open findings, one line each
scripts/codex-review.sh detail <pr>     # why / what to fix / the code, per finding
scripts/codex-review.sh all <pr>        # incl. stale/outdated
scripts/codex-review.sh json <pr>       # machine-readable
scripts/codex-review.sh request <pr>    # post "@codex review"
scripts/codex-review.sh wait <pr>       # block until a review lands
```

Add `--repo OWNER/REPO` when outside a checkout.

Needs `gh` 2.44+ (for `api --slurp`); an older one is refused with a message.

Exit codes for `status` / `findings` — the same codes from both, decided in one
place so they cannot drift (`findings` used to print open findings and exit `0`):
`0` reviewed & clean · `2` open findings · `3` not reviewed yet · `4` findings all stale.

## What goes wrong without this

1. **Findings live on two endpoints, and `gh pr view --json comments` shows neither
   completely.** Most are inline review comments (`gh api repos/O/R/pulls/N/comments`),
   but Codex also posts findings as plain issue comments
   (`gh api repos/O/R/issues/N/comments`) — same badge, same severity, but anchored by
   a blob permalink in the body instead of by `path`/`line`. Reading only the review
   endpoint silently drops those; a P1 sat unread on PR #591 that way. The wrapper reads
   both and normalises them into one list.
2. **Severity is a markdown image badge.** Stripping "markdown noise" deletes the
   `P0`–`P4` you need to decide whether to merge — and it fails silently.
3. **No findings ⇒ no review object.** The verdict is an *issue* comment:
   `Codex Review: Didn't find any major issues. <random sign-off>` or
   `Grok Review: Didn't find any major issues. 🚀`, plus
   **`Reviewed commit: <sha>`**. Never match the sign-off (it varies); match
   `Didn't find any major issues`, then check that the SHA is the PR's newest commit —
   an older clean verdict does not vouch for code pushed since. Grok posts as
   `1xp-dorami`; a comment from that login that is not a badge or this phrase is noise.
4. **Old findings get re-anchored, and `commit_id` lies about it.** GitHub drags
   `commit_id` forward to the newest commit when it re-anchors a comment, so a stale
   finding reports HEAD. Use **`original_commit_id`** — it never moves and matches the
   `Reviewed commit: <sha>` hash in the parent review's body. A finding is live only
   when `original_commit_id` is the PR's newest commit **and** `line != null`.
   An issue-comment finding has no `original_commit_id`; its permalink SHA plays that
   role, and it never goes `line == null` because nothing re-anchors it.
5. **Two authors, one reader.** Codex is `chatgpt-codex-connector[bot]`. Grok is
   `1xp-dorami`, and only when the body has `![P0 Badge]`–`![P4 Badge]` or
   `Didn't find any major issues`. An open badge from either author makes `status`
   exit `2` — a Codex CLEAN does not cover a Grok P2. `@codex review` / `wait` /
   `request` stay Codex-only.

## Procedure

1. **Check status first.** `status <pr>`. Exit `3` means nobody has reviewed — request
   one rather than waiting.
2. **Read open findings.** `detail <pr>` gives, per finding, the rationale (WHY), the
   change Codex prescribes (FIX), and the anchored code (CODE) — enough to start
   editing without opening the browser. `findings <pr>` is the one-line list; use
   `all <pr>` / `detail-all <pr>` to confirm an older finding was in fact addressed.
3. **Reproduce each finding before fixing it.** A finding is a hypothesis about the
   code, not a verdict. If you cannot reproduce it, report that with evidence — a
   well-argued rebuttal is a legitimate outcome, and "fixing" a phantom can mask the
   real cause.
4. **Fix, run the repo's own gates, push.**
5. **Re-request, then let it wake you.** `request <pr>`, and run `wait <pr>` as a
   **background** job rather than polling `status` — its exit is the signal that a
   verdict landed. Tune with `CODEX_REVIEW_TIMEOUT` / `CODEX_REVIEW_INTERVAL`. Findings do not clear themselves and a push does not
   notify Codex.
6. **Re-check before merging.** `status <pr>` again. If your merge policy is
   "no P1 blocks", gate on severity:

   ```bash
   scripts/codex-review.sh json <pr> \
     | jq '[.[] | select(.stale==false and .anchored==true and .severity=="P1")] | length'
   ```

## Before acting on findings, check the PR is real

GitHub diffs a PR against its **merge base**, so a branch whose changes already landed
(squash-merged, cherry-picked) still shows a full diff and Codex reviews it as new
code. `git branch --contains` does not settle it — squash-merge rewrites the commit.
Compare content: `git diff --stat origin/main origin/<branch> -- <paths>`. Empty means
duplicate — close it. The finding may still be valid against `main`; fix it on a fresh
branch.

## Reporting findings to a human

State each finding's **severity, file:line, and whether you reproduced it**. Never
report "review passed" from the absence of a review object alone — say whether you saw
a 👍, and whether it postdates your newest commit (reactions are untimestamped, so an
old 👍 does not vouch for new commits).
