#!/usr/bin/env bash
# codex-grok-review — read Codex and Grok PR review findings correctly, and request re-reviews.
#
# Why this exists: the obvious `gh` invocations silently omit Codex findings or
# throw away their severity. See README.md for the measured behaviour.
#
# Requires: gh (authenticated), jq.

set -euo pipefail

# Codex still posts as chatgpt-codex-connector[bot] (login startswith this).
# Grok reviews post as 1xp-dorami. Only comments that look like a review count —
# a P-badge or the clean-verdict phrase. Random 1xp-dorami chatter is ignored.
# Override either login via the environment (or by editing these defaults)
# so a different installation does not have to fork the jq filters.
CODEX_LOGIN="${CODEX_LOGIN:-chatgpt-codex-connector}"
GROK_LOGIN="${GROK_LOGIN:-1xp-dorami}"

# jq library spliced into every comment/review filter.
# Built from CODEX_LOGIN / GROK_LOGIN so the two cannot drift.
# is_badge_body     — carries a P0–P4 severity badge
# is_clean_body     — carries the "no major issues" verdict phrase
# is_review_body    — either of the two: this comment is review output, not chatter
# is_reviewer       — Codex login, or Grok login with a review-shaped body
# is_finding_author — Codex login, or Grok login with a P-badge (clean != finding)
#
# The two body shapes are defs rather than inline regexes because they are each
# tested from more than one call site. `clean_verdicts` used to spell the phrase
# `[Dd]idn't` while `is_review_body` spelled it `[Dd]idn.t`, so a curly apostrophe
# passed the reviewer gate and then vanished from the verdict list — the comment
# counted as a review that had produced nothing. One def, one spelling.
jq_reviewer_lib() {
  cat <<EOF
def is_codex: startswith("${CODEX_LOGIN}");
def is_grok: . == "${GROK_LOGIN}";
def is_badge_body: test("!\\\[P[0-9] Badge\\\]");
def is_clean_body: test("[Dd]idn.t find any major issues");
def is_error_body: test("Codex Review: Something went wrong");
def is_review_body: is_badge_body or is_clean_body;
def is_reviewer:
  (.user.login | is_codex)
  or ((.user.login | is_grok) and (.body // "" | is_review_body));
def is_finding_author:
  (.user.login | is_codex)
  or ((.user.login | is_grok) and (.body // "" | is_badge_body));
EOF
}
JQ_REVIEWER_LIB="$(jq_reviewer_lib)"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Which reviewers have to vouch for the newest commit before `status` says 0.
#
# This cannot be read off the PR. "Grok is not installed here" and "Grok has not
# answered yet" look identical over the API — no comment, no review, no reaction —
# so a rule derived from PR data alone has to pick one and be wrong about the
# other. Requiring BOTH broke every Codex-only repository; requiring EITHER let a
# Grok clean stand in for a Codex that never looked. Observed on PR #4 of this
# repo: Codex hit its usage limit and posted nothing, Grok posted a clean naming
# HEAD, and `status` answered REVIEWED, CLEAN / 0 for code Codex had not read.
#
# So it is configuration:
#
#   codex          (default)  Codex must name HEAD. What a repo that installed
#                             this skill on its own has.
#   grok                      Grok must name HEAD.
#   codex grok                BOTH must — space-separated names are AND.
#   either  (or any)          ONE of them is enough.
#
# `either` is not the same as having no policy. It is the rule a repo running both
# bots may genuinely want — whoever gets there first has read the code — and
# without a token for it that policy would have to go back to being inferred from
# the PR, which is what could not be done in the first place. It stands alone:
# "either grok" has no coherent reading, so it is rejected rather than guessed at.
#
# `${VAR-default}`, not `${VAR:-default}`: an explicitly empty value keeps being
# empty and is rejected below. The logins above can take the `:-` form because
# they are cosmetic, but this one decides whether a PR is callable clean, and
# `REQUIRED_REVIEWERS=` silently becoming `codex` is a policy nobody chose.
REQUIRED_REVIEWERS="${REQUIRED_REVIEWERS-codex}"

# Normalise to the tokens the shell actually sees before judging them.
#
# A set-but-blank value — spaces, a tab — is the dangerous case. It matches
# neither `either|any` nor `''`, so it used to reach the validation loop, which
# then iterated ZERO times and passed. `missing_reviewers` ran the same empty
# loop and reported nothing missing, so a blank string read as a satisfied
# policy: any author's HEAD-clean became clean-head/0, which is precisely the
# no-policy behaviour this variable exists to prevent. Counting tokens rather
# than comparing strings catches "", "   ", and "\t" with one rule, and it also
# lets " either " and "codex  grok" mean what they look like.
_req=""
for _r in $REQUIRED_REVIEWERS; do _req="${_req:+$_req }$_r"; done
REQUIRED_REVIEWERS="$_req"
unset _req
[ -n "$REQUIRED_REVIEWERS" ] \
  || die "REQUIRED_REVIEWERS names no reviewer — set 'codex', 'grok', 'codex grok', or 'either'"

case "$REQUIRED_REVIEWERS" in
  either|any) ;;
  *)
    for _r in $REQUIRED_REVIEWERS; do
      case "$_r" in
        codex|grok) ;;
        either|any) die "REQUIRED_REVIEWERS: '$_r' means one-of and cannot be combined — use it on its own" ;;
        # Not a warning. An unrecognised name can never be satisfied, so accepting it
        # would park `status` on partial-clean forever — and `REQUIRED_REVIEWERS=codex,grok`
        # is one token, not two, which is exactly the typo that would do it.
        *) die "REQUIRED_REVIEWERS: unknown reviewer '$_r' (expected 'codex', 'grok', or 'either')" ;;
      esac
    done
    unset _r ;;
esac

# ── Fetch every page as ONE array, then filter ───────────────────────────────
#
# `gh api --paginate --jq EXPR` runs EXPR against each page SEPARATELY and prints
# a result per page. So `[...] | length` answers "100\n91" on a PR with 191 review
# comments, and the arithmetic downstream — `[ "$n" -gt 0 ]` — dies with
# "integer expression expected", taking the VERDICT line with it. It only shows up
# past 100 comments, which is to say on exactly the long-running PRs this loop
# exists for.
#
# `--slurp` cannot be combined with `--jq`, so the merging and the filtering have
# to be separate steps.
#
# Always emits a JSON array, so callers can pipe into jq without guarding: an
# unreachable API becomes "nothing found", never a syntax error mid-pipeline.
api_all() {
  local out errfile err rc=0
  errfile="$(mktemp)"
  out="$(gh api "$1" --paginate --slurp 2>"$errfile")" || rc=$?
  err="$(cat "$errfile" 2>/dev/null || true)"
  rm -f "$errfile"
  if [ "$rc" -ne 0 ]; then
    # A gh too old for --slurp would otherwise look like "no findings" on every
    # PR, which is the most expensive way to be wrong. Name it instead.
    case "$err" in
      *slurp*) die "this gh does not support 'api --slurp' (needs gh >= 2.44). Upgrade gh." ;;
    esac
    # Everything else — 404, auth, rate limit — propagates exactly as it did
    # before this helper existed. Callers that mean to tolerate a failure say so
    # themselves (`|| echo 0`); the rest should still stop.
    printf '%s\n' "$err" >&2
    return "$rc"
  fi
  printf '%s' "$out" | jq '[ .[][] ]'
}

command -v gh >/dev/null || die "gh CLI not found"
command -v jq >/dev/null || die "jq not found"

usage() {
  cat <<'EOF'
codex-grok-review — read Codex and Grok PR review findings, and request re-reviews.

USAGE
  codex-grok-review status <pr>     One-line verdict: has Codex reviewed? any open findings?
  codex-grok-review findings <pr>   Open findings, one line each, with severity + staleness
  codex-grok-review detail <pr>     Open findings in full: rationale, prescribed fix, code
  codex-grok-review detail-all <pr> Same, including stale/outdated findings
  codex-grok-review all <pr>        Every finding including outdated/resolved ones
  codex-grok-review json <pr>       Machine-readable findings (for agents/scripts)
  codex-grok-review request <pr>    Post "@codex review" to trigger a re-review
  codex-grok-review wait <pr>       Block until a review lands after the newest commit
                                    (exits 5 if Codex posts a failure notice instead)

OPTIONS
  -R, --repo OWNER/REPO   Target repo (default: repo of the current directory)

ENVIRONMENT
  CODEX_GROK_REVIEW_CONTEXT  Lines of code context in `detail` (default 12)
  REQUIRED_REVIEWERS         Who must vouch for the newest commit before `status`
                             exits 0. "codex" (default), "grok", "codex grok"
                             (both), or "either" (one of them is enough).
  CODEX_LOGIN / GROK_LOGIN   Reviewer logins, if your installation differs

EXIT CODES (status / findings; wait shares 5)
  0  reviewed, no open findings          2  open findings exist
  3  not reviewed / stale / partial      4  reviewed, but findings are stale-only
  5  codex errored — its last word is a failure notice; re-request

EXAMPLES
  codex-grok-review status 123
  codex-grok-review detail 123
  codex-grok-review request 123 && codex-grok-review wait 123
EOF
}

