# Codex review on GitHub PRs — agent instructions

Tool-agnostic rules for reading Codex code-review findings and driving the
`@codex review` loop. Paste into your repo's `AGENTS.md`, or point your agent here.

Companion wrapper: `scripts/codex-review.sh` (needs `gh` + `jq`). Use it instead of
composing `gh` calls by hand.

## Rules

1. **Findings arrive on two endpoints. Read both.** Most are *inline review comments*
   (`gh api repos/OWNER/REPO/pulls/N/comments`) — `gh pr view --json comments` carries
   only issue comments, so the bot is simply absent from it. But Codex also files
   findings as issue comments (`gh api repos/OWNER/REPO/issues/N/comments`), same badge
   and severity, anchored by a blob permalink in the body rather than by `path`/`line`:

   ```
   ### 💡 Codex Review

   https://github.com/O/R/blob/cf125d41c7/packages/api/src/routes/auth.ts#L169
   **<sub><sub>![P1 Badge](https://img.shields.io/badge/P1-orange?style=flat)</sub></sub>  Move sign-in keying after body parsing**

   With `@fastify/rate-limit` using its default `onRequest` hook, the POST body has not
   been parsed when ...

   AGENTS.md reference: [AGENTS.md:L327-L335](https://github.com/O/R/blob/cf125d41c7/AGENTS.md#L327-L335)
   ```

   Reading only the review endpoint drops these silently — the wrapper reported CLEAN on
   a PR carrying an open P1 until it learned to read both. Three things about that shape
   are load-bearing, and all three were got wrong first:

   - The **permalink precedes the badge**, and carries the path, the line (`#L169`, or a
     range `#L12-L14` — keep both ends), and the commit the finding was made against.
     That SHA is what `original_commit_id` is for an inline finding; compare it to the
     PR head to decide staleness.
   - The badge sits **inside** the `**...**` and is wrapped in `<sub>`, sometimes doubled,
     sometimes absent. Anchoring the title regex on the wrappers yields `(untitled)`.
   - A **second** blob permalink may follow, pointing at the AGENTS.md rule the finding
     cites. Take the first match — and do not mistake its `#L327-L335` for the location.

2. **Never strip markdown from a finding before reading its severity.** The
   `P1`/`P2`/`P3` level is a badge image at the start of the body:
   `![P2 Badge](https://img.shields.io/badge/P2-yellow?style=flat)`.
   Regex-cleaning "noise" deletes the field your merge decision depends on, and it
   fails silently.

3. **Absence of a review is ambiguous.** With nothing to report, Codex submits **no
   review**. It leaves an *issue* comment instead:

   ```
   Codex Review: Didn't find any major issues. Breezy!
   **Reviewed commit:** `d94a859dde`
   ```

   The sign-off is randomised (`Bravo.`, `Breezy!`, `Keep them coming!`, …) — match the
   stable `Didn't find any major issues`, never the tail. Then compare
   **`Reviewed commit`** against the PR's newest SHA: that hash is what proves which
   commit was cleared. A `+1` reaction also appears but is untimestamped, so it can
   never vouch for a specific commit.

4. **Distinguish live findings from re-anchored ones — and do not trust `commit_id`.**
   GitHub moves old comments onto new line numbers, so resolved findings look current.
   Worse, it drags `commit_id` forward to the newest commit as it re-anchors, so that
   field will tell you a stale finding is about HEAD.

   Read **`original_commit_id`** instead. It never moves, and it matches the
   `Reviewed commit: <sha>` hash that every Codex output carries (the findings review
   body, not only clean verdicts). Treat a finding as live only when:
   - `original_commit_id` is the PR's newest commit, and
   - `line != null` (otherwise the code it referenced is gone).

   Fall back to `created_at` only when nothing names a commit.

5. **Read the whole finding before fixing.** Each comment body carries the rationale
   and, in its final sentence, the change Codex prescribes. `diff_hunk` carries the
   code it is anchored to, ending **at** the commented line. `start_line`..`line` is a
   range, not a single line.

6. **Reproduce a finding before fixing it.** It is a hypothesis about the code, not a
   verdict. If it does not reproduce, report that with evidence instead of applying a
   speculative fix — a wrong fix can bury the real cause. A well-argued rebuttal is a
   legitimate outcome.

7. **Check that the PR is real before acting on its findings.** GitHub diffs a PR
   against its merge base, so a branch whose changes already landed still shows a
   full diff and gets reviewed as new code. `git branch --contains` does not settle
   it — squash-merge rewrites the commit. Compare content:
   `git diff --stat origin/main origin/<branch> -- <paths>`; empty means duplicate.
   The finding can be valid while the PR is not — fix it on a branch off `main`.

8. **Prefer being woken to polling.** `wait` blocks until a verdict lands for the
   newest commit. Run it as a background job and continue other work; its exit is the
   signal. Do not re-run `status` on a timer.

9. **Re-request a review after pushing fixes.** Findings do not clear themselves and a
   push does not notify Codex. Post `@codex review` again, then re-check.

10. **Report severity, location, and reproduction status** to the human. Do not claim a
   PR passed review based on the absence of findings alone.

## Loop

```
status → not reviewed?  → request → wait → status
       → open findings? → reproduce → fix → gates → push → request → status
       → clean?         → merge per your policy
```

## Verifying claims about this behaviour

These rules were measured, not remembered. If you change one, include the command and
its output. Useful probes:

```bash
gh api repos/O/R/pulls/N/comments  -q '[.[] | select(.user.login|startswith("chatgpt-codex-connector"))] | length'
gh api repos/O/R/pulls/N/reviews   -q 'length'
gh api repos/O/R/issues/N/reactions -q '[.[] | "\(.user.login):\(.content)"]'
gh api repos/O/R/pulls/N/commits   -q 'map(.commit.committer.date) | max'
gh api repos/O/R/pulls/N/comments  -q '.[] | "\(.commit_id[0:10]) vs \(.original_commit_id[0:10])"'

# Findings filed as issue comments — invisible to every probe above.
gh api repos/O/R/issues/N/comments -q '[.[] | select(.body | test("!\\[P[0-9] Badge\\]"))] | length'
```

That last probe is how the two-endpoint rule was found. On `1XP-AI/solana-world-soccer-2026`
PR #591 it printed `1` while `pulls/591/comments` held no live finding at all — a P1
(`Move sign-in keying after body parsing`) that the wrapper had been reporting as CLEAN.
