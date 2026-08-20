#!/usr/bin/env bash
#
# The failure-notice extractor.
#
# "Codex Review: Something went wrong. Try again later by commenting
# '@codex review'." is a crash posted where a review pass should have been, and
# it matches NOTHING this script otherwise reads — no badge, no clean phrase, no
# review object. Before codex_errors existed, `status` answered "awaiting:
# codex" and `wait` slept out its full timeout on a bot that had already said it
# would not answer (observed on solana-world-soccer-2026#688).
#
# The extractor is sourced out of the real script — a copy would drift. api_all
# is stubbed so the fixtures below play the two endpoints.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$here/codex-grok-review.sh"
[ -f "$src" ] || { echo "cannot find codex-grok-review.sh next to this script" >&2; exit 1; }

# Login defaults + the jq lib builder, straight from the script.
eval "$(awk '/^CODEX_LOGIN=/{p=1} p{print} /^JQ_REVIEWER_LIB=/{exit}' "$src")"
JQ_REVIEWER_LIB="$(jq_reviewer_lib)"
[ -n "${JQ_REVIEWER_LIB:-}" ] || { echo "JQ_REVIEWER_LIB not extracted" >&2; exit 1; }

for name in codex_errors latest_codex_word_date live_codex_error_at review_shas; do
  fn="$(sed -n "/^${name}() {/,/^}/p" "$src")"
  [ -n "$fn" ] || { echo "$name not found in $src — was it renamed?" >&2; exit 1; }
  eval "$fn"
done

pass=0; fail=0
check() {
  local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    printf '  ok   %-52s [%s]\n' "$name" "$got"; pass=$((pass + 1))
  else
    printf '  FAIL %-52s got [%s], want [%s]\n' "$name" "$got" "$want"; fail=$((fail + 1))
  fi
}

# The real shape from #688, plus the decoys every fetch has to survive: a clean
# verdict (also codex, also "Codex Review:"-prefixed), a badge finding, a human
# quoting the error text, and Grok saying anything at all.
ISSUE_COMMENTS='[
  {"user":{"login":"chatgpt-codex-connector[bot]"},
   "created_at":"2026-08-20T06:56:39Z",
   "body":"Codex Review: Something went wrong. Try again later by commenting “@codex review”.\n\n```\nUnknown error\n```"},
  {"user":{"login":"chatgpt-codex-connector[bot]"},
   "created_at":"2026-08-20T05:34:41Z",
   "body":"Codex Review: Didn'"'"'t find any major issues. Breezy!\n**Reviewed commit:** `abc1234`"},
  {"user":{"login":"jjangg96"},
   "created_at":"2026-08-20T07:00:00Z",
   "body":"codex said \"Codex Review: Something went wrong\" — should we retry?"},
  {"user":{"login":"1xp-dorami"},
   "created_at":"2026-08-20T06:58:53Z",
   "body":"Grok Review: Didn'"'"'t find any major issues. 🚀\n**Reviewed commit:** `def5678`"}
]'
REVIEWS='[
  {"user":{"login":"chatgpt-codex-connector[bot]"},
   "submitted_at":"2026-08-20T04:00:00Z",
   "body":"Codex Review: Something went wrong. Try again later by commenting “@codex review”."}
]'

