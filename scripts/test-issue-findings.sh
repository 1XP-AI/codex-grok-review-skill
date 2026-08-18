#!/usr/bin/env bash
#
# The issue-comment finding parser.
#
# test-reviewer.sh pins the PREDICATE — which authors and bodies count as a
# finding. It says nothing about what happens to a comment after it passes.
# That gap hid a regression of the bug this endpoint was added for: `capture`
# emits nothing when it does not match, and `($c.body | capture(...)) as $loc`
# over an empty stream drops the element, so a badge-carrying comment with no
# blob permalink disappeared. Three badge comments in, one out — and `status`
# then answers CLEAN over an open P0.
#
# Two of this repo's own Grok fixtures (grok_p2, grok_p0 in test-reviewer.sh)
# are exactly that shape: they pass the predicate and used to die here.
#
# The parser is sourced out of the real script — a copy would drift.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$here/codex-grok-review.sh"
[ -f "$src" ] || { echo "cannot find codex-grok-review.sh next to this script" >&2; exit 1; }

# Login defaults + the jq lib builder, straight from the script.
eval "$(awk '/^CODEX_LOGIN=/{p=1} p{print} /^JQ_REVIEWER_LIB=/{exit}' "$src")"
JQ_REVIEWER_LIB="$(jq_reviewer_lib)"
[ -n "${JQ_REVIEWER_LIB:-}" ] || { echo "JQ_REVIEWER_LIB not extracted" >&2; exit 1; }

fn="$(sed -n '/^fetch_issue_findings() {/,/^}/p' "$src")"
[ -n "$fn" ] || { echo "fetch_issue_findings not found in $src — was it renamed?" >&2; exit 1; }
eval "$fn"

pass=0; fail=0
check() {
  local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    printf '  ok   %-52s %s\n' "$name" "$got"; pass=$((pass + 1))
  else
    printf '  FAIL %-52s got [%s], want [%s]\n' "$name" "$got" "$want"; fail=$((fail + 1))
  fi
}

# --- fixtures ---------------------------------------------------------------
#
# Nine issue comments; six of them are findings. The permalink-less pair is
# the regression guard, and id 4 is the heading shape it exposed.
HEAD_SHA='cf125d41c7aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

