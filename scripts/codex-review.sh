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
head_commit_date() {
  gh api "repos/$1/pulls/$2/commits" --paginate \
    -q 'map(.commit.committer.date // .commit.author.date) | max // ""'
}

# review id → the commit that review inspected. Every Codex output states it as
#   **Reviewed commit:** `<sha10>`
# which is far better than guessing from timestamps.
review_shas() {
  gh api "repos/$1/pulls/$2/reviews" --paginate \
    -q "[ .[]
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
fetch_findings() {
  local repo="$1" pr="$2" head_date="$3" head_sha="$4" shamap
  shamap="$(review_shas "$repo" "$pr")"
  gh api "repos/$repo/pulls/$pr/comments" --paginate \
    --jq "[ .[] | select(.user.login | startswith(\"$BOT\")) ]" \
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
      ] | sort_by(.created_at) | reverse'
}

# Codex leaves NO review object when it has nothing to say — it reacts 👍 on the
# PR instead. So "zero reviews" is ambiguous unless you also check reactions.
has_thumbsup() {
  gh api "repos/$1/issues/$2/reactions" --paginate \
    -q "[.[] | select((.user.login | startswith(\"$BOT\")) and .content == \"+1\")] | length" \
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
  gh api "repos/$1/issues/$2/comments" --paginate \
    -q "[ .[]
          | select(.user.login | startswith(\"$BOT\"))
          | select(.body | test(\"[Dd]idn't find any major issues\"))
          | { created_at, sha: ((.body | capture(\"Reviewed commit:\\\\*\\\\*\\\\s*\`(?<s>[0-9a-f]+)\`\") | .s) // \"\") }
        ] | sort_by(.created_at) | .[] | \"\\(.created_at)\\t\\(.sha)\"" 2>/dev/null || true
}

# Full SHA of the PR's newest commit, for matching against `Reviewed commit`.
head_commit_sha() {
  gh api "repos/$1/pulls/$2/commits" --paginate -q '.[-1].sha // ""' 2>/dev/null || true
}

review_count() {
  gh api "repos/$1/pulls/$2/reviews" --paginate \
    -q "[.[] | select(.user.login | startswith(\"$BOT\"))] | length" 2>/dev/null || echo 0
}

latest_review_date() {
  gh api "repos/$1/pulls/$2/reviews" --paginate \
    -q "[.[] | select(.user.login | startswith(\"$BOT\")) | .submitted_at] | max // \"\"" 2>/dev/null
}

sev_rank() { case "$1" in P1) echo 1;; P2) echo 2;; P3) echo 3;; *) echo 9;; esac; }

cmd_json() {
  local repo pr head head_sha
  repo="$(resolve_repo)"; pr="$1"
  head="$(head_commit_date "$repo" "$pr")"; head_sha="$(head_commit_sha "$repo" "$pr")"
  fetch_findings "$repo" "$pr" "$head" "$head_sha"
}

print_findings() {
  local repo pr head head_sha all json count
  repo="$(resolve_repo)"; pr="$1"; all="${2:-open}"
  head="$(head_commit_date "$repo" "$pr")"; head_sha="$(head_commit_sha "$repo" "$pr")"
  json="$(fetch_findings "$repo" "$pr" "$head" "$head_sha")"

  if [ "$all" = "open" ]; then
    json="$(printf '%s' "$json" | jq '[.[] | select(.stale == false and .anchored == true)]')"
  fi

  count="$(printf '%s' "$json" | jq 'length')"
  if [ "$count" -eq 0 ]; then
    if [ "$all" = "open" ]; then echo "No open Codex findings."; else echo "No Codex findings at all."; fi
    return
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
}

# Everything you need to act on a finding, without opening the browser: the
# reasoning, what Codex wants changed, and the code it is pointing at. Grouped by
# file and ordered by line, so each file is opened once.
cmd_detail() {
  local repo pr head head_sha all json count ctx
  repo="$(resolve_repo)"; pr="$1"; all="${2:-open}"
  ctx="${CODEX_REVIEW_CONTEXT:-12}"
  head="$(head_commit_date "$repo" "$pr")"; head_sha="$(head_commit_sha "$repo" "$pr")"
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
    | (.diff_hunk | split("\n")) as $h
    | ($h | length) as $n
    | ((if $n > $ctx then ["        …"] + ($h[$n-$ctx:] | map("        " + .))
        else ($h | map("        " + .)) end)
       | .[0:-1] + [ (.[-1] | sub("^        "; "     »» ")) ] | join("\n")) as $code
    | "────────────────────────────────────────────────────────────────────────\n"
      + "[\(.severity)]  \(.path):\($loc)\($stale)\($anchor)\n"
      + "       \(.title)\n\n"
      + "  WHY  \(.rationale | wrapblock(66; "       ") | ltrimstr("       "))\n"
      + (if .fix != "" then "\n  FIX  \(.fix | wrap(66; "       ") | ltrimstr("       "))\n" else "" end)
      + "\n  CODE\n\($code)\n"
      + "\n  LINK \(.url)\n"'
}

cmd_status() {
  local repo pr head head_sha json open p1 reviews thumbs latest
  local clean clean_line clean_sha clean_at clean_matches_head
  repo="$(resolve_repo)"; pr="$1"
  head="$(head_commit_date "$repo" "$pr")"
  head_sha="$(head_commit_sha "$repo" "$pr")"
  json="$(fetch_findings "$repo" "$pr" "$head" "$head_sha")"
  open="$(printf '%s' "$json" | jq '[.[] | select(.stale == false and .anchored == true)] | length')"
  p1="$(printf '%s' "$json" | jq '[.[] | select(.stale == false and .anchored == true and .severity == "P1")] | length')"
  reviews="$(review_count "$repo" "$pr")"
  thumbs="$(has_thumbsup "$repo" "$pr")"
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

  # A clean verdict naming the newest commit is the strongest possible signal.
  if [ "$open" -eq 0 ] && [ "$clean_matches_head" -eq 1 ]; then
    echo "  VERDICT       : REVIEWED, CLEAN — verdict names the newest commit."
    return 0
  fi

  if [ "$reviews" -eq 0 ] && [ "$thumbs" -eq 0 ] && [ -z "$clean_line" ]; then
    echo "  VERDICT       : NOT REVIEWED — no review, no 👍, no clean verdict."
    echo "                  Trigger one:  codex-review request $pr"
    return 3
  fi

  if [ "$open" -eq 0 ]; then
    local total; total="$(printf '%s' "$json" | jq 'length')"
    if [ -n "$clean_sha" ] && [ "$clean_matches_head" -eq 0 ]; then
      echo "  VERDICT       : STALE CLEAN VERDICT — it names ${clean_sha}, not the newest commit."
      echo "                  Newer commits are unreviewed:  codex-review request $pr"
      return 3
    fi
    if [ "$total" -gt 0 ]; then
      echo "  VERDICT       : REVIEWED — $total finding(s), all stale/outdated."
      echo "                  Confirm they are addressed, then merge."
      return 4
    fi
    echo "  VERDICT       : REVIEWED, CLEAN."
    return 0
  fi

  echo "  VERDICT       : $open OPEN FINDING(S) — address before merging."
  [ "$p1" -gt 0 ] && echo "                  ⚠ $p1 of them are P1."
  return 2
}

cmd_request() {
  local repo pr; repo="$(resolve_repo)"; pr="$1"
  gh pr comment "$pr" --repo "$repo" --body "@codex review" >/dev/null
  echo "Requested a Codex re-review on PR #$pr."
  echo "Note: a re-review typically takes several minutes."
  echo "Then:  codex-review status $pr"
}

cmd_wait() {
  local repo pr head deadline interval elapsed reviews thumbs latest
  repo="$(resolve_repo)"; pr="$1"
  head="$(head_commit_date "$repo" "$pr")"
  deadline="${CODEX_REVIEW_TIMEOUT:-1800}"
  interval="${CODEX_REVIEW_INTERVAL:-60}"
  # A review pass is not always one post — Codex has been observed splitting
  # one pass across posts seconds apart. Returning on the first post reports a
  # subset, and a caller whose merge rule is "no P1" can be shown "P1: 0" while
  # a P1 is still in flight. Let the stream go quiet before reporting.
  settle_secs="${CODEX_REVIEW_SETTLE_SECONDS:-45}"
  settle_max="${CODEX_REVIEW_SETTLE_MAX_TRIES:-4}"
  elapsed=0
  local head_sha clean_sha
  head_sha="$(head_commit_sha "$repo" "$pr")"
  echo "Waiting for a Codex verdict on ${head_sha:0:10} (after $head, timeout ${deadline}s)..."
  while [ "$elapsed" -lt "$deadline" ]; do
    # Strongest signal: a clean verdict naming this exact commit.
    clean_sha="$(clean_verdicts "$repo" "$pr" | tail -n 1 | cut -f2)"
    if [ -n "$clean_sha" ] && [ -n "$head_sha" ] \
       && case "$head_sha" in "$clean_sha"*) true ;; *) false ;; esac; then
      echo "Clean verdict for ${clean_sha}."
      cmd_status "$pr" || true
      return 0
    fi
    latest="$(latest_review_date "$repo" "$pr")"
    if [ -n "$latest" ] && [ "$latest" \> "$head" ]; then
      echo "Review landed at $latest."
      # Settle: keep looking until the newest review timestamp stops moving, so
      # a pass split across several posts is reported whole.
      settle_prev=""
      settle_tries=0
      while [ "$settle_tries" -lt "$settle_max" ] && [ "$latest" != "$settle_prev" ]; do
        settle_prev="$latest"
        sleep "$settle_secs"
        latest="$(latest_review_date "$repo" "$pr")"
        settle_tries=$((settle_tries + 1))
      done
      [ "$latest" != "$settle_prev" ] && echo "(more arrived — settled at $latest)"
      cmd_status "$pr" || true
      return 0
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
