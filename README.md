# codex-review-skill

Read **Codex** and **Grok** code-review findings on GitHub pull requests correctly, and drive the
`@codex review` re-review loop — from Claude Code, Codex CLI, or any coding agent.

The obvious `gh` commands **silently omit findings or throw away their severity**.
Every behaviour documented here was measured against real PRs, not recalled from
memory.

---

## The five traps

### 1. `gh pr view --json comments` does not contain review findings

Codex posts its findings as **inline review comments**, which live on a different
endpoint from issue comments.

```bash
gh pr view 123 --json comments -q '[.comments[].author.login] | unique'
# ["someuser","some-ci-bot"]   ← the Codex bot is absent
```

The human-readable `gh pr view 123 --comments` *does* render them, but as
unstructured text — you cannot reliably read severity or staleness out of it.

The reliable source is:

```bash
gh api repos/OWNER/REPO/pulls/123/comments
```

**And that endpoint is not the whole story either.** Codex also files findings as plain
issue comments — same badge, same severity, but located by a blob permalink in the body
instead of by `path`/`line`:

```bash
gh api repos/OWNER/REPO/issues/123/comments \
  -q '[.[] | select(.body | test("!\\[P[0-9] Badge\\]"))] | length'
# 1   ← a P1 that pulls/123/comments never mentions
```

That is not hypothetical: it is how this wrapper came to report `CLEAN` on a PR with an
open P1. Both endpoints have to be read and merged, which is what the wrapper does.

### 2. Severity is a markdown image badge — easy to strip by accident

Each finding opens with:

```markdown
**<sub><sub>![P2 Badge](https://img.shields.io/badge/P2-yellow?style=flat)</sub></sub>  Make the dropdown scroll…**
```

Cleaning "markdown noise" with something like
`sed 's|!\[P[0-9] Badge\]([^)]*)||g'` deletes **the severity itself**. If your merge
rule is "no P1 findings", stripping the badge makes that rule unenforceable — and it
fails silently, because the text still reads fine.

### 3. No findings ⇒ **no review object at all** — the verdict is an issue comment

When Codex has nothing to say it does **not** submit a review. It leaves an *issue*
comment and reacts `+1`:

```bash
gh api repos/OWNER/REPO/pulls/123/reviews -q 'length'   # 0  ← looks unreviewed
```

```
Codex Review: Didn't find any major issues. Breezy!

**Reviewed commit:** `d94a859dde`
```

Grok uses the same two fixed fields, as an issue comment, posted as `1xp-dorami`:

```
Grok Review: Didn't find any major issues. 🚀

**Reviewed commit:** `d94a859dde`
```

A random `1xp-dorami` comment is **not** a review. Require `![P0 Badge]`–`![P4 Badge]`
or `Didn't find any major issues`. An open badge from either author makes `status`
exit `2` — a Codex CLEAN does not cover a Grok P2.

So **"zero reviews" is ambiguous** — it means either *not reviewed yet* or *reviewed
and clean*. Miss this and you either wait forever for a review that will never come,
or merge something Codex never looked at.

Two things about that comment matter:

- **The sign-off is randomised.** Observed: `Bravo.` · `Breezy!` ·
  `Keep them coming!` · `What shall we delve into next?` — matching on it will break.
  Match the stable part: `Didn't find any major issues`.
- **`Reviewed commit` names the exact SHA.** This is the single most valuable field on
  a clean verdict: it proves *which* commit was cleared. A 👍 reaction carries no
  timestamp and cannot. Always compare that SHA against the PR's newest commit —
  otherwise an old clean verdict silently vouches for code Codex never saw.

```bash
gh api repos/OWNER/REPO/issues/123/comments \
  -q '.[] | select(.user.login|startswith("chatgpt-codex-connector"))
          | select(.body | test("[Dd]idn'"'"'t find any major issues"))
          | .body' | head -3
```

### 4. Old findings are re-anchored — and `commit_id` lies about it

GitHub keeps review comments attached to a PR as it changes, moving them onto new
line numbers. A finding you already fixed reappears pointing at a plausible line.

The obvious field to check is `commit_id`. **It is the wrong one.** GitHub drags it
forward when it re-anchors a comment, so a finding written against an old commit
reports the newest one:

```bash
# a review whose body says it inspected 6b8109667e
gh api repos/OWNER/REPO/pulls/123/comments \
  -q '.[] | "commit_id=\(.commit_id[0:10])  original_commit_id=\(.original_commit_id[0:10])"'
# commit_id=b28ef03af2  original_commit_id=6b8109667e   ← .commit_id moved. It is now the HEAD sha.
# commit_id=b28ef03af2  original_commit_id=6b8109667e
```

