#!/usr/bin/env bash
#
# Grok reviews post as 1xp-dorami. Only comments that look like a review count.
# This pins the reviewer predicate so a random 1xp-dorami comment cannot appear
# as a finding, and so a Grok clean / Grok P-badge is accepted the same way as
# Codex. The defs are sourced from the real script — a copy would drift.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$here/codex-review.sh"
[ -f "$src" ] || { echo "cannot find codex-review.sh next to this script" >&2; exit 1; }

eval "$(python3 - "$src" <<'PY'
import sys
from pathlib import Path
t = Path(sys.argv[1]).read_text()
start = t.index("JQ_REVIEWER_LIB='")
end = t.index("\n'", start) + 2
print(t[start:end])
PY
)"
[ -n "${JQ_REVIEWER_LIB:-}" ] || { echo "JQ_REVIEWER_LIB not extracted" >&2; exit 1; }

pass=0; fail=0
check() {
  local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    printf '  ok   %-48s %s\n' "$name" "$got"; pass=$((pass + 1))
  else
    printf '  FAIL %-48s got %s, want %s\n' "$name" "$got" "$want"; fail=$((fail + 1))
  fi
}

ask() {
  # $1 name  $2 json  $3 jq expr  $4 want
  local name="$1" json="$2" expr="$3" want="$4" got
  got="$(printf '%s' "$json" | jq -r "${JQ_REVIEWER_LIB}${expr}")"
  check "$name" "$got" "$want"
}

# --- fixtures ---------------------------------------------------------------
codex_clean='{"user":{"login":"chatgpt-codex-connector[bot]"},"body":"Codex Review: Didn'"'"'t find any major issues. Breezy!\n\n**Reviewed commit:** `d94a859dde`"}'
grok_clean='{"user":{"login":"1xp-dorami"},"body":"Grok Review: Didn'"'"'t find any major issues. 🚀\n\n**Reviewed commit:** `d94a859dde`"}'
grok_p2='{"user":{"login":"1xp-dorami"},"body":"**<sub><sub>![P2 Badge](https://img.shields.io/badge/P2-yellow?style=flat)</sub></sub>  Guard the empty path**\n\nOne paragraph."}'
grok_p0='{"user":{"login":"1xp-dorami"},"body":"![P0 Badge](https://img.shields.io/badge/P0-red?style=flat) **Do not drop the wallet**\n\nOne paragraph."}'
grok_p4='{"user":{"login":"1xp-dorami"},"body":"![P4 Badge](https://img.shields.io/badge/P4-lightgrey?style=flat) **Name the helper**\n\nOne paragraph."}'
noise='{"user":{"login":"1xp-dorami"},"body":"looks good, ship it"}'
other='{"user":{"login":"random-user"},"body":"![P1 Badge](x) **Nope**\n\nIgnored — wrong author."}'
codex_p1='{"user":{"login":"chatgpt-codex-connector[bot]"},"body":"**<sub>![P1 Badge](https://img.shields.io/badge/P1-orange?style=flat)</sub>  Move sign-in keying**\n\nOne paragraph."}'

ask 'Codex clean is a reviewer'           "$codex_clean" 'is_reviewer'       'true'
ask 'Grok clean on HEAD is a reviewer'    "$grok_clean"  'is_reviewer'       'true'
ask 'Grok P2 inline is a reviewer'        "$grok_p2"     'is_reviewer'       'true'
ask 'Grok P2 is a finding author'         "$grok_p2"     'is_finding_author' 'true'
ask 'Grok P0 is a finding author'         "$grok_p0"     'is_finding_author' 'true'
ask 'Grok P4 is a finding author'         "$grok_p4"     'is_finding_author' 'true'
ask '1xp-dorami noise is not a reviewer'  "$noise"       'is_reviewer'       'false'
ask '1xp-dorami noise is not a finding'   "$noise"       'is_finding_author' 'false'
ask 'unrelated badge is not a reviewer'   "$other"       'is_reviewer'       'false'
ask 'Codex P1 still a finding author'     "$codex_p1"    'is_finding_author' 'true'

# Mixed thread: Codex finding + Grok P2 + 1xp-dorami noise.
# is_finding_author keeps both authors' badges and drops the chat note.
mixed='['"$codex_p1"','"$grok_p2"','"$noise"']'
got="$(printf '%s' "$mixed" | jq -r "${JQ_REVIEWER_LIB}"'[.[] | select(is_finding_author) | .user.login] | join(",")')"
check 'mixed list keeps Codex P1 + Grok P2' "$got" 'chatgpt-codex-connector[bot],1xp-dorami'
got="$(printf '%s' "$mixed" | jq -r "${JQ_REVIEWER_LIB}"'[.[] | select(is_finding_author) | select(.body|test("!\\[P[0-9] Badge\\]")) | .body | capture("!\\[(?<sev>P[0-9]) Badge\\]") | .sev] | join(",")')"
check 'mixed list severities stay P1,P2' "$got" 'P1,P2'
got="$(printf '%s' "$mixed" | jq -r "${JQ_REVIEWER_LIB}"'[.[] | select(is_reviewer)] | length')"
check 'mixed list reviewer count is Codex+Grok' "$got" '2'
# Codex CLEAN + Grok P2: both are reviewers; only Grok is a finding.
mixed_clean='['"$codex_clean"','"$grok_p2"']'
got="$(printf '%s' "$mixed_clean" | jq -r "${JQ_REVIEWER_LIB}"'[.[] | select(is_finding_author and (.body|test("!\\[P[0-9] Badge\\]")))] | length')"
check 'Codex CLEAN + Grok P2 leaves one finding' "$got" '1'

# Severity stays in the badge ALT — the same capture findings/json use.
got="$(printf '%s' "$grok_p2" | jq -r '.body | capture("!\\[(?<sev>P[0-9]) Badge\\]") | .sev')"
check 'Grok P2 severity from badge alt' "$got" 'P2'
got="$(printf '%s' "$grok_p0" | jq -r '.body | capture("!\\[(?<sev>P[0-9]) Badge\\]") | .sev')"
check 'Grok P0 severity from badge alt' "$got" 'P0'
got="$(printf '%s' "$grok_p4" | jq -r '.body | capture("!\\[(?<sev>P[0-9]) Badge\\]") | .sev')"
check 'Grok P4 severity from badge alt' "$got" 'P4'

# Clean SHA capture — same regex clean_verdicts uses.
got="$(printf '%s' "$grok_clean" | jq -r '.body | capture("Reviewed commit:\\*\\*\\s*`(?<s>[0-9a-f]+)`") | .s')"
check 'Grok clean SHA from Reviewed commit' "$got" 'd94a859dde'

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