api_all() {
  case "$1" in
    */issues/*) printf '%s' "$ISSUE_COMMENTS" ;;
    */pulls/*)  printf '%s' "$REVIEWS" ;;
    *) printf '[]' ;;
  esac
}

out="$(codex_errors o/r 1)"

check 'finds both notices, both endpoints' "$(printf '%s\n' "$out" | grep -c .)" 2
check 'sorted ascending — tail is newest'  "$(printf '%s\n' "$out" | tail -n 1)" '2026-08-20T06:56:39Z'
check 'review-object notice is normalised' "$(printf '%s\n' "$out" | head -n 1)" '2026-08-20T04:00:00Z'

# A clean verdict must never read as an error, and vice versa: the two phrases
# share a prefix, and a prefix match here would turn every verdict into a crash.
only_clean='[{"user":{"login":"chatgpt-codex-connector[bot]"},"created_at":"2026-08-20T05:34:41Z","body":"Codex Review: Didn'"'"'t find any major issues."}]'
api_all() { case "$1" in */issues/*) printf '%s' "$only_clean" ;; *) printf '[]' ;; esac; }
check 'a clean verdict is not an error' "$(codex_errors o/r 1 | grep -c . || true)" 0

# A human quoting the phrase is not Codex crashing.
only_human='[{"user":{"login":"someone"},"created_at":"2026-08-20T07:00:00Z","body":"Codex Review: Something went wrong"}]'
api_all() { case "$1" in */issues/*) printf '%s' "$only_human" ;; *) printf '[]' ;; esac; }
check 'a human quoting it is not an error' "$(codex_errors o/r 1 | grep -c . || true)" 0

# CODEX quoting the phrase mid-body is not a crash either — a review of code
# that emits this very message (this repo, for one) mentions it in rationale.
# Only a body that STARTS with the phrase is the notice (P1: prefix anchor).
codex_quotes='[{"user":{"login":"chatgpt-codex-connector[bot]"},"created_at":"2026-08-20T07:10:00Z",
  "body":"![P1 Badge](x) **Do not match Codex Review: Something went wrong loosely**\nbecause reviews quoting it would classify as crashes."}]'
api_all() { case "$1" in */issues/*) printf '%s' "$codex_quotes" ;; *) printf '[]' ;; esac; }
check 'codex quoting it mid-body is not an error' "$(codex_errors o/r 1 | grep -c . || true)" 0

# One endpoint down must not blank the other.
api_all() { case "$1" in */issues/*) printf '%s' "$ISSUE_COMMENTS" ;; *) return 1 ;; esac; }
check 'a failing reviews endpoint is tolerated' "$(codex_errors o/r 1 | tail -n 1)" '2026-08-20T06:56:39Z'

# ── Liveness: is the notice Codex's LAST word? ──────────────────────────────
#
# The trap this pins (P1 on PR #7): a notice delivered as a REVIEW OBJECT used
# to be its own superseding "later word" — err_at == latest_review_date, the >
# check false — and with one review counted and nothing filed, the verdict
# walked to clean/0 over a crash. A word is a word only if it is not the scream.

# Notice as a review object, and nothing else on the PR: LIVE.
api_all() { case "$1" in */pulls/*) printf '%s' "$REVIEWS" ;; *) printf '[]' ;; esac; }
check 'a review-object notice does not supersede itself' \
  "$(live_codex_error_at o/r 1 '')" '2026-08-20T04:00:00Z'

# A later REAL review supersedes it.
later_review='[
  {"user":{"login":"chatgpt-codex-connector[bot]"},"submitted_at":"2026-08-20T04:00:00Z",
   "body":"Codex Review: Something went wrong. Try again later by commenting “@codex review”."},
  {"user":{"login":"chatgpt-codex-connector[bot]"},"submitted_at":"2026-08-20T05:00:00Z",
   "body":"real review pass"}
]'
api_all() { case "$1" in */pulls/*) printf '%s' "$later_review" ;; *) printf '[]' ;; esac; }
check 'a later real review supersedes the notice' "$(live_codex_error_at o/r 1 '')" ''

# A later clean verdict (from the caller-supplied snapshot) supersedes it too.
api_all() { case "$1" in */pulls/*) printf '%s' "$REVIEWS" ;; *) printf '[]' ;; esac; }
clean_snapshot="$(printf '2026-08-20T05:34:41Z\tabc1234\tcodex')"
check 'a later clean verdict supersedes the notice' \
  "$(live_codex_error_at o/r 1 "$clean_snapshot")" ''

# …but an EARLIER clean verdict does not.
older_clean="$(printf '2026-08-20T03:00:00Z\tabc1234\tcodex')"
check 'an earlier clean verdict does not' \
  "$(live_codex_error_at o/r 1 "$older_clean")" '2026-08-20T04:00:00Z'

# A Grok verdict is not a Codex word.
grok_clean="$(printf '2026-08-20T05:00:00Z\tdef5678\tgrok')"
check 'a grok verdict is not a codex word' \
  "$(live_codex_error_at o/r 1 "$grok_clean")" '2026-08-20T04:00:00Z'

# A LATER Codex finding delivered purely as an issue comment (badge body, no
# review object) IS a word — without this, the notice stayed live forever and
# status exited 5 after the finding went stale (P1: issue findings are words).
notice_then_issue_finding='[
  {"user":{"login":"chatgpt-codex-connector[bot]"},"created_at":"2026-08-20T06:56:39Z",
   "body":"Codex Review: Something went wrong. Try again later by commenting “@codex review”."},
  {"user":{"login":"chatgpt-codex-connector[bot]"},"created_at":"2026-08-20T07:20:00Z",
   "body":"### 💡 Codex Review\n**![P2 Badge](https://img.shields.io/badge/P2-yellow)** later finding"}
]'
api_all() { case "$1" in */issues/*) printf '%s' "$notice_then_issue_finding" ;; *) printf '[]' ;; esac; }
check 'a later issue-comment finding supersedes' "$(live_codex_error_at o/r 1 '')" ''
# A word and a notice in the SAME second are unorderable at GitHub's
# one-second resolution — the tie reads as live (P2: suppressed crash costs a
# timeout, false-live costs one redundant re-request).
tie='[
  {"user":{"login":"chatgpt-codex-connector[bot]"},"created_at":"2026-08-20T07:20:00Z",
   "body":"Codex Review: Something went wrong. Try again later by commenting “@codex review”."},
  {"user":{"login":"chatgpt-codex-connector[bot]"},"created_at":"2026-08-20T07:20:00Z",
   "body":"### 💡 Codex Review\n**![P2 Badge](x)** same-second finding"}
]'
api_all() { case "$1" in */issues/*) printf '%s' "$tie" ;; *) printf '[]' ;; esac; }
check 'a same-second tie reads as live' "$(live_codex_error_at o/r 1 '')" '2026-08-20T07:20:00Z'

# An error REVIEW OBJECT must not look like a landed review: review_shas is the
# one source reviewed_head and hashless_review_count read, and an unfiltered
# notice there made wait print "Review landed." and return 0 over a status of 5.
err_review_with_sha='[
  {"id": 42, "user":{"login":"chatgpt-codex-connector[bot]"},"submitted_at":"2026-08-20T04:00:00Z",
   "body":"Codex Review: Something went wrong. Try again later.\n**Reviewed commit:** `deadbeef`"}
]'
api_all() { case "$1" in */pulls/*) printf '%s' "$err_review_with_sha" ;; *) printf '[]' ;; esac; }
check 'an error review object yields no review sha' "$(review_shas o/r 1)" '{}'

# …but chat noise from the Codex login is NOT a word.
notice_then_chat='[
  {"user":{"login":"chatgpt-codex-connector[bot]"},"created_at":"2026-08-20T06:56:39Z",
   "body":"Codex Review: Something went wrong. Try again later by commenting “@codex review”."},
  {"user":{"login":"chatgpt-codex-connector[bot]"},"created_at":"2026-08-20T07:20:00Z",
   "body":"ℹ️ About Codex in GitHub — how reviews are triggered."}
]'
api_all() { case "$1" in */issues/*) printf '%s' "$notice_then_chat" ;; *) printf '[]' ;; esac; }
check 'codex chat noise is not a word' "$(live_codex_error_at o/r 1 '')" '2026-08-20T06:56:39Z'

echo
if [ "$fail" -gt 0 ]; then echo "$fail failing, $pass ok"; exit 1; fi
echo "all $pass ok"
