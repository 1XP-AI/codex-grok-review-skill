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

fn="$(sed -n '/^codex_errors() {/,/^}/p' "$src")"
[ -n "$fn" ] || { echo "codex_errors not found in $src — was it renamed?" >&2; exit 1; }
eval "$fn"

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

# One endpoint down must not blank the other.
api_all() { case "$1" in */issues/*) printf '%s' "$ISSUE_COMMENTS" ;; *) return 1 ;; esac; }
check 'a failing reviews endpoint is tolerated' "$(codex_errors o/r 1 | tail -n 1)" '2026-08-20T06:56:39Z'

echo
if [ "$fail" -gt 0 ]; then echo "$fail failing, $pass ok"; exit 1; fi
echo "all $pass ok"