REPO_ARG=()
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -R|--repo) [ $# -ge 2 ] || die "--repo needs a value"; REPO_ARG=(--repo "$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

[ $# -ge 1 ] || { usage; exit 1; }
CMD="$1"; shift || true

resolve_repo() {
  if [ ${#REPO_ARG[@]} -gt 0 ]; then printf '%s' "${REPO_ARG[1]}"; return; fi
  gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null \
    || die "not in a GitHub repo; pass --repo OWNER/REPO"
}

need_pr() { [ -n "${1:-}" ] || die "missing <pr> (a pull request number)"; }

# Newest commit timestamp on the PR. Findings older than this may be stale.
#
# Derived from the head SHA rather than from the commit LIST, for the reason in
# head_commit_sha below: that list stops at 250.
head_commit_date() {
  # The MAXIMUM commit date, not the head's own.
  #
  # This value only classifies findings that state no commit — the exact signal
  # is the head SHA, which comes from the PR object and is never capped. A
  # watermark, though, must not move backward, and the head's own date can: an
  # imported commit keeps its original timestamp, so a head pushed today can be
  # dated before its ancestors. A finding created after that push then compares
  # as older than the head and is reported as current.
  #
  # The commit list is capped at 250 by GitHub, which is why the SHA is not taken
  # from it. For a monotonic date the cap is acceptable: it can only make the
  # watermark older, which errs toward calling a finding stale rather than
  # inventing an open one.
  api_all "repos/$1/pulls/$2/commits" \
    | jq -r 'map(.commit.committer.date // .commit.author.date) | max // ""'
}

# review id → the commit that review inspected. Every Codex output states it as
#   **Reviewed commit:** `<sha10>`
# which is far better than guessing from timestamps.
review_shas() {
  api_all "repos/$1/pulls/$2/reviews" | jq -r "${JQ_REVIEWER_LIB}[ .[]
          | select(.user.login | is_codex)
          | { key: (.id | tostring),
              value: ((.body | capture(\"Reviewed commit:\\\\*\\\\*\\\\s*\`(?<s>[0-9a-f]+)\`\") | .s) // \"\") }
        ] | from_entries"
}

# All inline review comments authored by the Codex bot, enriched:
#   severity     P0|P1|P2|P3|P4|—   (from the badge image alt text)
#   title        the bolded finding headline
#   rationale    the prose, minus the headline and the "Useful?" footer
#   fix          the prescriptive clause Codex closes with (heuristic)
#   diff_hunk    the code the finding is anchored to
#   reviewed_sha the commit the finding was actually written against
#   stale        true when that commit is NOT the PR's newest
#   anchored     false when GitHub could no longer place it (line == null)
# Findings Codex posts as ISSUE comments rather than review comments.
#
# Most arrive attached to a line of the diff. Some — observed right after a
# failed review attempt, when the bot retries — arrive as a plain PR comment
# instead: a blob permalink, the severity badge, the title, the rationale. This
# reader looked only at review comments, so those counted as "no findings",
# which is the one answer the tool must never get wrong. One such comment among
# 218 on a single PR was a P1.
#
# The permalink carries MORE than the review-comment form: the commit, the path
# and the line are all in the URL, so staleness here is exact rather than dated.
fetch_issue_findings() {
  # $4 (head_date) is optional. `wait` has no date to give — see issue_findings_now.
  local repo="$1" head_sha="$2" head_date="${4:-}"
  api_all "repos/$repo/issues/$3/comments" \
  | jq --arg head "$head_sha" --arg headdate "$head_date" "${JQ_REVIEWER_LIB}"'
      def trim: sub("^\\s+"; "") | sub("\\s+$"; "");
      def _hv: {"0":0,"1":1,"2":2,"3":3,"4":4,"5":5,"6":6,"7":7,"8":8,"9":9,
                "a":10,"b":11,"c":12,"d":13,"e":14,"f":15}[ascii_downcase];
      # Percent-decode, UTF-8 aware.
      #
      # jq has no uridecode, and decoding each escape on its own is worse than not
      # decoding: %ED%95%9C is three BYTES of one character, and implode reads them as
      # three codepoints, so a Korean filename comes out as mojibake that matches nothing.
      # So the escapes are turned into bytes and the bytes are folded back into
      # codepoints the way UTF-8 defines. Literal characters in a URL are ASCII, where
      # byte and codepoint coincide, so explode is the right source for them.
      def uridecode:
        [ scan("%[0-9A-Fa-f]{2}|[\\s\\S]") ]
        | map(if startswith("%") and (length == 3)
              then [ (.[1:2] | _hv) * 16 + (.[2:3] | _hv) ]
              else explode end)
        | add // []
        | reduce .[] as $b ({ cp: 0, need: 0, out: [] };
            if .need > 0 then
              { cp: (.cp * 64 + ($b - 128)), need: (.need - 1), out: .out }
              | if .need == 0 then { cp: 0, need: 0, out: (.out + [.cp]) } else . end
            elif $b < 128    then { cp: 0, need: 0, out: (.out + [$b]) }
            elif $b >= 240   then { cp: ($b - 240), need: 3, out: .out }
            elif $b >= 224   then { cp: ($b - 224), need: 2, out: .out }
            elif $b >= 192   then { cp: ($b - 192), need: 1, out: .out }
            else { cp: 0, need: 0, out: (.out + [$b]) } end)
        | .out | implode;
      # The same prescription heuristic the review-comment branch uses.
      def prescription:
        ([ splits("(?<=\\.)\\s+") ] | map(trim) | map(select(length > 0)) | last // .)
        | (if test("; ") then (split("; ") | last) else . end)
        | trim;
      [ .[]
        | select(is_finding_author)
        | select(.body | test("!\\[P[0-9] Badge\\]"))
        | . as $c
        # Ranged permalinks exist (#L12-L14). Both ends are kept: reporting only
        # the first turns a reviewed range into a single line.
        #
        # And it FALLS BACK, because `capture` emits nothing when it does not
        # match and `as` over an empty stream drops the whole element. Every
        # other field below is guarded with `//`; this one was not, so a
        # badge-carrying comment whose body has no blob permalink disappeared
        # from the list entirely — the CLEAN-over-an-open-P1 answer this reader
        # exists to prevent, arriving by a second route. Measured: three badge
        # comments in, one out.
        #
        # The permalink is a Codex habit, not a contract; nothing makes Grok
        # follow it, and `is_finding_author` now accepts Grok on this endpoint.
        # The Grok fixtures in test-reviewer.sh carry no permalink: they passed
        # the predicate and died here.
        #
        # (No apostrophes in this block. The jq program is a single-quoted shell
        # string, so one ends it — which is how the first draft of this comment
        # broke the whole script.)
        #
        # An unlocated finding is still a finding. `sha: ""` makes it live
        # rather than stale (see the `stale` rule below), so the failure lands
        # on the side of reporting something we cannot place instead of
        # silently reporting nothing.
        #
        # Searched only in the part of the body BEFORE the badge.
        #
        # When a finding cites a repo rule, Codex appends
        #   AGENTS.md reference: [AGENTS.md:L327-L335](.../blob/<sha>/AGENTS.md#L327-L335)
        # which is a blob permalink too. On a body with no code permalink that
        # citation is the FIRST and only match, so the finding got located in
        # AGENTS.md and dated by the cited commit — not HEAD, so it came out
        # STALE and vanished from `status` exactly as being dropped had. Same
        # wrong answer, another route in.
        #
        # Position is the invariant, not the label and not the filename. The
        # documented shape puts the code permalink AHEAD of the badge and the
        # citation after the rationale, so cutting at the badge separates them
        # by construction.
        #
        # Keying on the label instead was measured to fail three ways: a capital
        # `Reference:` (the pattern is case sensitive), a bare `See [...](...)`
        # with no label at all, and any wording a future template picks. Keying
        # on the filename fails differently — the cited file is whatever rules
        # file the repo keeps, and a finding may legitimately be ABOUT AGENTS.md.
        #
        # A permalink that appears only after the badge is therefore not read as
        # a location. That costs nothing that is real and errs toward an
        # unlocated, live finding, which is the direction that blocks a merge
        # rather than hiding one.
        #
        # (No apostrophes in this block. The jq program is a single-quoted shell
        # string, so one ends it.)
        | ($c.body | sub("!\\[P[0-9] Badge\\][\\s\\S]*$"; "")) as $locbody
        | (($locbody | capture("blob/(?<sha>[0-9a-f]{7,40})/(?<path>[^#\\s]+)#L(?<a>[0-9]+)(-L(?<b>[0-9]+))?"))
           // { sha: "", path: "(location unknown)", a: "0", b: null }) as $loc
        # The badge headline appears both wrapped in <sub> and bare. Requiring
        # the wrappers produced "(untitled)" and left the whole heading sitting
        # in the rationale.
        #
        # TWO placements, so two patterns. The badge sits inside the bold run
        # (`**<sub>BADGE</sub> Title**`) or ahead of it (`BADGE **Title**`), and
        # one regex cannot read both: against the second shape, `[^*\n]+` cannot
        # start on the `*` it faces, backtracks onto the single space before it,
        # and captures that space. The title then trims to EMPTY — not even
        # "(untitled)", because an empty string is truthy to `//`. The bare shape
        # is what the grok_p0 and grok_p4 fixtures in test-reviewer.sh look like.
        #
        # Bold-first is tried first: on the wrapped shape it simply does not
        # match, while the wrapped pattern on a bare heading is the case above.
        # `select(length > 0)` on each is what makes `//` fall through a match
        # that came back blank.
        | ((($c.body | capture("!\\[P[0-9] Badge\\]\\([^)]*\\)(</sub>)*\\s*\\*\\*\\s*(?<t>[^*\\n]+)") | .t | trim | select(length > 0))
            // ($c.body | capture("!\\[P[0-9] Badge\\]\\([^)]*\\)(</sub>)*\\s*(?<t>[^*\\n]+)\\*\\*") | .t | trim | select(length > 0))
            // "(untitled)")) as $title
        | ($c.body
           | sub("^[\\s\\S]*?!\\[P[0-9] Badge\\]\\([^)]*\\)(</sub>)*[^\\n]*\\n"; "")
           | sub("\\s*<details>[\\s\\S]*$"; "")
           # The same "Useful? React with..." footer the inline parser drops. Left
           # in, it is the last sentence of the rationale — so `prescription` picks
           # it and `detail` prints "React with thumbs" under FIX, which is the one
           # line of that block a reader acts on.
           | sub("\\s*Useful\\?[\\s\\S]*$"; "")
           | trim) as $rationale
        | {
            id: $c.id,
            review_id: ($c.id | tostring),
            created_at: $c.created_at,
            path: ($loc.path | uridecode),
            line: (($loc.b // $loc.a) | tonumber),
            start_line: (if $loc.b == null then null else ($loc.a | tonumber) end),
            source: "issue",
            anchored: true,
            reviewed_sha: $loc.sha,
            severity: (($c.body | capture("!\\[(?<sev>P[0-9]) Badge\\]") | .sev) // "—"),
            title: $title,
            rationale: $rationale,
            diff_hunk: "",
            body: $c.body,
            url: $c.html_url
          }
        | . + { fix: (.rationale
                      | sub("\\n\\s*[^\\n]*\\breference:[\\s\\S]*$"; "")
                      | trim | prescription) }
        | . + { fix: (if .fix == .rationale or (.fix | length) < 12 then "" else .fix end) }
        # Bound BEFORE the pipe: inside the startswith pipeline the input is
        # $head, a string, and .reviewed_sha would index into it.
        # An unlocated finding has no sha to compare, so without a second signal
        # it is live FOREVER: the author fixes the code, pushes, and `status`
        # still exits 2 until someone deletes the GitHub comment. The review
        # comment parser already falls back to the date for exactly this hole
        # (`created_at < $headdate`); this one was never handed the date.
        #
        # The date is a watermark, not proof, which is why it stays a FALLBACK
        # under the sha: a finding posted after the newest commit date is live, one
        # posted before a later push goes stale rather than blocking every commit
        # after it. With no date at all — `wait`, which does not fetch one — the
        # old always-live reading stands, because calling a finding stale on no
        # evidence is the direction that hides it.
        | . + { stale: (. as $f
                        | if $f.reviewed_sha != "" and $head != ""
                          then ($head | startswith($f.reviewed_sha)) | not
                          elif $headdate != ""
                          then $f.created_at < $headdate
                          else false end) }
      ]'
}

fetch_findings() {
  local repo="$1" pr="$2" head_date="$3" head_sha="$4" shamap extra
  shamap="$(review_shas "$repo" "$pr")"
  # Findings that arrived as issue comments, in the same shape.
  extra="$(fetch_issue_findings "$repo" "$head_sha" "$pr" "$head_date")"
  api_all "repos/$repo/pulls/$pr/comments" | jq -r "${JQ_REVIEWER_LIB}[ .[] | select(is_finding_author) ]" \
  | jq --argjson shas "$shamap" --arg head "$head_sha" --arg headdate "$head_date" '
      def trim: sub("^\\s+"; "") | sub("\\s+$"; "");
      # Codex states what to do in its FINAL SENTENCE, and when that sentence also
      # diagnoses the cause, the prescription follows a semicolon inside it. Take
      # the sentence first, then the clause — the reverse order swallows the whole
      # rationale whenever a semicolon appears early. A heuristic either way; the
      # full rationale is printed alongside, so a bad guess costs nothing.
      def prescription:
        ([ splits("(?<=\\.)\\s+") ] | map(trim) | map(select(length > 0)) | last // .)
        | (if   test("; ")    then (split("; ")    | last)
           elif test(", so ") then (split(", so ") | last)
           else . end)
        | trim;

      [ .[]
        | {
            id, path, diff_hunk,
            line:       (.line // .original_line),
            start_line: (.start_line // .original_start_line),
            source:     "review",
            anchored:   (.line != null),
            created_at,
            url: .html_url,
            review_id: (.pull_request_review_id | tostring),
            # original_commit_id is the commit the review actually inspected, and
            # it never moves. .commit_id DOES move: GitHub drags it forward when
            # it re-anchors the comment, making an old finding look current.
            reviewed_sha: (.original_commit_id // ""),
            severity: ((.body | capture("!\\[(?<sev>P[0-9]) Badge\\]") | .sev) // "—"),
            title: (
              ((.body
                | gsub("<[^>]*>"; "")
                | gsub("!\\[[^]]*\\]\\([^)]*\\)"; "")
                | capture("\\*\\*(?<t>[^*]+)\\*\\*") | .t) // "(untitled)")
              | trim
            ),
            rationale: (
              .body
              | sub("^\\s*\\*\\*[\\s\\S]*?\\*\\*"; "")        # drop the headline
              | sub("\\s*Useful\\?[\\s\\S]*$"; "")            # drop the footer
              | trim
            ),
            body: .body
          }
        # Fall back to the review body hash only if the API field is missing.
        | . + { reviewed_sha: (if .reviewed_sha != "" then .reviewed_sha
                               else ($shas[.review_id] // "") end) }
        # When a finding cites a repo rule, Codex appends a "<file> reference: [link]"
        # footer. Keep it in the rationale as provenance, but drop it before hunting
        # for the prescription — otherwise the citation IS the last "sentence".
        | . + { fix: (.rationale
                      | sub("\\n\\s*[^\\n]*\\breference:[\\s\\S]*$"; "")
                      | trim | prescription) }
        | . + { fix: (if .fix == .rationale or (.fix | length) < 12 then "" else .fix end) }
        | . + {
            # Prefer an exact commit match; fall back to dates only when nothing
            # named a commit. Bind BEFORE piping into $head — a pipe rebinds `.`
            # to the string, and .reviewed_sha would index into it.
            stale: (
              . as $c
              | if $c.reviewed_sha != "" and $head != "" then
                  ($head | startswith($c.reviewed_sha)) | not
                else
                  $c.created_at < $headdate
                end
            )
          }
      ]' \
  | jq --slurpfile extra <(printf '%s' "$extra") '
      # Two sources, one list. A finding is a finding whichever way it arrived.
      #
      # --slurpfile, not --argjson: argv values pass through execve, which caps a
      # SINGLE argument at 128KB on Linux. Each finding carries its whole comment
      # body, so a busy PR crosses that and the merge dies with E2BIG — on the
      # PR that needs it most. A pipe has no such ceiling.
      . + $extra[0] | sort_by(.created_at) | reverse'
}

# Codex leaves NO review object when it has nothing to say — it reacts 👍 on the
# PR instead. So "zero reviews" is ambiguous unless you also check reactions.
has_thumbsup() {
  api_all "repos/$1/issues/$2/reactions" | jq -r "[.[] | select((.user.login | startswith(\"$CODEX_LOGIN\")) and .content == \"+1\")] | length" \
    2>/dev/null || echo 0
}

# A clean review ALSO lands as an issue comment carrying the commit it inspected:
#
#   Codex Review: Didn't find any major issues. Breezy!
#   Grok Review: Didn't find any major issues. 🚀
#   **Reviewed commit:** `d94a859dde`
#
# The sign-off wanders ("Bravo.", "Breezy!", "Keep them coming!", …), so never match
# on it. The `Reviewed commit` hash is the valuable part: unlike a 👍 reaction, it
# proves WHICH commit was reviewed. Emits "<iso8601>\t<sha>\t<who>" per verdict.
# $3 = all|codex|grok (default all). wait stays Codex-only.
#
# The third column is what lets `missing_reviewers` answer per author from ONE
# fetch. Asking clean_verdicts once per reviewer would re-read every issue comment
# on the PR each time, and three reads of the same endpoint can disagree with each
# other — the split-snapshot bug `issue_open_in` exists to avoid.
# TWO ENDPOINTS, one verdict list — the same split findings already have.
#
# A clean verdict arrives either as an issue comment or as the BODY of a review
# object, and which one you get is not yours to choose. Reading only
# `issues/N/comments` therefore reports "no clean verdict" for a PR that was
# cleared, and the caller sees `stale-clean`/3: reviewed code called unreviewed.
#
# Measured on PR #4 of this repo — the same PR that added REQUIRED_REVIEWERS:
#
#   e8949ab, b8b4a65   cleared by issue comment   → seen
#   3b017ea, 227c4ca   cleared by review body     → invisible
#
# `status` put the newest verdict at b8b4a65 and answered stale-clean/3 while
# Grok had in fact cleared HEAD minutes earlier. This is trap 1 and trap 3 of the
# README wearing a different hat: findings are merged from both endpoints, and
# verdicts have to be too.
#
# Review objects date with `submitted_at`, issue comments with `created_at`, so
# the two are normalised to one field before sorting — otherwise the merged list
# orders by whichever key happened to exist and the LATEST verdict is a guess.
# Emits "<iso8601>\t<sha>\t<who>" per verdict; $3 = all|codex|grok (default all).
#
# The third column is what lets `missing_reviewers` answer per author without
# re-fetching. Asking once per reviewer would re-read every comment on the PR
# each time, and repeated reads of one endpoint can disagree with each other —
# the split-snapshot bug `issue_open_in` exists to avoid.
clean_verdicts() {
  local repo="$1" pr="$2" who="${3:-all}" comments reviews
  # Tolerated separately, so one unreachable endpoint cannot blank out the other.
  comments="$(api_all "repos/$repo/issues/$pr/comments" 2>/dev/null || printf '[]')"
  reviews="$(api_all "repos/$repo/pulls/$pr/reviews" 2>/dev/null || printf '[]')"
  printf '%s\n%s\n' "$comments" "$reviews" \
  | jq -rs --arg who "$who" "${JQ_REVIEWER_LIB}[ .[][]
          | select(is_reviewer)
          | select(.body // \"\" | is_clean_body)
          | select(
              if \$who == \"codex\" then (.user.login | is_codex)
              elif \$who == \"grok\" then (.user.login | is_grok)
              else true end)
          | { at: (.submitted_at // .created_at // \"\"),
              sha: ((.body | capture(\"Reviewed commit:\\\\*\\\\*\\\\s*\`(?<s>[0-9a-f]+)\`\") | .s) // \"\"),
              who: (if (.user.login | is_codex) then \"codex\" else \"grok\" end) }
        ] | sort_by(.at) | .[] | \"\\(.at)\\t\\(.sha)\\t\\(.who)\"" 2>/dev/null || true
}

# Codex failure notices — a crash posted where a review pass should have been:
#
#   Codex Review: Something went wrong. Try again later by commenting "@codex review".
#
# To every signal this script already reads, that comment is SILENCE: it carries
# no badge, no clean phrase, no review object — so `status` answered
# "awaiting: codex" and `wait` slept to its full timeout while the bot had
# already said, in prose, that it crashed and wants to be re-asked. Observed on
# solana-world-soccer-2026#688 (issuecomment-5352490610).
#
# Same two-endpoint rule as verdicts: nothing says the notice must stay an issue
# comment, so reviews are merged in too. Emits one normalised ISO8601 timestamp
# per notice, ascending — callers take the tail. Codex-only: Grok has not been
# observed failing this way, and a Grok notice would need its own phrase anyway.
codex_errors() {
  local repo="$1" pr="$2" comments reviews
  # Tolerated separately, so one unreachable endpoint cannot blank out the other.
  comments="$(api_all "repos/$repo/issues/$pr/comments" 2>/dev/null || printf '[]')"
  reviews="$(api_all "repos/$repo/pulls/$pr/reviews" 2>/dev/null || printf '[]')"
  printf '%s\n%s\n' "$comments" "$reviews" \
  | jq -rs "${JQ_REVIEWER_LIB}[ .[][]
          | select(.user.login | is_codex)
          | select(.body // \"\" | is_error_body)
          | (.submitted_at // .created_at // \"\")
        ] | sort | .[]" 2>/dev/null || true
}

# The newest LIVE failure notice, or nothing. One implementation, two callers —
# cmd_status and verdict_for — because the tenth verdict argument is exactly the
# kind of input that gets added to one call site and forgotten in the other
# (it was: `findings` shipped answering not-reviewed/3 on a crash-only PR while
# `status` said codex-errored/5, breaking the shared-exit-code promise — P1 on
# PR #7 of this repo).
#
# A notice is live while it is Codex's latest word. Words: clean verdicts (from
# the snapshot in $3, so the caller's own fetch is reused) and review objects
# that are not themselves the notice (latest_codex_word_date). ISO8601 compares
# correctly as text.
live_codex_error_at() {
  local repo="$1" pr="$2" clean="$3" err_at word
  err_at="$(codex_errors "$repo" "$pr" | tail -n 1)"
  [ -n "$err_at" ] || return 0
  word="$(printf '%s\n' "$clean" | awk -F'\t' '$3 == "codex" { t = $1 } END { print t }')"
  local rw; rw="$(latest_codex_word_date "$repo" "$pr")"
  if [ -n "$rw" ] && { [ -z "$word" ] || [ "$rw" \> "$word" ]; }; then word="$rw"; fi
  if [ -z "$word" ] || [ "$err_at" \> "$word" ]; then printf '%s' "$err_at"; fi
}

# Has $3 filed a clean verdict naming commit $2, given the snapshot $1?
#
# Its LATEST verdict, not any of them: an older blessing does not cover code pushed
# since. Verdicts with no SHA in the body are skipped rather than trusted — they
# prove a review happened, not which commit it read.
reviewer_vouched() {
  local sha
  sha="$(printf '%s\n' "$1" | awk -F'\t' -v w="$3" '$3 == w && $2 != "" { s = $2 } END { print s }')"
  [ -n "$sha" ] && [ -n "$2" ] || return 1
  case "$2" in "$sha"*) return 0 ;; esac
  return 1
}

# Who still owes a clean verdict for commit $2, as text for a human. Empty means
# the REQUIRED_REVIEWERS policy is satisfied.
#
# Pure text over a clean_verdicts snapshot already in hand ($1) — no API call, so
# it cannot disagree with the verdict line rendered beside it.
# Did ANY author clear commit $2, whatever the policy says about it?
#
# Separates the two ways a policy can be unmet, which need opposite advice: some
# reviewer cleared HEAD and we are waiting on another (partial-clean), or nobody
# did and the newest code is genuinely unreviewed (stale-clean → request one).
# The globally-latest verdict cannot tell them apart — it is whoever spoke last,
# which on a dual-bot PR is routinely the one naming an older commit.
head_clean_exists() {
  reviewer_vouched "$1" "$2" codex || reviewer_vouched "$1" "$2" grok
}

missing_reviewers() {
  local clean="$1" head="$2" who out=""
  case "$REQUIRED_REVIEWERS" in
    either|any)
      # One is enough, so the first hit ends it. Nothing is "missing" by name here;
      # what is missing is an answer from anybody, which is what the phrase says.
      for who in codex grok; do
        reviewer_vouched "$clean" "$head" "$who" && return 0
      done
      printf 'codex or grok'
      return 0 ;;
  esac
  for who in $REQUIRED_REVIEWERS; do
    reviewer_vouched "$clean" "$head" "$who" || out="${out:+$out, }$who"
  done
  printf '%s' "$out"
}

# Has any Codex review stated THIS head commit as the one it reviewed?
#
# Exact, and the reason the timestamp comparison below is only a fallback: a
# commit date can be OLDER than its ancestors (an imported commit keeps its
# original date), and a watermark that moves backward makes an existing review
# look like a verdict for code pushed after it.
reviewed_head() {
  local shas count
  shas="$(review_shas "$1" "$2")" || return 1
  # `.value` is bound BEFORE the pipe on purpose: inside `$head | startswith(...)`
  # the input is $head, a string, and `.value` there indexes a string — jq dies,
  # the count comes back empty, and an empty count read as "not zero" reported a
  # verdict that had not landed.
  count="$(printf '%s' "$shas" | jq -r --arg head "$3" '
    [ to_entries[]
      | select((.value | length) > 0)
      | select(.value as $v | $head | startswith($v))
    ] | length')" || return 1
  case "$count" in
    ''|*[!0-9]*) return 1 ;;  # not a number: say "could not tell", never "yes"
    *) printf '%s' "$count" ;;
  esac
}

# How many Codex reviews state NO commit at all.
#
# The count the fallback watches. Counting every review instead let a review that
# names a DIFFERENT commit satisfy it: Codex starts on A, B is pushed, waiting on
# B rejects A by hash and then accepts the same review as "something new arrived".
# A review that names a commit is answered by hash or not at all.
hashless_review_count() {
  local shas
  shas="$(review_shas "$1" "$2")" || return 1
  printf '%s' "$shas" | jq -r '[ to_entries[] | select((.value | length) == 0) ] | length'
}

# How many live issue-comment findings are in a snapshot ALREADY FETCHED.
#
# Counted from the merged list rather than fetched again on purpose. It used to be
# its own API call, which meant two snapshots taken moments apart: a finding landing
# between them produced total=0 with issue_open=1, and that combination fell through
# the verdict table to `clean`, exit 0 — a P1 reported as a clean PR. One snapshot
# cannot disagree with itself.
issue_open_in() {
  printf '%s' "$1" \
    | jq '[ .[] | select(.source == "issue" and .stale == false and .anchored == true) ] | length'
}

# The same count, fetched, for `wait` — which holds no snapshot to be consistent
# with and wants the freshest possible answer to "has anything landed yet".
# One endpoint, so a failure here cannot take down a wait that the review count
# could have answered on its own.
# $4 is the head date, and it may be empty: `wait` deliberately does not fetch one
# (see cmd_wait), so an unlocated finding stays live there and `wait` errs toward
# reporting that something landed.
issue_findings_now() {
  fetch_issue_findings "$1" "$3" "$2" "${4:-}" | jq '[ .[] | select(.stale | not) ] | length'
}

# Full SHA of the PR's newest commit, for matching against `Reviewed commit`.
#
# From the pull-request object, NOT from the commit list. "List commits on a pull
# request" is capped at 250 by GitHub, so on a longer PR the last element is the
# 250th commit and not the head at all — and a clean verdict naming THAT commit
# would then be accepted as covering the newest code. The tool would answer
# "REVIEWED, CLEAN" for code nobody reviewed, which is the one answer it must
# never get wrong.
head_commit_sha() {
  local sha
  # No `|| true`. An unknown head is not an empty head: with it empty, the date
  # below comes back empty too, every older review compares as current, and
  # `status` answers REVIEWED, CLEAN without ever knowing which commit is live.
  # A pull request always has a head, so failing to read one is a failure.
  sha="$(gh api "repos/$1/pulls/$2" -q '.head.sha // ""')" \
    || die "could not read PR #$2 of $1 — refusing to judge a PR whose head is unknown."
  [ -n "$sha" ] || die "PR #$2 of $1 reported no head commit."
  printf '%s' "$sha"
}

# The reviews endpoint is a CODEX-ONLY signal, and `is_codex` — not `is_reviewer` —
# is the predicate for it. `is_reviewer` gates Grok on the comment BODY, but a review
# object that carries only inline comments has `body: ""`, so every Grok review would
# fail that gate and this would report 0. Widening the gate is worse: without the body
# check a stray `1xp-dorami` review object counts as a review, which is the false
# "reviewed" this tool exists to prevent. Grok's evidence reaches `verdict_key` by the
# routes it actually uses — findings (`total`) and clean verdicts (`clean_line`) — so
# nothing is lost by reading this endpoint for Codex alone. `review_shas` does the same.
review_count() {
  api_all "repos/$1/pulls/$2/reviews" | jq -r "${JQ_REVIEWER_LIB}[.[] | select(.user.login | is_codex)] | length" 2>/dev/null || echo 0
}

# The fingerprint `wait` settles on: everything Codex has posted, both ways.
#
# Settling used to key off review submission dates alone. A pass delivered purely as
# issue comments has no review object, so the stamp stayed "" from the first check to
# the last, `latest == settle_prev` on entry, and the loop slept zero times — which
# is precisely the case that made `wait` return a partial set. Codex has been seen
# splitting one pass across posts seconds apart, so a second P1 could land just after
# the report. Any new post of either kind now changes this string.
activity_stamp() {
  printf '%s|%s' \
    "$(latest_review_date "$1" "$2")" \
    "$(api_all "repos/$1/issues/$2/comments" \
       | jq -r "${JQ_REVIEWER_LIB}"'
           [ .[]
             | select(is_reviewer)
             | select(.body | test("!\\[P[0-9] Badge\\]") or test("major issues"))
             | .created_at ]
           | "\(length):\(max // "")"' 2>/dev/null)"
}

# Codex-only for the same reason as review_count above — and here it also matters
# that the value feeds `activity_stamp`, which only `wait` reads, and `wait` is
# Codex-only by design.
latest_review_date() {
  api_all "repos/$1/pulls/$2/reviews" | jq -r "${JQ_REVIEWER_LIB}[.[] | select(.user.login | is_codex) | .submitted_at] | max // \"\"" 2>/dev/null
}

# Codex's newest review object that is NOT itself a failure notice.
#
# The liveness check must not use latest_review_date: a notice delivered as a
# REVIEW OBJECT (the merged-endpoint shape codex_errors exists for) would then
# be its own superseding "later word" — err_at == latest, the > check false,
# err_live 0 — and with review_count now 1 and nothing filed, the verdict walks
# to clean/0 over a crash (P1 on PR #7 of this repo, reproduced). A word is a
# word only if it is not the scream.
latest_codex_word_date() {
  api_all "repos/$1/pulls/$2/reviews" \
  | jq -r "${JQ_REVIEWER_LIB}[.[]
        | select(.user.login | is_codex)
        | select(.body // \"\" | is_error_body | not)
        | .submitted_at] | max // \"\"" 2>/dev/null
}

cmd_json() {
  local repo pr head head_sha
  repo="$(resolve_repo)"; pr="$1"; head="$(head_commit_date "$repo" "$pr")"; head_sha="$(head_commit_sha "$repo" "$pr")"
  fetch_findings_settled "$repo" "$pr" "$head" "$head_sha"
}

# THE verdict. One decision site, deliberately.
#
# `status` and `findings` both publish exit codes, and the help text promises they are
# the same codes. They were not: `findings` returned 0 with open findings on screen, so
# a merge gate written as `codex-grok-review.sh findings N && merge` merged straight through
# them. Two copies of a rule this fiddly will drift again, so there is one copy, and
# `status` renders its messages from the key rather than re-deciding.
#
# Echoes a key; returns the exit code that goes with it.
verdict_key() {
  local open="$1" total="$2" reviews="$3" thumbs="$4" clean_line="$5" \
        head_clean_exists="$6" clean_sha="$7" issue_open="$8" \
        missing_required="${9:-1}" codex_errored="${10:-0}"

  # THE clean test, and it asks the policy — not the newest verdict on the PR.
  #
  # `clean_matches_head` is derived from the LAST LINE of the all-author verdict
  # list, so it answers "did whoever spoke most recently name HEAD". That is the
  # wrong question the moment two bots are involved: Codex clears HEAD, Grok then
  # posts a late clean for an older commit, and the global-latest SHA goes stale
  # while the policy is fully satisfied. Gating on it returned stale-clean/3 and
  # blocked a PR that `REQUIRED_REVIEWERS=codex` had already accepted — the exact
  # delayed-second-reviewer race a dual-bot reader exists to survive.
  #
  # missing_required is per author and already asks each one's own latest verdict,
  # so it is the authority. It defaults to 1: an unknown policy state must never
  # be read as clean.
  if [ "$open" -eq 0 ] && [ "$missing_required" -eq 0 ]; then
    echo clean-head; return 0
  fi

  # A failure notice as Codex's last word outranks every flavour of "waiting":
  # not-reviewed, stale-clean and partial-clean all counsel patience or a fresh
  # request, and patience is exactly wrong when the bot has already said it
  # crashed. Open findings still outrank the error — they are actionable
  # without Codex — which is why this sits inside the open==0 world.
  if [ "$open" -eq 0 ] && [ "$codex_errored" -eq 1 ]; then
    echo codex-errored; return 5
  fi

  # `total`, not just `issue_open`. An issue-comment finding leaves no review
  # object, so once it goes stale every other trace of that review is gone and
  # this reported not-reviewed — sending the caller to request a review that
  # already happened, and losing the all-stale verdict that says "check these
  # were addressed". A finding on the PR is evidence a review produced it,
  # whether or not it still points at the newest commit.
  if [ "$reviews" -eq 0 ] && [ "$thumbs" -eq 0 ] && [ -z "$clean_line" ] \
     && [ "${issue_open:-0}" -eq 0 ] && [ "$total" -eq 0 ]; then
    echo not-reviewed; return 3
  fi

  if [ "$open" -eq 0 ]; then
    # Reached only with the policy unmet, so both of these say "not clear yet" and
    # differ in what to do about it. Someone HAS cleared HEAD, just not everyone
    # required → wait for the other reviewer. Nobody has → the newest code is
    # unreviewed and needs a re-review requested.
    if [ "$head_clean_exists" -eq 1 ]; then
      echo partial-clean; return 3
    fi
    if [ -n "$clean_sha" ]; then
      echo stale-clean; return 3
    fi
    if [ "$total" -gt 0 ]; then echo all-stale; return 4; fi
    # A live issue finding with an empty list behind it is a contradiction, and it
    # is reachable only if the two numbers came from different fetches. They do not
    # any more — `issue_open` is counted out of the same snapshot as `open`. Should
    # that ever stop being true, this reports uncertainty rather than the CLEAN it
    # used to fall through to with a P1 sitting on the PR.
    if [ "${issue_open:-0}" -gt 0 ]; then echo inconsistent; return 3; fi
    echo clean; return 0
  fi

  echo open; return 2
}

# The findings snapshot, taken so a review landing mid-read cannot look like none.
#
# Two endpoints read in sequence, and the ORDER decides which way the race falls.
# Findings-then-reviews was the dangerous direction: a review landing between them
# left an empty finding list beside a nonzero review count, which walks the verdict
# table straight to `clean`/0 — a merge permitted over findings that were arriving
# as we looked. Reviews-then-findings fails the safe way instead: the count is the
# older one and the findings are the newer, so anything that landed is IN the list.
#
# The reorder closes the window in the common case. It cannot close it entirely —
# the two endpoints are separately consistent, so a review can still be visible
# before its own comments are — which is what the re-read is for. Codex files a
# review object only when it has something to say, so "a review, and nothing to
# say" is not a resting state; seeing it means we looked too early.
# $5 is the review count, if the caller already has one. It must have been read
# BEFORE this call — that is the whole point — so anything that decides a verdict
# reads it once, up front, and hands it down. Reading it again afterwards would
# put the newest count beside the older findings and restore the bug.
fetch_findings_settled() {
  local repo="$1" pr="$2" head="$3" head_sha="$4" reviews="${5:-}" json total

  [ -n "$reviews" ] || reviews="$(review_count "$repo" "$pr")"
  json="$(fetch_findings "$repo" "$pr" "$head" "$head_sha")"
  total="$(printf '%s' "$json" | jq 'length')"

  if [ "$total" -eq 0 ] && [ "${reviews:-0}" -gt 0 ]; then
    json="$(fetch_findings "$repo" "$pr" "$head" "$head_sha")"
  fi

  printf '%s' "$json"
}

# Every input `verdict_key` needs, gathered from the API. Kept next to it so a new
# input cannot be added to one and forgotten in the other.
verdict_for() {
  local repo="$1" pr="$2" head_sha="$3" json="$4" reviews="$5"
  local open total thumbs clean clean_line clean_sha matches missing

  open="$(printf '%s' "$json" | jq '[.[] | select(.stale == false and .anchored == true)] | length')"
  total="$(printf '%s' "$json" | jq 'length')"
  thumbs="$(has_thumbsup "$repo" "$pr")"
  clean="$(clean_verdicts "$repo" "$pr")"
  clean_line="$(printf '%s' "$clean" | tail -n 1)"
  clean_sha="$(printf '%s' "$clean_line" | cut -f2)"
  # Not "did the newest verdict name HEAD" — "did anyone". See head_clean_exists.
  matches=0
  if head_clean_exists "$clean" "$head_sha"; then matches=1; fi
  # Counted off the snapshot already fetched, never re-read — see missing_reviewers.
  missing="$(missing_reviewers "$clean" "$head_sha")"
  # The tenth argument, from the SAME helper cmd_status uses — see
  # live_codex_error_at for why this cannot be inlined in only one caller.
  local err_live=0
  [ -n "$(live_codex_error_at "$repo" "$pr" "$clean")" ] && err_live=1

  verdict_key "$open" "$total" "$reviews" "$thumbs" "$clean_line" "$matches" \
    "$clean_sha" "$(issue_open_in "$json")" "$([ -n "$missing" ] && echo 1 || echo 0)" \
    "$err_live"
}

print_findings() {
  local repo pr head head_sha all json count code reviews
  repo="$(resolve_repo)"; pr="$1"; all="${2:-open}"; head="$(head_commit_date "$repo" "$pr")"; head_sha="$(head_commit_sha "$repo" "$pr")"
  # BEFORE the findings, and read once. See fetch_findings_settled.
  reviews="$(review_count "$repo" "$pr")"
  json="$(fetch_findings_settled "$repo" "$pr" "$head" "$head_sha" "$reviews")"

  # Decided on the UNFILTERED list, before `open` mode throws the stale ones away —
  # "all stale" and "none at all" are different verdicts and both look empty after.
  code=0
  if [ "$all" = "open" ]; then
    verdict_for "$repo" "$pr" "$head_sha" "$json" "$reviews" >/dev/null || code=$?
    json="$(printf '%s' "$json" | jq '[.[] | select(.stale == false and .anchored == true)]')"
  fi

  count="$(printf '%s' "$json" | jq 'length')"
  if [ "$count" -eq 0 ]; then
    if [ "$all" = "open" ]; then echo "No open Codex findings."; else echo "No Codex findings at all."; fi
    return "$code"
  fi

  printf '%s' "$json" | jq -r '
    sort_by([.path, (.line // 0)])
    | .[]
    | . + {
        loc: (if (.start_line != null and .start_line != .line)
              then "\(.start_line)-\(.line)" else "\(.line)" end),
        staleNote: (
          if .stale | not then ""
          elif .reviewed_sha != "" then "  (STALE — reviewed \(.reviewed_sha[0:10]))"
          else "  (STALE — predates newest commit)"
          end
        ),
        anchorNote: (if .anchored then "" else "  (OUTDATED — code removed)" end)
      }
    | "[\(.severity)] \(.path):\(.loc)\(.staleNote)\(.anchorNote)\n" +
      "      \(.title)\n" +
      "      \(.url)\n"'

  return "$code"
}

# Everything you need to act on a finding, without opening the browser: the
# reasoning, what Codex wants changed, and the code it is pointing at. Grouped by
# file and ordered by line, so each file is opened once.
cmd_detail() {
  local repo pr head head_sha all json count ctx
  repo="$(resolve_repo)"; pr="$1"; all="${2:-open}"
  ctx="${CODEX_GROK_REVIEW_CONTEXT:-${CODEX_REVIEW_CONTEXT:-12}}"; head="$(head_commit_date "$repo" "$pr")"; head_sha="$(head_commit_sha "$repo" "$pr")"
  json="$(fetch_findings_settled "$repo" "$pr" "$head" "$head_sha")"

  if [ "$all" = "open" ]; then
    json="$(printf '%s' "$json" | jq '[.[] | select(.stale == false and .anchored == true)]')"
  fi

  count="$(printf '%s' "$json" | jq 'length')"
  if [ "$count" -eq 0 ]; then
    if [ "$all" = "open" ]; then echo "No open Codex findings."; else echo "No Codex findings at all."; fi
    return
  fi

  printf '%s' "$json" | jq -r --argjson ctx "$ctx" '
    # Greedy word wrap. jq has no formatter, so build lines by folding words.
    def wrap($w; $ind):
      [ splits("\\s+") ] | map(select(length > 0))
      | reduce .[] as $x ([];
          if length == 0 then [$x]
          elif ((.[-1] | length) + 1 + ($x | length)) <= $w then (.[0:-1] + [.[-1] + " " + $x])
          else . + [$x] end)
      | map($ind + .) | join("\n");
    def wrapblock($w; $ind):
      [ splits("\n\n+") ] | map(select(length > 0) | wrap($w; $ind)) | join("\n\n");

    sort_by([.path, (.line // 0)])
    | .[]
    | (if (.start_line != null and .start_line != .line)
       then "\(.start_line)-\(.line)" else "\(.line)" end) as $loc
    | (if .stale | not then ""
       elif .reviewed_sha != "" then "   ⚠ STALE — written against \(.reviewed_sha[0:10])"
       else "   ⚠ STALE — predates the newest commit" end) as $stale
    | (if .anchored then "" else "   ⚠ OUTDATED — GitHub could not re-anchor it" end) as $anchor
    # GitHub ends the hunk AT the commented line, so the tail is the relevant
    # context and its final line is the finding itself — marked with »».
    # An issue-comment finding carries no hunk — its permalink is the anchor.
    # Splitting "" yields [""], and the renderer then produced a code block
    # holding one blank marker line, which reads as if the finding pointed at
    # nothing at all.
    | (if (.diff_hunk | length) == 0 then null else (.diff_hunk | split("\n")) end) as $h
    | (if $h == null then "        (no diff hunk — the link below is the anchor)"
       else (($h | length) as $n
         | ((if $n > $ctx then ["        …"] + ($h[$n-$ctx:] | map("        " + .))
             else ($h | map("        " + .)) end)
            | .[0:-1] + [ (.[-1] | sub("^        "; "     »» ")) ] | join("\n")))
       end) as $code
    | "────────────────────────────────────────────────────────────────────────\n"
      + "[\(.severity)]  \(.path):\($loc)\($stale)\($anchor)\n"
      + "       \(.title)\n\n"
      + "  WHY  \(.rationale | wrapblock(66; "       ") | ltrimstr("       "))\n"
      + (if .fix != "" then "\n  FIX  \(.fix | wrap(66; "       ") | ltrimstr("       "))\n" else "" end)
      + "\n  CODE\n\($code)\n"
      + "\n  LINK \(.url)\n"'
}

cmd_status() {
  local repo pr head head_sha json open blocking reviews thumbs latest issue_open
  local clean clean_line clean_sha clean_at clean_matches_head sev_counts missing
  repo="$(resolve_repo)"; pr="$1"
  head="$(head_commit_date "$repo" "$pr")"; head_sha="$(head_commit_sha "$repo" "$pr")"
  # BEFORE the findings, and read once. A review landing between the two reads
  # used to leave an empty list beside a nonzero count, which reads as CLEAN.
  reviews="$(review_count "$repo" "$pr")"
  json="$(fetch_findings_settled "$repo" "$pr" "$head" "$head_sha" "$reviews")"
  open="$(printf '%s' "$json" | jq '[.[] | select(.stale == false and .anchored == true)] | length')"
  blocking="$(printf '%s' "$json" | jq '[.[] | select(.stale == false and .anchored == true and (.severity == "P0" or .severity == "P1"))] | length')"
  sev_counts="$(printf '%s' "$json" | jq -r '
    [.[] | select(.stale == false and .anchored == true) | .severity]
    | group_by(.) | map("\(.[0]):\(length)") | join(" ")')"
  # An issue-comment finding is evidence a review happened even when no review
  # object exists — otherwise `status` reports "not reviewed yet" while a P1 it
  # just listed sits on the PR.
  issue_open="$(issue_open_in "$json")"
  thumbs="$(has_thumbsup "$repo" "$pr")"
  # Displayed, not compared — the settle fingerprint is a different thing and
  # printing it would put an opaque count in front of a human.
  latest="$(latest_review_date "$repo" "$pr")"

  clean="$(clean_verdicts "$repo" "$pr")"
  local err_at err_live
  err_at="$(live_codex_error_at "$repo" "$pr" "$clean")"
  err_live=0; [ -n "$err_at" ] && err_live=1
  clean_line="$(printf '%s' "$clean" | tail -n 1)"
  clean_at="$(printf '%s' "$clean_line" | cut -f1)"
  clean_sha="$(printf '%s' "$clean_line" | cut -f2)"
  clean_matches_head=0
  if head_clean_exists "$clean" "$head_sha"; then clean_matches_head=1; fi
  # Same snapshot as the verdict line above, so the two cannot disagree.
  missing="$(missing_reviewers "$clean" "$head_sha")"

  echo "PR #$pr  ($repo)"
  echo "  newest commit : ${head:-unknown}  ${head_sha:0:10}"
  echo "  codex reviews : $reviews${latest:+  (latest $latest)}"
  echo "  codex 👍       : $thumbs"
  [ "$err_live" -eq 1 ] && echo "  codex error   : ⚠ failure notice at ${err_at} — nothing from codex since"
  if [ -n "$clean_sha" ]; then
    echo "  clean verdict : yes — reviewed commit ${clean_sha}  ($clean_at)"
  elif [ -n "$clean_line" ]; then
    echo "  clean verdict : yes — but no commit hash in the comment"
  else
    echo "  clean verdict : none"
  fi
  # Named, not just counted: "which reviewer still owes a verdict" is the whole
  # question this line answers, and the answer is what you act on.
  echo "  required      : ${REQUIRED_REVIEWERS}${missing:+  (awaiting: $missing)}"
  echo "  open findings : $open${sev_counts:+  ($sev_counts)}"

  # The decision itself lives in verdict_key. Everything below renders it.
  local key code total
  code=0
  key="$(verdict_key "$open" "$(printf '%s' "$json" | jq 'length')" "$reviews" "$thumbs" \
        "$clean_line" "$clean_matches_head" "$clean_sha" "${issue_open:-0}" \
        "$([ -n "$missing" ] && echo 1 || echo 0)" "$err_live")" || code=$?
  total="$(printf '%s' "$json" | jq 'length')"

  case "$key" in
    clean-head)
      echo "  VERDICT       : REVIEWED, CLEAN — verdict names the newest commit." ;;
    not-reviewed)
      echo "  VERDICT       : NOT REVIEWED — no review, no 👍, no clean verdict."
      echo "                  Trigger one:  codex-grok-review request $pr" ;;
    codex-errored)
      echo "  VERDICT       : CODEX ERRORED — its last word is a failure notice (${err_at})."
      echo "                  It asked to be re-asked:  codex-grok-review request $pr" ;;
    stale-clean)
      echo "  VERDICT       : STALE CLEAN VERDICT — it names ${clean_sha}, not the newest commit."
      echo "                  Newer commits are unreviewed:  codex-grok-review request $pr" ;;
    all-stale)
      echo "  VERDICT       : REVIEWED — $total finding(s), all stale/outdated."
      echo "                  Confirm they are addressed, then merge." ;;
    clean)
      echo "  VERDICT       : REVIEWED, CLEAN." ;;
    partial-clean)
      echo "  VERDICT       : PARTIAL CLEAN — no clean verdict for the newest commit from:"
      echo "                  ${missing}."
      echo "                  REQUIRED_REVIEWERS is \"${REQUIRED_REVIEWERS}\". Use 'either' if one"
      echo "                  reviewer naming HEAD should be enough." ;;
    inconsistent)
      echo "  VERDICT       : INCONSISTENT — an issue-comment finding is live but the"
      echo "                  finding list is empty. Re-run; do not read this as clean." ;;
    open)
      echo "  VERDICT       : $open OPEN FINDING(S) — address before merging."
      [ "$blocking" -gt 0 ] && echo "                  ⚠ $blocking of them are P0/P1." ;;
    *)
      die "internal: unknown verdict key '$key'" ;;
  esac
  return "$code"
}

cmd_request() {
  local repo pr; repo="$(resolve_repo)"; pr="$1"
  gh pr comment "$pr" --repo "$repo" --body "@codex review" >/dev/null
  echo "Requested a Codex re-review on PR #$pr."
  echo "Note: a re-review typically takes several minutes."
  echo "Then:  codex-grok-review status $pr"
}

# Let a review pass go quiet before reporting it.
#
# Codex has been observed splitting one pass across posts seconds apart, so
# returning on the first post reports a subset — and a caller whose merge rule is
# "no P1" can be shown "P1: 0" while a P1 is still in flight.
settle_and_report() {
  local repo="$1" pr="$2" latest="$3" settle_prev="" settle_tries=0
  while [ "$settle_tries" -lt "$settle_max" ] && [ "$latest" != "$settle_prev" ]; do
    settle_prev="$latest"
    sleep "$settle_secs"
    latest="$(activity_stamp "$repo" "$pr")"
    settle_tries=$((settle_tries + 1))
  done
  # The stamp is a fingerprint, not a timestamp — say that something moved, not what.
  [ "$latest" != "$settle_prev" ] && echo "(more arrived while settling — reporting the full set)"
  cmd_status "$pr" || true
  return 0
}

cmd_wait() {
  # No head_commit_date here: every check below uses the head SHA or the
  # hashless-review count, so calling it only added an endpoint whose failure
  # could stop a wait that did not need it.
  local repo pr deadline interval elapsed reviews thumbs latest
  repo="$(resolve_repo)"; pr="$1"
  # Snapshot BEFORE the head lookups. A hashless review landing while those
  # requests are in flight would otherwise be indistinguishable from one that was
  # already there, and this command would wait out its whole timeout for it.
  local reviews_at_entry reviews_now
  reviews_at_entry="$(hashless_review_count "$repo" "$pr")" \
    || die "could not read the reviews of PR #$pr in $repo."
  # Failure-notice watermark. Only a NEW notice ends the wait: one that predates
  # this command was already reported by `status`, and the caller chose to wait
  # anyway — presumably having just re-requested.
  local err_at_entry err_now
  err_at_entry="$(codex_errors "$repo" "$pr" | tail -n 1)"
  deadline="${CODEX_GROK_REVIEW_TIMEOUT:-${CODEX_REVIEW_TIMEOUT:-1800}}"
  interval="${CODEX_GROK_REVIEW_INTERVAL:-${CODEX_REVIEW_INTERVAL:-60}}"
  # A review pass is not always one post — Codex has been observed splitting
  # one pass across posts seconds apart. Returning on the first post reports a
  # subset, and a caller whose merge rule is "no P1" can be shown "P1: 0" while
  # a P1 is still in flight. Let the stream go quiet before reporting.
  settle_secs="${CODEX_GROK_REVIEW_SETTLE_SECONDS:-${CODEX_REVIEW_SETTLE_SECONDS:-45}}"
  settle_max="${CODEX_GROK_REVIEW_SETTLE_MAX_TRIES:-${CODEX_REVIEW_SETTLE_MAX_TRIES:-4}}"
  elapsed=0
  local head_sha clean_sha reviewed_n issue_n
  head_sha="$(head_commit_sha "$repo" "$pr")"
  echo "Waiting for a Codex verdict on ${head_sha:0:10} (timeout ${deadline}s)..."
  while [ "$elapsed" -lt "$deadline" ]; do
    # Strongest signal: a clean verdict naming this exact commit.
    clean_sha="$(clean_verdicts "$repo" "$pr" codex | tail -n 1 | cut -f2)"
    if [ -n "$clean_sha" ] && [ -n "$head_sha" ] \
       && case "$head_sha" in "$clean_sha"*) true ;; *) false ;; esac; then
      echo "Clean verdict for ${clean_sha}."
      cmd_status "$pr" || true
      return 0
    fi
    # A crash instead of a review. Without this check the notice is invisible to
    # every signal below — no badge, no verdict, no review object — and `wait`
    # sleeps out its full timeout on a bot that already said it will not answer.
    # Exit 5 so a driving loop can distinguish "re-request" from "genuinely slow".
    err_now="$(codex_errors "$repo" "$pr" | tail -n 1)"
    if [ -n "$err_now" ] && [ "$err_now" != "$err_at_entry" ]; then
      echo "Codex ERRORED instead of reviewing (${err_now}) — it asked to be re-requested."
      cmd_status "$pr" || true
      return 5
    fi
    # A review that names this commit — exact, whatever the clocks say.
    # A lookup that FAILED is not a lookup that found nothing. Swallowing it here
    # made `wait` spin to its 1800s timeout printing the same error each round,
    # when the honest answer was available on the first try.
    reviewed_n="$(reviewed_head "$repo" "$pr" "$head_sha")" \
      || die "could not read the reviews of PR #$pr in $repo."
    # A finding can arrive as an ISSUE comment with no review object behind it.
    # Only asked when the reviews have not already answered: a failing second
    # endpoint must not throw away a review this loop has just recognised and send
    # the caller back to waiting for something that already landed.
    if [ -n "$head_sha" ] && [ "${reviewed_n:-0}" -eq 0 ]; then
      issue_n="$(issue_findings_now "$repo" "$pr" "$head_sha")" \
        || die "could not read the comments of PR #$pr in $repo."
    else
      issue_n=0
    fi
    if [ -n "$head_sha" ] && { [ "${reviewed_n:-0}" -gt 0 ] || [ "${issue_n:-0}" -gt 0 ]; }; then
      latest="$(activity_stamp "$repo" "$pr")"
      echo "Review landed."
      settle_and_report "$repo" "$pr" "$latest"
      return $?
    fi
    # Fallback for a review that states no commit at all: has one APPEARED since
    # this command started? Counted, not timed. GitHub's submitted_at has
    # one-second resolution, so a review arriving in the same second as the
    # watermark compared equal and was ignored until the timeout — and any
    # timestamp watermark has some version of that edge. A count does not.
    reviews_now="$(hashless_review_count "$repo" "$pr")" \
      || die "could not read the reviews of PR #$pr in $repo."
    if [ "${reviews_now:-0}" -gt "${reviews_at_entry:-0}" ]; then
      latest="$(activity_stamp "$repo" "$pr")"
      echo "Review landed."
      settle_and_report "$repo" "$pr" "$latest"
      return $?
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  # A 👍 alone is untimestamped and cannot vouch for a specific commit, so it is
  # never treated as success here — only reported.
  thumbs="$(has_thumbsup "$repo" "$pr")"
  [ "$thumbs" -gt 0 ] && echo "(a 👍 reaction exists, but it is untimestamped — it cannot prove which commit was reviewed)" >&2
  echo "Timed out after ${deadline}s with no new review." >&2
  return 1
}

case "$CMD" in
  status)   need_pr "${1:-}"; cmd_status "$1" ;;
  findings) need_pr "${1:-}"; print_findings "$1" open ;;
  detail)     need_pr "${1:-}"; cmd_detail "$1" open ;;
  detail-all) need_pr "${1:-}"; cmd_detail "$1" all ;;
  all)      need_pr "${1:-}"; print_findings "$1" all ;;
  json)     need_pr "${1:-}"; cmd_json "$1" ;;
  request)  need_pr "${1:-}"; cmd_request "$1" ;;
  wait)     need_pr "${1:-}"; cmd_wait "$1" ;;
  -h|--help|help) usage ;;
  *) die "unknown command: $CMD (try --help)" ;;
esac