Use **`original_commit_id`** — it never moves, and across every PR measured it equals
the `Reviewed commit` hash in the parent review's body. It is an API contract rather
than a markdown format, so prefer it over parsing the body.

For reference, the body does state it too, on *every* Codex output — the findings
review, not just clean verdicts:

```
### 💡 Codex Review
Here are some automated review suggestions for this pull request.

**Reviewed commit:** `6b8109667e`
```

A finding is **live** only when both hold:

| Condition | Why |
|---|---|
| `original_commit_id` is the PR's newest commit | otherwise it was written against code you have since changed |
| `line != null` | otherwise GitHub could no longer place it — the code is gone |

Timestamps are a last resort, for outputs that name no commit at all.

### 5. A PR's diff is against the merge base, not against `main`

Not a Codex behaviour, but it decides whether a finding is worth acting on. GitHub
computes a PR's diff from where the branch forked. A branch whose changes already
landed — squash-merged, cherry-picked — still shows a full diff, and Codex will
review it as new code.

Ancestry does not settle it, because squash-merge rewrites the commit:

```bash
git branch -r --contains <sha>     # main absent — proves nothing after a squash merge
```

Compare content instead:

```bash
git diff --stat origin/main origin/<branch> -- <paths the PR touches>
# empty → already on main; the PR is a duplicate no matter what its diff shows
```

Worth doing before you spend time on findings: the finding may be real while the PR
is not.

---

## Reading a finding fast

A finding is three things: **why it is a bug**, **what to change**, and **where**.
`detail` extracts all three, so you can start editing without opening the browser.

```
$ codex-review detail 123
────────────────────────────────────────────────────────────────────────
[P2]  src/components/TopNav.tsx:316-317
       Make the dropdown scroll within short viewports

  WHY  When the actions are appended after the 7–9 navigation links, the
       dropdown can exceed the available height on landscape phones and
       other short viewports. The absolutely positioned `.nav__links` has
       neither a viewport-relative `max-height` nor vertical scrolling.

  FIX  constrain the dropdown to the space below the 64px header and
       enable `overflow-y: auto`.

  CODE
        …
             </li>
           ))}
    »» +    {isRandomWallet && (

  LINK https://github.com/owner/repo/pull/123#discussion_r...
```

- **WHY** — the rationale, with the badge markup and the `Useful?` footer removed.
- **FIX** — Codex states the prescription in its final sentence, after a `;` or a
  `, so` when that sentence also diagnoses the cause. Extracted heuristically, and
  printed *next to* the full rationale so a bad guess is visible and harmless.
- **CODE** — the `diff_hunk` GitHub attaches to the comment. The hunk **ends at** the
  commented line, so the tail is the relevant part; `»»` marks the anchor line.
- Findings are grouped by file and ordered by line, so each file is opened once.

Set `CODEX_REVIEW_CONTEXT` to change how many lines of code context are shown.

---

## Install

