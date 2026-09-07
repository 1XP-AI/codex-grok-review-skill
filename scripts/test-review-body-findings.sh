#!/usr/bin/env bash
#
# The review-BODY finding parser — the third place a finding can live.
#
# test-issue-findings.sh pins what happens to a badge comment on the issue
# endpoint. This one pins the same shape when it arrives as the body of a review
# object: `### 💡 Codex Review`, a blob permalink, the badge, the title, the
# rationale — submitted as a review, so it has `submitted_at` and `commit_id`,
# carries no "Reviewed commit" line, and leaves NO inline comment behind it.
#
# To the reader it was invisible. `review_shas` read review bodies only for a
# "Reviewed commit" line, `fetch_findings` read the review COMMENTS endpoint,
# and `fetch_issue_findings` read issue comments. Measured on
# 1XP-AI/boardgame-engine PR #472: two consecutive passes (50e8013, 5c1bb37)
# each carried one P2 this way, `pulls/472/comments` held neither, `all 472`
# printed neither, and `status` answered "0 open findings … all stale, exit 4"
# — "confirm they are addressed, then merge" — over an open P2, twice.
#
# The parser is sourced out of the real script — a copy would drift. api_all is
# stubbed per endpoint so the fixtures play both.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$here/codex-grok-review.sh"
[ -f "$src" ] || { echo "cannot find codex-grok-review.sh next to this script" >&2; exit 1; }

eval "$(awk '/^CODEX_LOGIN=/{p=1} p{print} /^JQ_REVIEWER_LIB=/{exit}' "$src")"
JQ_REVIEWER_LIB="$(jq_reviewer_lib)"
[ -n "${JQ_REVIEWER_LIB:-}" ] || { echo "JQ_REVIEWER_LIB not extracted" >&2; exit 1; }

for name in fetch_issue_findings fetch_review_body_findings review_shas issue_open_in; do
  fn="$(sed -n "/^${name}() {/,/^}/p" "$src")"
  [ -n "$fn" ] || { echo "$name not found in $src — was it renamed?" >&2; exit 1; }
  eval "$fn"
done

pass=0; fail=0
check() {
  local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    printf '  ok   %-56s %s\n' "$name" "$got"; pass=$((pass + 1))
  else
    printf '  FAIL %-56s got [%s], want [%s]\n' "$name" "$got" "$want"; fail=$((fail + 1))
  fi
}

# --- fixtures ---------------------------------------------------------------
#
# Bodies are the real shapes from PR #472, paths shortened. id 2 is the P2 that
# was missed (permalink names HEAD); id 3 the same shape naming the previous
# commit; id 4 an ordinary findings review (inline comments carry the findings,
# the body only the hash); id 5 a clean verdict as a review body; id 6 a crash
# notice as a review body; id 7 a badge body with NO permalink, so the review's
# own commit_id must place it in time; id 8 Grok, same shape as id 2.
HEAD_SHA='5c1bb37016983a2b4cfdb3e4b21c663ee7992018'
FOOTER='\n\n<details> <summary>ℹ️ About Codex in GitHub</summary>\n<br/>\n\nReviews are triggered when you comment \"@codex review\".\n</details>'

