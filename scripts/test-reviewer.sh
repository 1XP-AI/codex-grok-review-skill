#!/usr/bin/env bash
#
# Grok reviews post as 1xp-dorami. Only comments that look like a review count.
# This pins the reviewer predicate so a random 1xp-dorami comment cannot appear
# as a finding, and so a Grok clean / Grok P-badge is accepted the same way as
# Codex. The defs are sourced from the real script — a copy would drift.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$here/codex-grok-review.sh"
[ -f "$src" ] || { echo "cannot find codex-grok-review.sh next to this script" >&2; exit 1; }

# Source the login defaults and the builder from the real script so a
# login change cannot pass here and fail in the wrapper.
eval "$(awk '/^CODEX_LOGIN=/{p=1} p{print} /^JQ_REVIEWER_LIB=/{exit}' "$src")"
JQ_REVIEWER_LIB="$(jq_reviewer_lib)"
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

# --- one spelling of the clean phrase ----------------------------------------
#
# The reviewer gate and the clean-verdict filter used to spell the apostrophe
# differently: `[Dd]idn.t` admitted a curly one, `[Dd]idn't` did not. A comment
# with a typographic apostrophe therefore counted as a review and then produced
# no verdict — "reviewed, nothing filed", which reads as CLEAN. Both now go
# through is_clean_body, so the two answers cannot disagree again.
# U+2019 is built at runtime, not typed: a literal curly quote in shell source
# trips shellcheck SC1112, and this file has to stay lint-clean to run in CI.
rsquo="$(printf '\u2019')"
curly='{"user":{"login":"1xp-dorami"},"body":"Grok Review: Didn'"$rsquo"'t find any major issues.\n\n**Reviewed commit:** `d94a859dde`"}'
ask 'curly apostrophe is a clean body'    "$curly"      '.body | is_clean_body' 'true'
ask 'curly apostrophe is a reviewer'      "$curly"      'is_reviewer'           'true'
ask 'straight apostrophe is a clean body' "$grok_clean" '.body | is_clean_body' 'true'
ask 'a P-badge alone is not a clean body' "$grok_p2"    '.body | is_clean_body' 'false'
ask 'chatter is not a clean body'         "$noise"      '.body | is_clean_body' 'false'
# The invariant behind the shared def: a body that reads as a clean verdict must
# also read as review output. Break it and a Grok clean verdict stops being a
# reviewer at all, which is the same silent hole from the other direction.
for fx in "$codex_clean" "$grok_clean" "$curly" "$grok_p2" "$noise" "$other"; do
  got="$(printf '%s' "$fx" | jq -r "${JQ_REVIEWER_LIB}"'.body
    | (is_clean_body | not) or is_review_body')"
  check 'clean body implies review body' "$got" 'true'
done

# --- the reviews endpoint is read Codex-only ---------------------------------
#
# review_count / latest_review_date / review_shas select on `is_codex`, not
# `is_reviewer`. This pins WHY: a review object carrying only inline comments has
# an empty body, so the body-shaped gate would drop it. Widening the gate instead
# would let a stray Grok review object count as a review — the false "reviewed"
# this tool exists to prevent.
grok_review_obj='{"user":{"login":"1xp-dorami"},"body":"","submitted_at":"2026-01-01T00:00:00Z"}'
codex_review_obj='{"user":{"login":"chatgpt-codex-connector[bot]"},"body":"**Reviewed commit:** `d94a859dde`","submitted_at":"2026-01-01T00:00:00Z"}'
ask 'empty-body Grok review fails is_reviewer' "$grok_review_obj"  'is_reviewer'            'false'
ask 'empty-body Codex review is still Codex'   "$codex_review_obj" '.user.login | is_codex' 'true'
ask 'Grok review object is not Codex'          "$grok_review_obj"  '.user.login | is_codex' 'false'

# --- clean_verdicts runs for real, against a stubbed fetch ---------------------
#
# The function is sourced and its ONE network call is stubbed, so the actual jq
# program runs. That matters: `clean_verdicts` swallows jq errors
# (`2>/dev/null || true`), so a program that fails to compile returns an empty
# list and reads as "no clean verdict" — indistinguishable from a real answer.
#
# It did. `$who` sat unescaped inside a double-quoted jq program, so the SHELL
# expanded it before jq ever saw it: `who=codex` compiled to `if codex == "codex"`,
# jq answered `codex/0 is not defined`, and the caller got nothing. `wait` reads
# `clean_verdicts <repo> <pr> codex` as its strongest exit signal, so that signal
# was dead. Asserting on output rather than on exit status is what pins it.
eval "$(sed -n '/^clean_verdicts() {/,/^}/p' "$src")"
FIXTURES='['"$codex_clean"','"$grok_clean"','"$grok_p2"','"$noise"']'
api_all() { printf '%s' "$FIXTURES"; }

got="$(clean_verdicts fake-repo 1 | cut -f3 | paste -sd, -)"
check 'clean_verdicts all  -> both authors' "$got" 'codex,grok'
got="$(clean_verdicts fake-repo 1 codex | cut -f3 | paste -sd, -)"
check 'clean_verdicts codex -> codex only'  "$got" 'codex'
got="$(clean_verdicts fake-repo 1 grok | cut -f3 | paste -sd, -)"
check 'clean_verdicts grok  -> grok only'   "$got" 'grok'
got="$(clean_verdicts fake-repo 1 codex | cut -f2)"
check 'clean_verdicts keeps the reviewed sha' "$got" 'd94a859dde'

# --- REQUIRED_REVIEWERS: who still owes a verdict ------------------------------
#
# Pure text over a clean_verdicts snapshot. A reviewer is missing when it filed no
# clean verdict, or when its latest one names a commit that is not HEAD.
eval "$(sed -n '/^missing_reviewers() {/,/^}/p' "$src")"
grok_only="$(printf '2026-01-01T00:00:00Z\tabc123\tgrok\n')"
both="$(printf '2026-01-01T00:00:00Z\tabc123\tcodex\n2026-01-02T00:00:00Z\tabc123\tgrok\n')"
stale_codex="$(printf '2026-01-01T00:00:00Z\tdeadbee\tcodex\n')"

# missing_reviewers reads REQUIRED_REVIEWERS as a global. It is defined by the eval
# above, which shellcheck cannot see through, so every assignment here looks unused.
# shellcheck disable=SC2034
REQUIRED_REVIEWERS='codex'
check 'req codex: grok-only clean leaves codex' "$(missing_reviewers "$grok_only" abc123def)"   'codex'
check 'req codex: codex clean on an older sha'  "$(missing_reviewers "$stale_codex" abc123def)" 'codex'
check 'req codex: no verdicts at all'           "$(missing_reviewers "" abc123def)"             'codex'
# shellcheck disable=SC2034
REQUIRED_REVIEWERS='grok'
check 'req grok: grok clean satisfies it'       "$(missing_reviewers "$grok_only" abc123def)"   ''
# shellcheck disable=SC2034
REQUIRED_REVIEWERS='codex grok'
check 'req both: grok alone is not enough'      "$(missing_reviewers "$grok_only" abc123def)"   'codex'
check 'req both: both clean satisfies it'       "$(missing_reviewers "$both" abc123def)"        ''

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