FIXTURE="$(cat <<'JSON'
[
  { "id": 1, "created_at": "2026-08-18T00:01:00Z", "html_url": "u1",
    "user": { "login": "chatgpt-codex-connector[bot]" },
    "body": "### 💡 Codex Review\n\nhttps://github.com/O/R/blob/cf125d41c7/packages/api/src/routes/auth.ts#L169\n**<sub><sub>![P1 Badge](https://img.shields.io/badge/P1-orange?style=flat)</sub></sub>  Move sign-in keying after body parsing**\n\nWith the default onRequest hook the POST body has not been parsed. Key the limiter after parsing.\n\nAGENTS.md reference: [AGENTS.md:L327-L335](https://github.com/O/R/blob/cf125d41c7/AGENTS.md#L327-L335)" },

  { "id": 2, "created_at": "2026-08-18T00:02:00Z", "html_url": "u2",
    "user": { "login": "chatgpt-codex-connector[bot]" },
    "body": "https://github.com/O/R/blob/deadbee1234/src/range.ts#L12-L14\n**<sub><sub>![P2 Badge](https://img.shields.io/badge/P2-yellow?style=flat)</sub></sub>  Widen the guard**\n\nOne paragraph. Widen the guard to cover the empty case." },

  { "id": 3, "created_at": "2026-08-18T00:03:00Z", "html_url": "u3",
    "user": { "login": "1xp-dorami" },
    "body": "**<sub><sub>![P2 Badge](https://img.shields.io/badge/P2-yellow?style=flat)</sub></sub>  Guard the empty path**\n\nOne paragraph. Guard the empty path before dereferencing it." },

  { "id": 4, "created_at": "2026-08-18T00:04:00Z", "html_url": "u4",
    "user": { "login": "chatgpt-codex-connector[bot]" },
    "body": "![P0 Badge](https://img.shields.io/badge/P0-red?style=flat) **Do not drop the wallet**\n\nOne paragraph. Persist the wallet before returning." },

  { "id": 5, "created_at": "2026-08-18T00:05:00Z", "html_url": "u5",
    "user": { "login": "1xp-dorami" },
    "body": "looks good, ship it" },

  { "id": 6, "created_at": "2026-08-18T00:06:00Z", "html_url": "u6",
    "user": { "login": "chatgpt-codex-connector[bot]" },
    "body": "Codex Review: Didn't find any major issues. Breezy!\n\n**Reviewed commit:** `cf125d41c7`" },

  { "id": 7, "created_at": "2026-08-18T00:07:00Z", "html_url": "u7",
    "user": { "login": "random-user" },
    "body": "https://github.com/O/R/blob/cf125d41c7/src/nope.ts#L1\n**![P1 Badge](x) Wrong author**\n\nIgnored." },

  { "id": 8, "created_at": "2026-08-18T00:08:00Z", "html_url": "u8",
    "user": { "login": "chatgpt-codex-connector[bot]" },
    "body": "https://github.com/O/R/blob/cf125d41c7/%ED%95%9C%EA%B8%80/a.ts#L7\n**<sub>![P3 Badge](https://img.shields.io/badge/P3-blue?style=flat)</sub>  Rename the helper**\n\nOne paragraph. Rename it to something the caller recognises." },

  { "id": 9, "created_at": "2026-08-18T00:09:00Z", "html_url": "u9",
    "user": { "login": "1xp-dorami" },
    "body": "![P4 Badge](https://img.shields.io/badge/P4-lightgrey?style=flat) no bold heading anywhere in this body" }
]
JSON
)"

api_all() { printf '%s' "$FIXTURE"; }
OUT="$(fetch_issue_findings "O/R" "$HEAD_SHA" 1)"

q() { printf '%s' "$OUT" | jq -r "$1"; }
by() { printf '%s' "$OUT" | jq -r "first(.[] | select(.id == $1)) | $2"; }

# --- the regression: a badge with no blob permalink must survive -------------
check 'permalink-less Grok P2 is reported'   "$(q '[.[] | select(.id == 3)] | length')" '1'
check 'permalink-less Codex P0 is reported'  "$(q '[.[] | select(.id == 4)] | length')" '1'
check 'permalink-less finding keeps severity' "$(by 3 '.severity')"   'P2'
check 'permalink-less finding keeps title'    "$(by 3 '.title')"      'Guard the empty path'
# The badge sits AHEAD of the bold run here, not inside it. The single-pattern
# reader backtracked onto the space before `**` and captured it, so the title
# trimmed to empty — and an empty string is truthy to `//`, so not even
# "(untitled)" came out. Invisible before the permalink fix; blank after it.
check 'bare-badge heading is read'            "$(by 4 '.title')"      'Do not drop the wallet'
check 'wrapped heading still read'            "$(by 1 '.title')"      'Move sign-in keying after body parsing'
check 'single-sub heading still read'         "$(by 8 '.title')"      'Rename the helper'
check 'no heading at all falls back'          "$(by 9 '.title')"      '(untitled)'
check 'headingless finding is still reported' "$(q '[.[] | select(.id == 9)] | length')" '1'
check 'permalink-less finding says so'        "$(by 3 '.path')"       '(location unknown)'
# Live, not stale: an unplaceable finding must still block a merge. Stale would
# hide it from `findings`/`status` just as effectively as dropping it did.
check 'permalink-less finding is live'        "$(by 3 '.stale')"      'false'
check 'permalink-less finding is anchored'    "$(by 3 '.anchored')"   'true'
check 'permalink-less finding keeps its url'  "$(by 4 '.url')"        'u4'
check 'permalink-less finding has no range'   "$(by 4 '.start_line')" 'null'

