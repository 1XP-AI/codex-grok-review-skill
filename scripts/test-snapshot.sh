#!/usr/bin/env bash
#
# The findings snapshot must not be older than the review count it is judged against.
#
# Findings-then-reviews is the dangerous order: a review landing between the two
# reads leaves an empty finding list beside a nonzero review count, and that pair
# walks the verdict table to `clean`/0 — a merge permitted over findings that were
# arriving as we looked. Reviews-then-findings fails safe instead. The reorder shuts
# the common window; the re-read below covers the rest, since the two endpoints are
# separately consistent and a review can be visible before its own comments are.
#
# fetch_findings_settled is sourced from the real script and its two dependencies
# are stubbed, so this exercises the actual control flow rather than a copy of it.
# The call counter lives in a file: the function reads its stubs through command
# substitution, and a variable incremented in that subshell never comes back.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$here/codex-grok-review.sh"
fn="$(sed -n '/^fetch_findings_settled() {/,/^}/p' "$src")"
[ -n "$fn" ] || { echo "fetch_findings_settled not found in $src — renamed?" >&2; exit 1; }
eval "$fn"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
calls="$tmp/calls"

bump() { printf 'x' >>"$calls"; }
count() { [ -f "$calls" ] && wc -c <"$calls" | tr -d ' ' || echo 0; }
reset() { : >"$calls"; }

pass=0; fail=0
check() {
  if [ "$2" = "$3" ]; then printf '  ok   %-42s %s\n' "$1" "$2"; pass=$((pass + 1))
  else printf '  FAIL %-42s got %s, want %s\n' "$1" "$2" "$3"; fail=$((fail + 1)); fi
}

# --- the review arrives between the two reads -------------------------------
# The first read sees nothing; by the second, the review's comments are visible.
fetch_findings() { bump; if [ "$(count)" -ge 2 ]; then printf '[{"x":1}]'; else printf '[]'; fi; }
review_count() { echo 1; }
reset; out="$(fetch_findings_settled o/r 1 date sha)"
check 'empty list + a review is re-read' "$out" '[{"x":1}]'

# --- an honestly empty PR is not re-read forever ----------------------------
fetch_findings() { bump; printf '[]'; }
review_count() { echo 0; }
reset; out="$(fetch_findings_settled o/r 1 date sha)"
check 'no reviews, empty stays empty' "$out" '[]'
check 'no reviews, single fetch' "$(count)" '1'

# --- findings already there: no second call --------------------------------
fetch_findings() { bump; printf '[{"x":1}]'; }
review_count() { echo 3; }
reset; fetch_findings_settled o/r 1 date sha >/dev/null
check 'a non-empty list is taken as-is' "$(count)" '1'

# --- the caller's count wins over a fresh read ------------------------------
# A count read AFTER the findings is the bug; passing one in is how a caller says
# "this was read first". The stub returns a number that would force a re-read, and
# it must not be consulted.
fetch_findings() { bump; printf '[]'; }
review_count() { echo 9; }
reset; fetch_findings_settled o/r 1 date sha 0 >/dev/null
check 'a passed-in count is not re-read' "$(count)" '1'

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
