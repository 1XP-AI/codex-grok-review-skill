#!/usr/bin/env bash
# codex-review — read Codex PR review findings correctly, and request re-reviews.
#
# Why this exists: the obvious `gh` invocations silently omit Codex findings or
# throw away their severity. See README.md for the measured behaviour.
#
# Requires: gh (authenticated), jq.

set -euo pipefail

BOT="chatgpt-codex-connector"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

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
codex-review — read Codex PR review findings, and request re-reviews.

USAGE
  codex-review status <pr>     One-line verdict: has Codex reviewed? any open findings?
  codex-review findings <pr>   Open findings, one line each, with severity + staleness
  codex-review detail <pr>     Open findings in full: rationale, prescribed fix, code
  codex-review detail-all <pr> Same, including stale/outdated findings
  codex-review all <pr>        Every finding including outdated/resolved ones
  codex-review json <pr>       Machine-readable findings (for agents/scripts)
  codex-review request <pr>    Post "@codex review" to trigger a re-review
  codex-review wait <pr>       Block until a review lands after the newest commit

OPTIONS
  -R, --repo OWNER/REPO   Target repo (default: repo of the current directory)

ENVIRONMENT
  CODEX_REVIEW_CONTEXT    Lines of code context in `detail` (default 12)

EXIT CODES (status / findings)
  0  reviewed, no open findings          2  open findings exist
  3  not reviewed yet                    4  reviewed, but findings are stale-only

