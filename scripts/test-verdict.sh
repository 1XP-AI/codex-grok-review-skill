#!/usr/bin/env bash
#
# The verdict table.
#
# `status` and `findings` both publish exit codes and the help text promises they are
# the same ones. They were not — `findings` returned 0 with open findings printed above
# it, so `codex-grok-review.sh findings N && merge` merged straight through them. The fix was
# to put the decision in one function; this pins it so the two cannot drift apart again.
#
# It sources verdict_key out of the real script rather than copying it, so a change to
# the rule that nobody reflected here fails loudly instead of silently passing.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$here/codex-grok-review.sh"
[ -f "$src" ] || { echo "cannot find codex-grok-review.sh next to this script" >&2; exit 1; }

fn="$(sed -n '/^verdict_key() {/,/^}/p' "$src")"
[ -n "$fn" ] || { echo "verdict_key not found in $src — was it renamed?" >&2; exit 1; }
eval "$fn"

pass=0; fail=0
# name | open total reviews thumbs clean_line head_clean clean_sha issue missing | key | code
# `missing` is 1 when REQUIRED_REVIEWERS is unmet. It defaults to 1 in verdict_key:
# an unknown policy state must never be read as clean, so every row states it.
t() {
  local name="$1" args="$2" want_k="$3" want_c="$4" k c
  k="$(eval "verdict_key $args")"; c=$?
  if [ "$k" = "$want_k" ] && [ "$c" = "$want_c" ]; then
    printf '  ok   %-34s %s/%s\n' "$name" "$k" "$c"; pass=$((pass + 1))
  else
    printf '  FAIL %-34s got %s/%s, want %s/%s\n' "$name" "$k" "$c" "$want_k" "$want_c"
    fail=$((fail + 1))
  fi
}

t 'clean verdict names head'      '0 0 1 0 "x" 1 abc 0 0' clean-head   0
# The policy, not the newest verdict on the PR, decides clean.
#
# clean_matches_head comes from the LAST LINE of the all-author list, so it says
# "did whoever spoke most recently name HEAD". With two bots that is the wrong
# question: Codex clears HEAD, Grok posts a late clean for an older commit, and
# the global-latest SHA goes stale while REQUIRED_REVIEWERS=codex is satisfied.
# This used to return stale-clean/3 and block a PR the policy had accepted.
t 'policy met, later clean names older' '0 0 1 0 "x" 1 deadbee 0 0' clean-head 0
# The same guard stated bluntly: the clean test reads the policy flag and nothing
# else. Even with no HEAD-clean signalled at all, a satisfied policy is clean.
t 'clean test consults only the policy' '0 0 1 0 "x" 0 deadbee 0 0' clean-head 0
# Policy unmet, but SOMEONE cleared HEAD — wait for the other reviewer rather
# than telling the caller the newest code is unreviewed. The globally-latest
# verdict cannot make this call: on a dual-bot PR it is routinely the older one.
t 'one cleared HEAD, another still owed' '0 0 1 0 "x" 1 deadbee 0 1' partial-clean 3
# REQUIRED_REVIEWERS unmet. Someone cleared HEAD, just not everyone required —
# wait for the other reviewer rather than requesting a fresh review.
t 'a required reviewer has not vouched' '0 0 1 0 "x" 1 abc 0 1' partial-clean 3
# Nobody cleared HEAD and the only verdict is older: the newest code really is
# unreviewed, so this stays stale-clean and sends you to `request`.
t 'clean verdict names an older'  '0 3 1 0 "x" 0 abc 0 1' stale-clean  3
# Only the clean test consults the policy. A review that left a 👍 and no clean
# comment still reports clean/0 — a reaction names no commit, so there is no
# verdict for anyone to be missing from, and gating it would break that path.
t 'missing does not touch the thumbs path' '0 0 1 1 "" 0 "" 0 1' clean        0
t 'no review, no thumbs, nothing' '0 0 0 0 "" 0 "" 0 1'   not-reviewed 3
t 'reviewed, all findings stale'  '0 3 1 0 "" 0 "" 0 1'   all-stale    4
t 'reviewed, nothing filed'       '0 0 1 0 "" 0 "" 0 1'   clean        0
t 'open findings'                 '2 5 1 0 "" 0 "" 0 1'   open         2
# An issue-comment finding is the only trace some reviews leave; without counting it
# this row read as not-reviewed while a P1 sat on the PR. It is now counted out of the
# same snapshot as `open`, so a live one always shows up in `open` and `total` too.
t 'issue finding, no review object' '1 1 0 0 "" 0 "" 1 1'   open         2
# An issue-comment finding leaves no review object behind it, so when it goes stale
# the finding IS the only evidence a review ever ran. Keyed on reviews/thumbs/clean
# alone, this row said not-reviewed — telling the caller to request a review that had
# already happened, and dropping the all-stale verdict that says "check these landed".
t 'stale issue finding, no review' '0 1 0 0 "" 0 "" 0 1'   all-stale    4
# The combination that cannot come from one snapshot. It could when `issue_open` was
# its own fetch, and it fell straight through to clean/0 with a P1 on the PR.
t 'live issue finding, empty list'  '0 0 0 0 "" 0 "" 1 1'   inconsistent 3
# open beats a clean verdict: a later review can file against the same commit an
# earlier one blessed. It outranks a satisfied policy too, not just a partial one.
t 'open outranks a satisfied policy' '2 5 1 0 "x" 1 abc 0 0' open         2
t 'open outranks a partial clean'  '2 5 1 0 "x" 1 abc 0 1' open         2
# Mixed Codex+Grok thread: a clean verdict naming HEAD must not cover an
# open Grok finding. Either author's open badge makes status 2, not 0.
t 'mixed Codex clean + Grok P2'   '1 1 1 0 "x" 1 abc 1 0' open         2

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
