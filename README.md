# codex-review-skill

Read **Codex** code-review findings on GitHub pull requests correctly, and drive the
`@codex review` re-review loop — from Claude Code, Codex CLI, or any coding agent.

The obvious `gh` commands **silently omit findings or throw away their severity**.
Every behaviour documented here was measured against real PRs, not recalled from
memory.

---

## The four traps

### 1. `gh pr view --json comments` does not contain review findings

Codex posts its findings as **inline review comments**, which live on a different
endpoint from issue comments.

```bash
gh pr view 123 --json comments -q '[.comments[].author.login] | unique'
# ["someuser","vercel"]      ← the Codex bot is absent
```

The human-readable `gh pr view 123 --comments` *does* render them, but as
unstructured text — you cannot reliably read severity or staleness out of it.

The reliable source is:

```bash
gh api repos/OWNER/REPO/pulls/123/comments
```

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

### 4. Old findings are re-anchored and look current

GitHub keeps review comments attached to a PR as it changes, moving them to new line
numbers. A finding you already fixed reappears pointing at a plausible-looking line.

Two fields separate live findings from dead ones:

| Field | Meaning |
|---|---|
| `line == null` | GitHub could no longer anchor it — the code it referenced is gone |
| `created_at` earlier than the newest commit | It predates your fix; likely already addressed |

Compare `created_at` against the newest commit date, not against "now".

---

## Install

Requires [`gh`](https://cli.github.com/) (authenticated) and [`jq`](https://jqlang.github.io/jq/).

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
codex-review findings 123    # open findings only, with severity
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

[P2] src/styles/app.css:2542  (STALE — predates newest commit)  (OUTDATED — code removed)
      Hide the backdrop when no menu remains visible
      https://github.com/owner/repo/pull/545#discussion_r...
```

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
the command you ran and its output. Bot login is matched by the `chatgpt-codex-connector`
prefix; override with the `BOT` variable in the script if your installation differs.
