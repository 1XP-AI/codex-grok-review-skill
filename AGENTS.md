# Codex / Grok review on GitHub PRs — agent instructions

Tool-agnostic rules for reading Codex and Grok code-review findings and driving the
`@codex review` loop. Paste into your repo's `AGENTS.md`, or point your agent here.

Companion wrapper: `scripts/codex-grok-review.sh` (needs `gh` + `jq`). Use it instead of
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
   - But it is **optional**, and a parser that requires it is the two-endpoint bug
     again in miniature. `capture` in jq emits nothing on no match, so binding it with
     `as` **deletes the finding** instead of leaving the location blank. Fall back to an
     unlocated finding and let it block the merge. The permalink is a Codex habit; Grok
     is under no obligation to copy it.
   - An unlocated finding needs the **date** fallback that rule 4 gives review comments
     (`created_at < headdate`), or it is live forever: the author fixes the code, pushes,
     and the gate still refuses until somebody deletes the comment. The sha still wins
     where there is one — the date is a watermark, not proof.
   - The badge sits **inside** the `**...**` and is wrapped in `<sub>`, sometimes doubled,
     sometimes absent. Anchoring the title regex on the wrappers yields `(untitled)`.
   - It also appears **ahead of** the bold run — `![P0 Badge](…) **Title**` — and one
     regex does not read both placements. Against that shape `\s*(?<t>[^*\n]+)\*\*`
     cannot start on the `*` it faces, backtracks onto the space before it, and captures
     the space; the title trims to `""`, and an empty string is *truthy* to `//`, so not
     even `(untitled)` survives. Try bold-first, then wrapped, and reject a blank match
     from each.
   - A **second** blob permalink may follow, pointing at the AGENTS.md rule the finding
     cites. Take the first match — and do not mistake its `#L327-L335` for the location.
     "First match" only works once that footer is out of the way, though: on a body with
     **no** code permalink the citation is the first match, so the finding gets located in
     AGENTS.md and dated by the cited commit — not HEAD, so it reads STALE and drops out
     of the gate exactly as being deleted would.
   - Separate them by **position, not by label or filename**: search only the part of the
     body *before the badge*. The code permalink precedes the badge and the citation
     follows the rationale, so the cut is structural. Keying on the `reference:` label was
     measured to fail three ways — a capital `Reference:`, a bare `See [...](...)` with no
     label, and any wording a future template picks. Keying on the filename fails
     differently: the cited file is whatever rules file the repo keeps, and a finding may
     legitimately be *about* `AGENTS.md`. The cost is that a code permalink appearing only
     after the badge is not read as a location either — which leaves an unlocated, live
     finding, the direction that blocks a merge rather than hiding one.

2. **Never strip markdown from a finding before reading its severity.** The
   `P0`–`P4` level is a badge image at the start of the body:
   `![P2 Badge](https://img.shields.io/badge/P2-yellow?style=flat)`.
   Regex-cleaning "noise" deletes the field your merge decision depends on, and it
   fails silently.

3. **Absence of a review is ambiguous.** With nothing to report, Codex submits **no
   review**. It leaves an *issue* comment instead:

   ```
   Codex Review: Didn't find any major issues. Breezy!
   Grok Review: Didn't find any major issues. 🚀
   **Reviewed commit:** `d94a859dde`
   ```

   The sign-off is randomised (`Bravo.`, `Breezy!`, `Keep them coming!`, …) — match the
   stable `Didn't find any major issues`, never the tail. Then compare
   **`Reviewed commit`** against the PR's newest SHA: that hash is what proves which
   commit was cleared. A `+1` reaction also appears but is untimestamped, so it can
   never vouch for a specific commit.

   **Check BOTH endpoints for that verdict.** It lands either as an issue comment or
   as the body of a review object, and reading one of the two reports a cleared PR as
   unreviewed. Measured on PR #4 of this repo: two commits cleared by issue comment,
   two by review body. Merge them, and normalise `submitted_at` against `created_at`
   before taking the latest — otherwise the newest verdict is whichever key happened
   to exist.

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

11. **Two authors, one reader.** Codex posts as `chatgpt-codex-connector[bot]`.
    Grok posts as `1xp-dorami`. Only accept a 1xp-dorami comment when the body has
    `![P0 Badge]`–`![P4 Badge]` or `Didn't find any major issues` — a chat note from
    that login is not a finding. An open badge from either author makes `status`
    exit `2`; a Codex CLEAN must not cover a Grok P2. `status` is `0` only when the
    `REQUIRED_REVIEWERS` policy is met — `codex` (default), `grok`, `codex grok`
    for both, or `either` for one-of. A reviewer that is absent because it is down
    or rate-limited is indistinguishable over the API from one that was never
    installed, so this is configured, not inferred. Keep `@codex review` / `wait`
    Codex-only.

12. **A failure notice is an answer, not silence.** Codex sometimes posts
    `Codex Review: Something went wrong. Try again later by commenting "@codex
    review".` instead of a review. It carries no badge, no clean phrase and no
    review object, so every silence-shaped rule above reads it as "still
    waiting" — which is the one wrong response, since the bot has already asked
    to be re-run. Treat a notice that is Codex's LATEST word (nothing from Codex
    after it — verdicts and review objects both count as words) as its own
    state: report it, exit `5`, and re-request. A notice followed by any later
    Codex word is history. Match the phrase prefix `Codex Review: Something went
    wrong` from the Codex login only — a human quoting it is not a crash.

## Verifying claims about this behaviour

These rules were measured, not remembered. If you change one, include the command and
its output. Useful probes:

```bash
gh api repos/O/R/pulls/N/comments  -q '[.[] | select((.user.login|startswith("chatgpt-codex-connector")) or (.user.login=="1xp-dorami" and (.body|test("!\\[P[0-9] Badge\\]"))))] | length'
gh api repos/O/R/pulls/N/reviews   -q 'length'

# Clean verdicts hide on BOTH endpoints. Reading one calls a cleared PR unreviewed.
gh api repos/O/R/issues/N/comments -q '[.[] | select(.body // "" | test("major issues"))] | length'
gh api repos/O/R/pulls/N/reviews   -q '[.[] | select(.body // "" | test("major issues"))] | length'
gh api repos/O/R/issues/N/reactions -q '[.[] | "\(.user.login):\(.content)"]'
gh api repos/O/R/pulls/N/commits   -q 'map(.commit.committer.date) | max'
gh api repos/O/R/pulls/N/comments  -q '.[] | "\(.commit_id[0:10]) vs \(.original_commit_id[0:10])"'

# Findings filed as issue comments — invisible to every probe above.
gh api repos/O/R/issues/N/comments -q '[.[] | select(.body | test("!\\[P[0-9] Badge\\]"))] | length'
```

That last probe is how the two-endpoint rule was found. On `1XP-AI/solana-world-soccer-2026`
PR #591 it printed `1` while `pulls/591/comments` held no live finding at all — a P1
(`Move sign-in keying after body parsing`) that the wrapper had been reporting as CLEAN.