REVIEWS="$(cat <<JSON
[
  { "id": 2, "submitted_at": "2026-09-07T05:00:40Z", "commit_id": "$HEAD_SHA", "html_url": "r2", "state": "COMMENTED",
    "user": { "login": "chatgpt-codex-connector[bot]" },
    "body": "### 💡 Codex Review\n\nhttps://github.com/O/R/blob/5c1bb37016983a2b4cfdb3e4b21c663ee7992018/packages/harness/src/simulation/cli.e2e.test.ts#L90\n**<sub><sub>![P2 Badge](https://img.shields.io/badge/P2-yellow?style=flat)</sub></sub>  Keep the non-E2E boundary check in the unit project**\n\nRenaming the whole file also removes this inexpensive test from mandatory verification. Split this check into a regular .test.ts file while leaving the 500-episode subprocess test in E2E.${FOOTER}" },

  { "id": 3, "submitted_at": "2026-09-07T04:50:53Z", "commit_id": "50e80132bb7cddfd329bbd92abc02c8dbbd44d51", "html_url": "r3", "state": "COMMENTED",
    "user": { "login": "chatgpt-codex-connector[bot]" },
    "body": "### 💡 Codex Review\n\nhttps://github.com/O/R/blob/50e80132bb7cddfd329bbd92abc02c8dbbd44d51/packages/harness/src/simulation/cli.e2e.test.ts#L90\n**<sub><sub>![P2 Badge](https://img.shields.io/badge/P2-yellow?style=flat)</sub></sub>  Keep the public-boundary check in unit coverage**\n\nMoving this whole file also removes this assertion. Split this test back into a .test.ts file.${FOOTER}" },

  { "id": 4, "submitted_at": "2026-09-07T04:28:25Z", "commit_id": "225da8ebb5aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "html_url": "r4", "state": "COMMENTED",
    "user": { "login": "chatgpt-codex-connector[bot]" },
    "body": "### 💡 Codex Review\n\nHere are some automated review suggestions for this pull request.\n\n**Reviewed commit:** \`225da8ebb5\`${FOOTER}" },

  { "id": 5, "submitted_at": "2026-09-07T04:25:59Z", "commit_id": "fc5b5c2e25aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "html_url": "r5", "state": "COMMENTED",
    "user": { "login": "chatgpt-codex-connector[bot]" },
    "body": "Codex Review: Didn't find any major issues. Bravo.\n\n**Reviewed commit:** \`fc5b5c2e25\`${FOOTER}" },

  { "id": 6, "submitted_at": "2026-09-07T04:20:00Z", "commit_id": "fc5b5c2e25aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "html_url": "r6", "state": "COMMENTED",
    "user": { "login": "chatgpt-codex-connector[bot]" },
    "body": "Codex Review: Something went wrong. Try again later by commenting \"@codex review\"." },

  { "id": 7, "submitted_at": "2026-09-07T05:01:00Z", "commit_id": "$HEAD_SHA", "html_url": "r7", "state": "COMMENTED",
    "user": { "login": "chatgpt-codex-connector[bot]" },
    "body": "**<sub><sub>![P1 Badge](https://img.shields.io/badge/P1-orange?style=flat)</sub></sub>  No permalink at all**\n\nOne paragraph. Persist the wallet before returning.${FOOTER}" },

  { "id": 8, "submitted_at": "2026-09-07T05:02:00Z", "commit_id": "$HEAD_SHA", "html_url": "r8", "state": "COMMENTED",
    "user": { "login": "1xp-dorami" },
    "body": "https://github.com/O/R/blob/5c1bb37016983a2b4cfdb3e4b21c663ee7992018/src/a.ts#L3-L5\n**<sub><sub>![P3 Badge](https://img.shields.io/badge/P3-blue?style=flat)</sub></sub>  Grok, same shape**\n\nOne paragraph. Rename it." },

  { "id": 9, "submitted_at": "2026-09-07T05:03:00Z", "commit_id": "$HEAD_SHA", "html_url": "r9", "state": "COMMENTED",
    "user": { "login": "jjangg96" },
    "body": "https://github.com/O/R/blob/5c1bb37016983a2b4cfdb3e4b21c663ee7992018/src/a.ts#L3\n**![P0 Badge](x) A human quoting the shape**" }
]
JSON
)"
ISSUE_COMMENTS='[]'