# --- the shapes that already worked, so the fallback cannot mask them --------
check 'total findings parsed'                "$(q 'length')"          '6'
check 'located finding keeps its path'       "$(by 1 '.path')"        'packages/api/src/routes/auth.ts'
check 'located finding keeps its line'       "$(by 1 '.line')"        '169'
check 'located finding takes the FIRST link' "$(by 1 '.start_line')"  'null'
check 'located finding keeps its sha'        "$(by 1 '.reviewed_sha')" 'cf125d41c7'
check 'permalink naming HEAD is live'        "$(by 1 '.stale')"       'false'
check 'ranged permalink keeps both ends'     "$(by 2 '.start_line')|$(by 2 '.line')" '12|14'
check 'permalink naming an older is stale'   "$(by 2 '.stale')"       'true'
check 'percent-encoded path is decoded'      "$(by 8 '.path')"        '한글/a.ts'

# --- what must stay out -----------------------------------------------------
check 'dorami chatter is not a finding'      "$(q '[.[] | select(.id == 5)] | length')" '0'
check 'clean verdict is not a finding'       "$(q '[.[] | select(.id == 6)] | length')" '0'
check 'wrong author is not a finding'        "$(q '[.[] | select(.id == 7)] | length')" '0'

# --- the count `status` actually gates on -----------------------------------
# Both permalink-less findings land here. Before the fallback this was 3.
check 'live findings counted'                "$(q '[.[] | select(.stale == false and .anchored == true)] | length')" '5'

# --- staleness by date, when there is no sha to compare ---------------------
#
# `sha: ""` is what keeps an unlocated finding alive, and with no second signal
# it stays alive FOREVER: the author fixes the code, pushes, and `status` still
# exits 2 until someone deletes the comment. The review-comment parser already
# falls back to `created_at < $headdate`; this one was never handed the date.
#
# The sha still wins where there is one — the date is a watermark, not proof.
d() { printf '%s' "$1" | jq -r "first(.[] | select(.id == $2)) | $3"; }

MID="$(fetch_issue_findings "O/R" "$HEAD_SHA" 1 '2026-08-18T00:05:00Z')"
check 'unlocated, posted before head, stale' "$(d "$MID" 3 '.stale')" 'true'
check 'unlocated, posted before head, stale' "$(d "$MID" 4 '.stale')" 'true'
check 'unlocated, posted after head, live'   "$(d "$MID" 9 '.stale')" 'false'
# The whole point: the merge gate lets go once the work moves on.
# Live drops from 5 to 3: the two unlocated findings that predate the newest
# commit let go, while id 9 (posted after it) and the two sha-matched ones hold.
check 'stale unlocated stops blocking'       "$(printf '%s' "$MID" | jq '[.[] | select(.stale == false and .anchored == true)] | length')" '3'

LATER="$(fetch_issue_findings "O/R" "$HEAD_SHA" 1 '2026-08-18T00:30:00Z')"
# Selected on the empty sha, not on the source: every finding here is source
# "issue", so that predicate would also count the one already stale by hash.
check 'every unlocated goes stale eventually' "$(printf '%s' "$LATER" | jq '[.[] | select(.reviewed_sha == "" and .stale)] | length')" '3'
# A sha that names HEAD outranks any date — the finding IS about this commit.
check 'sha naming head beats a later date'   "$(d "$LATER" 1 '.stale')" 'false'

EARLY="$(fetch_issue_findings "O/R" "$HEAD_SHA" 1 '2026-08-18T00:00:00Z')"
check 'unlocated newer than head is live'    "$(d "$EARLY" 3 '.stale')" 'false'
# And a sha that names an older commit stays stale however early the watermark.
check 'sha naming an older beats the date'   "$(d "$EARLY" 2 '.stale')" 'true'

# No date at all is `wait`, which does not fetch one. Calling a finding stale on
# no evidence hides it, so the always-live reading stands there.
check 'no date keeps unlocated live'         "$(by 3 '.stale')" 'false'

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