EXAMPLES
  codex-review status 123
  codex-review detail 123
  codex-review request 123 && codex-review wait 123
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
  api_all "repos/$1/pulls/$2/reviews" | jq -r "[ .[]
          | select(.user.login | startswith(\"$BOT\"))
          | { key: (.id | tostring),
              value: ((.body | capture(\"Reviewed commit:\\\\*\\\\*\\\\s*\`(?<s>[0-9a-f]+)\`\") | .s) // \"\") }
        ] | from_entries"
}

# All inline review comments authored by the Codex bot, enriched:
#   severity     P1|P2|P3|—   (from the badge image alt text)
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
  local repo="$1" head_sha="$2"
  api_all "repos/$repo/issues/$3/comments" \
  | jq --arg head "$head_sha" --arg bot "$BOT" '
      def trim: sub("^\\s+"; "") | sub("\\s+$"; "");
      # The same prescription heuristic the review-comment branch uses.
      def prescription:
        ([ splits("(?<=\\.)\\s+") ] | map(trim) | map(select(length > 0)) | last // .)
        | (if test("; ") then (split("; ") | last) else . end)
        | trim;
      [ .[]
        | select(.user.login | startswith($bot))
        | select(.body | test("!\\[P[0-9] Badge\\]"))
        | . as $c
        # Ranged permalinks exist (#L12-L14). Both ends are kept: reporting only
        # the first turns a reviewed range into a single line.
        | ($c.body | capture("blob/(?<sha>[0-9a-f]{7,40})/(?<path>[^#\\s]+)#L(?<a>[0-9]+)(-L(?<b>[0-9]+))?")) as $loc
        # The badge headline appears both wrapped in <sub> and bare. Requiring
        # the wrappers produced "(untitled)" and left the whole heading sitting
        # in the rationale.
        | (($c.body | capture("!\\[P[0-9] Badge\\]\\([^)]*\\)(</sub>)*\\s*(?<t>[^*\\n]+)\\*\\*") | .t | trim) // "(untitled)") as $title
        | ($c.body
           | sub("^[\\s\\S]*?!\\[P[0-9] Badge\\]\\([^)]*\\)(</sub>)*[^\\n]*\\n"; "")
           | sub("\\s*<details>[\\s\\S]*$"; "")
           | trim) as $rationale
        | {
            id: $c.id,
            review_id: ($c.id | tostring),
            created_at: $c.created_at,
            path: $loc.path,
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
        | . + { stale: (. as $f
                        | if $f.reviewed_sha != "" and $head != ""
                          then ($head | startswith($f.reviewed_sha)) | not
                          else false end) }
      ]'
}

fetch_findings() {
  local repo="$1" pr="$2" head_date="$3" head_sha="$4" shamap extra
  shamap="$(review_shas "$repo" "$pr")"
  # Findings that arrived as issue comments, in the same shape.
  extra="$(fetch_issue_findings "$repo" "$head_sha" "$pr")"
  api_all "repos/$repo/pulls/$pr/comments" | jq -r "[ .[] | select(.user.login | startswith(\"$BOT\")) ]" \
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
  | jq --argjson extra "$extra" '
      # Two sources, one list. A finding is a finding whichever way it arrived.
      . + $extra | sort_by(.created_at) | reverse'
}

# Codex leaves NO review object when it has nothing to say — it reacts 👍 on the
# PR instead. So "zero reviews" is ambiguous unless you also check reactions.
has_thumbsup() {
  api_all "repos/$1/issues/$2/reactions" | jq -r "[.[] | select((.user.login | startswith(\"$BOT\")) and .content == \"+1\")] | length" \
    2>/dev/null || echo 0
}

# A clean review ALSO lands as an issue comment carrying the commit it inspected:
#
#   Codex Review: Didn't find any major issues. Breezy!
#   **Reviewed commit:** `d94a859dde`
#
# The sign-off wanders ("Bravo.", "Breezy!", "Keep them coming!", …), so never match
# on it. The `Reviewed commit` hash is the valuable part: unlike a 👍 reaction, it
# proves WHICH commit was reviewed. Emits "<iso8601>\t<sha>" per clean verdict.
clean_verdicts() {
  api_all "repos/$1/issues/$2/comments" | jq -r "[ .[]
          | select(.user.login | startswith(\"$BOT\"))
          | select(.body | test(\"[Dd]idn't find any major issues\"))
          | { created_at, sha: ((.body | capture(\"Reviewed commit:\\\\*\\\\*\\\\s*\`(?<s>[0-9a-f]+)\`\") | .s) // \"\") }
        ] | sort_by(.created_at) | .[] | \"\\(.created_at)\\t\\(.sha)\"" 2>/dev/null || true
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
issue_findings_now() {
  fetch_issue_findings "$1" "$3" "$2" | jq '[ .[] | select(.stale | not) ] | length'
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

review_count() {
  api_all "repos/$1/pulls/$2/reviews" | jq -r "[.[] | select(.user.login | startswith(\"$BOT\"))] | length" 2>/dev/null || echo 0
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
       | jq -r --arg bot "$BOT" '
           [ .[]
             | select(.user.login | startswith($bot))
             | select(.body | test("!\\[P[0-9] Badge\\]") or test("major issues"))
             | .created_at ]
           | "\(length):\(max // "")"' 2>/dev/null)"
}

latest_review_date() {
  api_all "repos/$1/pulls/$2/reviews" | jq -r "[.[] | select(.user.login | startswith(\"$BOT\")) | .submitted_at] | max // \"\"" 2>/dev/null
}

sev_rank() { case "$1" in P1) echo 1;; P2) echo 2;; P3) echo 3;; *) echo 9;; esac; }

cmd_json() {
  local repo pr head head_sha
  repo="$(resolve_repo)"; pr="$1"; head="$(head_commit_date "$repo" "$pr")"; head_sha="$(head_commit_sha "$repo" "$pr")"
  fetch_findings "$repo" "$pr" "$head" "$head_sha"
}

# THE verdict. One decision site, deliberately.
#
# `status` and `findings` both publish exit codes, and the help text promises they are
# the same codes. They were not: `findings` returned 0 with open findings on screen, so
# a merge gate written as `codex-review.sh findings N && merge` merged straight through
# them. Two copies of a rule this fiddly will drift again, so there is one copy, and
# `status` renders its messages from the key rather than re-deciding.
#
# Echoes a key; returns the exit code that goes with it.
verdict_key() {
  local open="$1" total="$2" reviews="$3" thumbs="$4" clean_line="$5" \
        clean_matches_head="$6" clean_sha="$7" issue_open="$8"

  # A clean verdict naming the newest commit is the strongest possible signal.
  if [ "$open" -eq 0 ] && [ "$clean_matches_head" -eq 1 ]; then
    echo clean-head; return 0
  fi

  if [ "$reviews" -eq 0 ] && [ "$thumbs" -eq 0 ] && [ -z "$clean_line" ] \
     && [ "${issue_open:-0}" -eq 0 ]; then
    echo not-reviewed; return 3
  fi

  if [ "$open" -eq 0 ]; then
    if [ -n "$clean_sha" ] && [ "$clean_matches_head" -eq 0 ]; then
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

# Every input `verdict_key` needs, gathered from the API. Kept next to it so a new
# input cannot be added to one and forgotten in the other.
verdict_for() {
  local repo="$1" pr="$2" head_sha="$3" json="$4"
  local open total reviews thumbs clean clean_line clean_sha matches

  open="$(printf '%s' "$json" | jq '[.[] | select(.stale == false and .anchored == true)] | length')"
  total="$(printf '%s' "$json" | jq 'length')"
  reviews="$(review_count "$repo" "$pr")"
  thumbs="$(has_thumbsup "$repo" "$pr")"
  clean="$(clean_verdicts "$repo" "$pr")"
  clean_line="$(printf '%s' "$clean" | tail -n 1)"
  clean_sha="$(printf '%s' "$clean_line" | cut -f2)"
  matches=0
  if [ -n "$clean_sha" ] && [ -n "$head_sha" ]; then
    case "$head_sha" in "$clean_sha"*) matches=1 ;; esac
  fi

  verdict_key "$open" "$total" "$reviews" "$thumbs" "$clean_line" "$matches" \
    "$clean_sha" "$(issue_open_in "$json")"
}

print_findings() {
  local repo pr head head_sha all json count code
  repo="$(resolve_repo)"; pr="$1"; all="${2:-open}"; head="$(head_commit_date "$repo" "$pr")"; head_sha="$(head_commit_sha "$repo" "$pr")"
  json="$(fetch_findings "$repo" "$pr" "$head" "$head_sha")"

  # Decided on the UNFILTERED list, before `open` mode throws the stale ones away —
  # "all stale" and "none at all" are different verdicts and both look empty after.
  code=0
  if [ "$all" = "open" ]; then
    verdict_for "$repo" "$pr" "$head_sha" "$json" >/dev/null || code=$?
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
  ctx="${CODEX_REVIEW_CONTEXT:-12}"; head="$(head_commit_date "$repo" "$pr")"; head_sha="$(head_commit_sha "$repo" "$pr")"
  json="$(fetch_findings "$repo" "$pr" "$head" "$head_sha")"

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
  local repo pr head head_sha json open p1 reviews thumbs latest issue_open
  local clean clean_line clean_sha clean_at clean_matches_head
  repo="$(resolve_repo)"; pr="$1"
  head="$(head_commit_date "$repo" "$pr")"; head_sha="$(head_commit_sha "$repo" "$pr")"
  json="$(fetch_findings "$repo" "$pr" "$head" "$head_sha")"
  open="$(printf '%s' "$json" | jq '[.[] | select(.stale == false and .anchored == true)] | length')"
  p1="$(printf '%s' "$json" | jq '[.[] | select(.stale == false and .anchored == true and .severity == "P1")] | length')"
  reviews="$(review_count "$repo" "$pr")"
  # An issue-comment finding is evidence a review happened even when no review
  # object exists — otherwise `status` reports "not reviewed yet" while a P1 it
  # just listed sits on the PR.
  issue_open="$(issue_open_in "$json")"
  thumbs="$(has_thumbsup "$repo" "$pr")"
  # Displayed, not compared — the settle fingerprint is a different thing and
  # printing it would put an opaque count in front of a human.
  latest="$(latest_review_date "$repo" "$pr")"

  clean="$(clean_verdicts "$repo" "$pr")"
  clean_line="$(printf '%s' "$clean" | tail -n 1)"
  clean_at="$(printf '%s' "$clean_line" | cut -f1)"
  clean_sha="$(printf '%s' "$clean_line" | cut -f2)"
  clean_matches_head=0
  if [ -n "$clean_sha" ] && [ -n "$head_sha" ] && case "$head_sha" in "$clean_sha"*) true ;; *) false ;; esac; then
    clean_matches_head=1
  fi

  echo "PR #$pr  ($repo)"
  echo "  newest commit : ${head:-unknown}  ${head_sha:0:10}"
  echo "  codex reviews : $reviews${latest:+  (latest $latest)}"
  echo "  codex 👍       : $thumbs"
  if [ -n "$clean_sha" ]; then
    echo "  clean verdict : yes — reviewed commit ${clean_sha}  ($clean_at)"
  elif [ -n "$clean_line" ]; then
    echo "  clean verdict : yes — but no commit hash in the comment"
  else
    echo "  clean verdict : none"
  fi
  echo "  open findings : $open  (P1: $p1)"

  # The decision itself lives in verdict_key. Everything below renders it.
  local key code total
  code=0
  key="$(verdict_key "$open" "$(printf '%s' "$json" | jq 'length')" "$reviews" "$thumbs" \
        "$clean_line" "$clean_matches_head" "$clean_sha" "${issue_open:-0}")" || code=$?
  total="$(printf '%s' "$json" | jq 'length')"

  case "$key" in
    clean-head)
      echo "  VERDICT       : REVIEWED, CLEAN — verdict names the newest commit." ;;
    not-reviewed)
      echo "  VERDICT       : NOT REVIEWED — no review, no 👍, no clean verdict."
      echo "                  Trigger one:  codex-review request $pr" ;;
    stale-clean)
      echo "  VERDICT       : STALE CLEAN VERDICT — it names ${clean_sha}, not the newest commit."
      echo "                  Newer commits are unreviewed:  codex-review request $pr" ;;
    all-stale)
      echo "  VERDICT       : REVIEWED — $total finding(s), all stale/outdated."
      echo "                  Confirm they are addressed, then merge." ;;
    clean)
      echo "  VERDICT       : REVIEWED, CLEAN." ;;
    inconsistent)
      echo "  VERDICT       : INCONSISTENT — an issue-comment finding is live but the"
      echo "                  finding list is empty. Re-run; do not read this as clean." ;;
    open)
      echo "  VERDICT       : $open OPEN FINDING(S) — address before merging."
      [ "$p1" -gt 0 ] && echo "                  ⚠ $p1 of them are P1." ;;
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
  echo "Then:  codex-review status $pr"
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
  deadline="${CODEX_REVIEW_TIMEOUT:-1800}"
  interval="${CODEX_REVIEW_INTERVAL:-60}"
  # A review pass is not always one post — Codex has been observed splitting
  # one pass across posts seconds apart. Returning on the first post reports a
  # subset, and a caller whose merge rule is "no P1" can be shown "P1: 0" while
  # a P1 is still in flight. Let the stream go quiet before reporting.
  settle_secs="${CODEX_REVIEW_SETTLE_SECONDS:-45}"
  settle_max="${CODEX_REVIEW_SETTLE_MAX_TRIES:-4}"
  elapsed=0
  local head_sha clean_sha reviewed_n issue_n
  head_sha="$(head_commit_sha "$repo" "$pr")"
  echo "Waiting for a Codex verdict on ${head_sha:0:10} (timeout ${deadline}s)..."
  while [ "$elapsed" -lt "$deadline" ]; do
    # Strongest signal: a clean verdict naming this exact commit.
    clean_sha="$(clean_verdicts "$repo" "$pr" | tail -n 1 | cut -f2)"
    if [ -n "$clean_sha" ] && [ -n "$head_sha" ] \
       && case "$head_sha" in "$clean_sha"*) true ;; *) false ;; esac; then
      echo "Clean verdict for ${clean_sha}."
      cmd_status "$pr" || true
      return 0
    fi
    # A review that names this commit — exact, whatever the clocks say.
    # A lookup that FAILED is not a lookup that found nothing. Swallowing it here
    # made `wait` spin to its 1800s timeout printing the same error each round,
    # when the honest answer was available on the first try.
    reviewed_n="$(reviewed_head "$repo" "$pr" "$head_sha")" \
      || die "could not read the reviews of PR #$pr in $repo."
    # A finding can arrive as an ISSUE comment with no review object behind it.
    # Waiting only on reviews meant the command sat out its whole timeout while
    # the verdict — a P1, in the case that surfaced this — was already posted.
    issue_n="$(issue_findings_now "$repo" "$pr" "$head_sha")" \
      || die "could not read the comments of PR #$pr in $repo."
    if [ -n "$head_sha" ] && { [ "${reviewed_n:-0}" -gt 0 ] || [ "${issue_n:-0}" -gt 0 ]; }; then
      latest="$(activity_stamp "$repo" "$pr")"
      echo "Review landed at ${latest:-now}."
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
      echo "Review landed at ${latest:-now}."
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