Requires [`gh`](https://cli.github.com/) **2.44 or newer** (authenticated) and
[`jq`](https://jqlang.github.io/jq/). The version floor is `gh api --slurp`, which is how
every page of a long PR's comments gets merged before being filtered — without it the
counts come back one-per-page and the verdict is unreadable. An older `gh` is refused
with a message rather than quietly reporting no findings.

Check yours with `gh --version`.

```bash
git clone https://github.com/1XP-AI/codex-review-skill.git
install -m 0755 codex-review-skill/scripts/codex-review.sh /usr/local/bin/codex-review
```

Or run it in place: `./scripts/codex-review.sh status 123`

### Claude Code

Copy the skill so Claude loads it on demand:

```bash
mkdir -p ~/.claude/skills/codex-review
cp codex-review-skill/SKILL.md ~/.claude/skills/codex-review/
cp -r codex-review-skill/scripts ~/.claude/skills/codex-review/
```

Project-scoped instead: use `.claude/skills/codex-review/` inside the repo.

### Codex CLI / other agents

Append [`AGENTS.md`](AGENTS.md) to your repo's `AGENTS.md`, or point your agent at
this README. The rules are tool-agnostic; only the wrapper is bash.

---

## Usage

```bash
codex-review status 123      # one-line verdict + counts
codex-review findings 123    # open findings only, one line each
codex-review detail 123      # open findings in full: why, what to fix, the code
codex-review detail-all 123  # same, including stale ones
codex-review all 123         # everything, incl. stale/outdated
codex-review json 123        # machine-readable, for agents
codex-review request 123     # post "@codex review"
codex-review wait 123        # block until a review lands after your newest commit
```

Add `--repo OWNER/REPO` outside a checkout.

### Exit codes

`status` and `findings` encode the verdict, so you can gate on them:

| Code | Meaning |
|---:|---|
| 0 | Reviewed, no open findings |
| 2 | Open findings exist |
| 3 | Not reviewed yet, **or** the clean verdict names an older commit |
| 4 | Reviewed; all findings stale/outdated — confirm they were addressed |

```bash
codex-review status 123 || echo "not clear to merge"
```

### Gate on severity

```bash
# Block only on P1, matching a "no P1 blocks the merge" policy
p1=$(codex-review json 123 \
     | jq '[.[] | select(.stale==false and .anchored==true and .severity=="P1")] | length')
[ "$p1" -eq 0 ] || { echo "P1 findings present"; exit 1; }
```

### Sample output

```
$ codex-review status 545
PR #545  (owner/repo)
  newest commit : 2026-08-06T04:44:48Z  b28ef03af2
  codex reviews : 2  (latest 2026-08-06T04:50:57Z)
  codex 👍       : 0
  clean verdict : none
  open findings : 1  (P1: 0)
  VERDICT       : 1 OPEN FINDING(S) — address before merging.

$ codex-review status 549
PR #549  (owner/repo)
  newest commit : 2026-08-06T05:17:05Z  63eef57b93
  codex reviews : 0
  codex 👍       : 1
  clean verdict : yes — reviewed commit 63eef57b93  (2026-08-06T05:19:57Z)
  open findings : 0  (P1: 0)
  VERDICT       : REVIEWED, CLEAN — verdict names the newest commit.

$ codex-review all 545
[P2] src/components/ConfirmDialog.tsx:68
      Restore focus to a control that survives the state change
      https://github.com/owner/repo/pull/545#discussion_r...

[P2] src/styles/app.css:2542  (STALE — reviewed 6b8109667e)  (OUTDATED — code removed)
      Hide the backdrop when no menu remains visible
      https://github.com/owner/repo/pull/545#discussion_r...
```

The stale note names the commit that finding was written against, so you can see at a
glance that it predates the fix you pushed. When an output carried no hash, it falls
back to `(STALE — predates newest commit)`.

---

## Don't poll — get woken up

`wait` blocks until a verdict lands for your newest commit. Backgrounded, that turns
a review into a **push**: an agent that starts it goes on to other work and is
re-invoked the moment the review arrives, instead of re-checking on a timer.

```bash
codex-review request 123
CODEX_REVIEW_TIMEOUT=2400 CODEX_REVIEW_INTERVAL=45 codex-review wait 123 &
# … keep working. The exit wakes whatever is watching the job.
```

In Claude Code, run `wait` as a background Bash task — completion notifies the agent.
Tunables: `CODEX_REVIEW_TIMEOUT` (default 1800s) and `CODEX_REVIEW_INTERVAL`
(default 60s). `wait` succeeds on a clean verdict naming your head commit **or** on a
review submitted after it, so it fires for both outcomes; call `status` afterwards to
find out which.

---

## The review loop

```
open PR  →  codex-review status
                │
    ┌───────────┴───────────┐
  exit 3                  exit 2
"not reviewed"        "open findings"
    │                       │
codex-review request    reproduce each finding first
    │                   fix → push
codex-review wait           │
    └───────────┬───────────┘
                ▼
         codex-review status  →  exit 0 / 4  →  merge
```

**Reproduce before you fix.** A review finding is a hypothesis about your code, not a
verdict. Confirm it, and if you cannot, say so with evidence — a well-argued rebuttal
is a legitimate outcome.

**Re-request after pushing.** Findings do not clear themselves; a fix push does not
notify Codex. Run `codex-review request` again.

---

## Triggers

Codex reviews a PR when you:

- open it for review,
- mark a draft as ready, or
- comment `@codex review`.

`codex-review request` posts that comment for you.

---

## Contributing

Behaviour here is measured, not assumed. If you change a documented claim, include
the command you ran and its output. Reviewer logins: `chatgpt-codex-connector*` (Codex)
and `1xp-dorami` (Grok, only when the body looks like a review). `@codex review` /
`wait` / `request` stay Codex-only. Severity badges are `P0`–`P4`.