api_all() {
  case "$1" in
    */pulls/*/reviews)   printf '%s' "$REVIEWS" ;;
    */issues/*/comments) printf '%s' "$ISSUE_COMMENTS" ;;
    *) echo "unexpected endpoint $1" >&2; return 1 ;;
  esac
}

OUT="$(fetch_review_body_findings "O/R" "$HEAD_SHA" 472)"
q()  { printf '%s' "$OUT" | jq -r "$1"; }
by() { printf '%s' "$OUT" | jq -r "first(.[] | select(.id == $1)) | $2"; }

# --- the regression: a finding in a review body is a finding -----------------
check 'body finding on HEAD is reported'            "$(q '[.[] | select(.id == 2)] | length')" '1'
check 'it keeps its severity'                       "$(by 2 '.severity')" 'P2'
check 'it keeps its title'                          "$(by 2 '.title')" 'Keep the non-E2E boundary check in the unit project'
check 'it is located by the permalink'              "$(by 2 '.path')|$(by 2 '.line')" 'packages/harness/src/simulation/cli.e2e.test.ts|90'
check 'it names its commit from the permalink'      "$(by 2 '.reviewed_sha')" '5c1bb37016983a2b4cfdb3e4b21c663ee7992018'
check 'naming HEAD, it is live'                     "$(by 2 '.stale')|$(by 2 '.anchored')" 'false|true'
check 'it is labelled by source'                    "$(by 2 '.source')" 'review-body'
check 'it dates by submitted_at'                    "$(by 2 '.created_at')" '2026-09-07T05:00:40Z'
check 'the About footer is not rationale'           "$(by 2 '.rationale | test("About Codex")')" 'false'
check 'the prescription is read'                    "$(by 2 '.fix' | cut -c1-30)" 'Split this check into a regula'
check 'it keeps its url'                            "$(by 2 '.url')" 'r2'
# Same shape, previous commit: stale, exactly as an inline finding would be.
check 'body finding on an older commit is stale'    "$(by 3 '.stale')" 'true'
check 'but still listed (all-stale is a verdict)'   "$(q '[.[] | select(.id == 3)] | length')" '1'
# No permalink: the review object itself says which commit it inspected.
check 'permalink-less body takes commit_id'         "$(by 7 '.reviewed_sha')" "$HEAD_SHA"
check 'and so is live on HEAD, not date-guessed'    "$(by 7 '.stale')" 'false'
check 'and says where it could not be placed'       "$(by 7 '.path')" '(location unknown)'
check 'Grok body finding is read too'               "$(by 8 '.severity')|$(by 8 '.start_line')|$(by 8 '.line')" 'P3|3|5'

# --- what must stay out ------------------------------------------------------
check 'an ordinary findings review is not a finding' "$(q '[.[] | select(.id == 4)] | length')" '0'
check 'a clean verdict body is not a finding'        "$(q '[.[] | select(.id == 5)] | length')" '0'
check 'a crash notice body is not a finding'         "$(q '[.[] | select(.id == 6)] | length')" '0'
check 'a human quoting the shape is not a finding'   "$(q '[.[] | select(.id == 9)] | length')" '0'
check 'total body findings'                          "$(q 'length')" '4'

# --- the count status gates on: sources other than inline comments ------------
check 'issue_open_in counts body findings'          "$(issue_open_in "$OUT")" '3'

# --- the issue-comment path is unchanged ---------------------------------------
check 'issue endpoint still yields issue source'    "$(fetch_issue_findings "O/R" "$HEAD_SHA" 472 | jq -r 'length')" '0'

# --- review_shas: a body finding names its commit in the URL -------------------
#
# Without this, such a review is "hashless": reviewed_head says nobody reviewed
# HEAD and wait only notices it through the count fallback.
SHAS="$(review_shas "O/R" 472)"
s() { printf '%s' "$SHAS" | jq -r ".\"$1\""; }
check 'review_shas reads the permalink sha'         "$(s 2)" '5c1bb37016983a2b4cfdb3e4b21c663ee7992018'
check 'Reviewed-commit line still wins where present' "$(s 4)" '225da8ebb5'
check 'clean verdict keeps its hash'                "$(s 5)" 'fc5b5c2e25'
check 'a crash notice yields no sha entry'          "$(printf '%s' "$SHAS" | jq -r 'has("6")')" 'false'
check 'a permalink-less body is hashless here'      "$(s 7)" ''
check 'a cited AGENTS.md link after the badge is not the sha' \
  "$(REVIEWS='[{"id":1,"user":{"login":"chatgpt-codex-connector[bot]"},"submitted_at":"2026-09-07T05:00:40Z","body":"**<sub>![P2 Badge](x)</sub> T**\n\nr\n\nAGENTS.md reference: [a](https://github.com/O/R/blob/deadbee1234/AGENTS.md#L1)"}]' review_shas O/R 1 | jq -r '."1"')" ''

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
