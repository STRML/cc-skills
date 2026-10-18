#!/usr/bin/env bash
# cr-check — trigger or poll a CodeRabbit review on a GitHub PR, then return
# ONLY the actionable feedback. Cache-mindful: output is plain text, capped,
# and skips CR's verbose prompt/autofix/run-info sections.
#
# Usage:
#   cr-check                                    # auto-detect PR from current branch
#   cr-check 84                                 # explicit PR
#   cr-check 84 --trigger                       # post @coderabbitai review, then poll
#   cr-check 84 --trigger --wait                # block until CR settles (default 6min)
#   cr-check 84 --since SHA                     # only reviews/comments newer than SHA's push
#   cr-check 84 --trigger --auto-resume         # post @coderabbitai resume if PR is paused, then retry
#   cr-check 84 --trigger --retry-on-rate-limit # backoff through rate limits AND fair-usage caps
#   cr-check 84 --trigger --retry-on-fair-usage # wait out a fair-usage cap only
#
# Findings output always carries two verdict lines. Read these, not the state in
# the "PR #N — commit ..." header:
#   HEAD verdict: APPROVED|CHANGES_REQUESTED|DISMISSED|NONE on <sha> (<ts>)
#   PR reviewDecision: <GitHub's aggregate across all reviewers>
# The header shows ONE review, the newest. CR posts a COMMENTED review for every
# inline thread reply, so the newest is often a COMMENTED that says nothing about
# approval and can sit seconds after the APPROVED it hides (PR #199, 2026-07-31).
# The two lines can legitimately disagree: the verdict is CR's last decisive word
# on THIS commit; reviewDecision is repo-wide and does not reset on a push.
#
# Status output shape (exit 2):
#   STATUS <kind>
#   [timestamp] first 6 lines of CR's comment, joined with " \n "
# where <kind> is one of: PR_PAUSED, RATE_LIMIT, PLAN_LIMIT, FAIR_USAGE_LIMIT,
# ORG_DISABLED, UNKNOWN.
# --auto-resume handles PR_PAUSED; --retry-on-rate-limit handles RATE_LIMIT and
# FAIR_USAGE_LIMIT; --retry-on-fair-usage handles FAIR_USAGE_LIMIT alone.
# PLAN_LIMIT and ORG_DISABLED are never auto-handled — they need a human.
#
# FAIR_USAGE_LIMIT is recoverable, and this used to say otherwise. CR states its
# own reset in the notice ("Next review available in: 21 minutes"), and once that
# elapses a re-trigger produces a full review. Observed twice on 2026-07-25:
# waits of ~33 and ~21 minutes, both followed by a complete review. Treating it
# as terminal (the old advice: "won't review for ~an hour, fall back to a local
# review") throws away the bot gate for a wait the bot itself has quantified.
#
# ⚠️  A fair-usage cap still posts a PASSING "CodeRabbit" check run while no
# review exists. `gh pr checks` shows green; `gh pr view --json reviews` is
# empty. Never gate a merge on the check — gate on a review object whose
# commit_id matches HEAD. This script warns loudly when it sees that combination.
#
# Exit codes:
#   0  CR reviewed; output contains findings (or "no findings")
#   2  CR is blocked by a status the script can't resolve; output explains state
#   3  CR has not responded within --wait deadline
#   4  precondition failed (no PR, not in repo, gh missing)
#

set -euo pipefail

PR=""
TRIGGER=0
WAIT=0
WAIT_SECONDS=360
SINCE_SHA=""
INCLUDE_NITPICKS=1
AUTO_RESUME=0
RETRY_RATE_LIMIT=0
RETRY_FAIR_USAGE=0
#: Ceiling on a single fair-usage sleep. CR's stated reset has been 20-35 min in
#: practice; anything far beyond that is a misparse or a different problem, and
#: should surface rather than park the caller for hours.
FAIR_USAGE_MAX_SLEEP=5400

while [ $# -gt 0 ]; do
  case "$1" in
    --trigger) TRIGGER=1; shift ;;
    --wait) WAIT=1; shift ;;
    --wait-seconds) WAIT_SECONDS="$2"; shift 2 ;;
    --since) SINCE_SHA="$2"; shift 2 ;;
    --no-nitpicks) INCLUDE_NITPICKS=0; shift ;;
    --auto-resume) AUTO_RESUME=1; WAIT=1; shift ;;
    # A caller asking to retry through rate limits means both flavours of cap;
    # splitting them is a distinction only this script cared about.
    --retry-on-rate-limit) RETRY_RATE_LIMIT=1; RETRY_FAIR_USAGE=1; WAIT=1; shift ;;
    --retry-on-fair-usage) RETRY_FAIR_USAGE=1; WAIT=1; shift ;;
    -h|--help)
      sed -n '3,37p' "$0"
      exit 0
      ;;
    *)
      if [ -z "$PR" ]; then PR="$1"; shift
      else echo "cr-check: unknown arg: $1" >&2; exit 4
      fi
      ;;
  esac
done

command -v gh >/dev/null || { echo "cr-check: gh CLI not installed" >&2; exit 4; }
command -v jq >/dev/null || { echo "cr-check: jq not installed" >&2; exit 4; }

if [ -z "$PR" ]; then
  PR=$(gh pr view --json number --jq .number 2>/dev/null || true)
  [ -n "$PR" ] || { echo "cr-check: no PR found for current branch; pass PR number explicitly" >&2; exit 4; }
fi

REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || \
  { echo "cr-check: not in a GitHub repo" >&2; exit 4; }

PR_HEAD=$(gh pr view "$PR" --json headRefOid --jq .headRefOid 2>/dev/null || echo "")

# --- API failure handling -------------------------------------------------
#
# `gh api` prints the error BODY to STDOUT on failure, not stderr. So the
# idiom this script used everywhere:
#
#   n=$(gh api ... --jq '... | length' 2>/dev/null || echo 0)
#
# does NOT yield 0 on failure — it yields '{"message":"Not Found",...}0',
# because 2>/dev/null silences only stderr and `|| echo 0` APPENDS to the
# body already on stdout. Every downstream [ "$n" -gt 0 ] then dies with
# "integer expected", the test is skipped, and the script carries on as if
# the answer were "no reviews". Observed 2026-08-17 on PR #213: the run
# printed "HEAD 43f1e28 does carry a null review; the green is not spurious"
# for a PR that had no reviews at all. A merge gate that reports a review
# which does not exist is worse than one that crashes.
#
# Everything numeric goes through cr_count now. It fails LOUD: a non-integer
# result sets API_FAILED and the caller reports UNKNOWN rather than green.
API_FAILED=0

# cr_count <jq-filter-over-.reviews> — CodeRabbit review count via the GraphQL
# path (gh pr view), which is also the one that survives environments where the
# REST pulls/N/reviews endpoint 404s (seen on a private org repo,
# where REST GET 404s while GraphQL returns the same data fine).
cr_count() {
  local out
  out=$(gh pr view "$PR" --json reviews --jq "$1" 2>/dev/null)
  case "$out" in
    ''|*[!0-9]*) API_FAILED=1; echo 0; return 1 ;;
  esac
  echo "$out"
}

# CodeRabbit reviews submitted after $1 (ISO-8601).
cr_reviews_since() {
  cr_count "[.reviews[] | select(.author.login | test(\"coderabbit\"; \"i\")) | select(.submittedAt > \"$1\")] | length"
}

# cr_comment_count <jq-filter-over-the-array> — same guarantee for the issue
# comments endpoint, which has the identical failure mode.
cr_comment_count() {
  local out
  out=$(gh api "repos/$REPO/issues/$PR/comments?per_page=50" --jq "$1" 2>/dev/null)
  case "$out" in
    ''|*[!0-9]*) API_FAILED=1; echo 0; return 1 ;;
  esac
  echo "$out"
}

# cr_comment_obj <jq-filter> — a {created_at, body} object from the comments
# endpoint, or empty. Same trap as the counts: `... || echo ""` leaves the 404
# body on stdout, and callers then treat that error document AS the status
# comment — which is how a failed lookup became "STATUS UNKNOWN" instead of an
# API error. Anything that is not a JSON object with a string body is rejected.
cr_comment_obj() {
  local out
  out=$(gh api "repos/$REPO/issues/$PR/comments?per_page=50" --jq "$1" 2>/dev/null) || {
    API_FAILED=1; return 1
  }
  [ -n "$out" ] || return 1
  echo "$out" | jq -e 'type == "object" and (.body | type == "string")' >/dev/null 2>&1 || {
    # An error document reaching here means the query failed, not that the PR
    # has no status comment. Those are different answers and must not collapse.
    case "$out" in *'"message"'*|*'"documentation_url"'*) API_FAILED=1 ;; esac
    return 1
  }
  echo "$out"
}

# Resolve "since" timestamp: from explicit --since SHA, or from PR HEAD commit.
if [ -n "$SINCE_SHA" ]; then
  SINCE=$(gh api "repos/$REPO/commits/$SINCE_SHA" --jq '.commit.committer.date' 2>/dev/null) || \
    { echo "cr-check: cannot resolve --since SHA $SINCE_SHA" >&2; exit 4; }
else
  SINCE=$(gh api "repos/$REPO/commits/$PR_HEAD" --jq '.commit.committer.date' 2>/dev/null) || \
    SINCE="1970-01-01T00:00:00Z"
fi

# True if CR has ever posted a review on this PR (any commit).
cr_has_prior_review() {
  local n
  n=$(cr_count "[.reviews[] | select(.author.login | test(\"coderabbit\"; \"i\"))] | length")
  [ "${n:-0}" -gt 0 ]
}

trigger_review() {
  # Pick the command. Plain `@coderabbitai review` is incremental and NO-OPS on
  # an auto-review-disabled repo once any prior review exists — CR's own note:
  # "applicable only when automatic reviews are paused" — so new commits never
  # get re-reviewed. There, force `@coderabbitai full review`, which re-reads the
  # whole PR and always reviews the current HEAD.
  local cmd="@coderabbitai review"
  if repo_auto_review_disabled && cr_has_prior_review; then
    cmd="@coderabbitai full review"
  fi
  # Idempotent-ish: don't trigger if CR posted a comment in the last 60s that
  # means a review is already under way.
  #
  # This MUST exclude blocking notices. A "Review limit reached" warning is a CR
  # comment from seconds ago, and counting it here suppressed the very trigger
  # that clears the cap. Observed 2026-08-23 on PR #302: --trigger
  # --retry-on-fair-usage skipped its trigger against the fresh cap notice, and
  # the PR sat unreviewed for three hours behind a green CodeRabbit check row.
  # A cap notice is the opposite of "a review is coming".
  since_60=$(date -u -v-60S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '60 seconds ago' +%Y-%m-%dT%H:%M:%SZ)
  recent=$(cr_comment_count "[.[] | select(.user.login | test(\"coderabbit\"; \"i\")) | select(.created_at > \"$since_60\") | select((.body | test(\"$CR_REVIEW_LIMIT_RE\"; \"i\")) | not) | select((.body | test(\"$CR_STATUS_SUMMARY_RE\")) | not)] | length")
  if [ "$recent" -gt 0 ]; then
    echo "cr-check: CR posted a non-blocking comment in the last 60s; skipping trigger" >&2
  else
    gh pr comment "$PR" --body "$cmd" >/dev/null
    echo "cr-check: triggered '$cmd' on PR #$PR" >&2
  fi
}

# CR uses <summary> emojis to flag the comment's intent. ✅ means a normal
# ack (boilerplate contains "automatic reviews are paused" — false positive
# bait). The signals that mean "no review is coming" use these emojis:
#   🛑  Review skipped / blocked
#   ⚠️  Rate limit, plan limit, warning
#   ❌  Cannot review
#   🚫  Banned / disallowed
#   ⏸️  Paused
# Match the summary line, not body text, to avoid catching boilerplate prose.
CR_STATUS_SUMMARY_RE='<summary>[^<]*(🛑|⚠️|❌|🚫|⏸️)'

# Phrases that uniquely identify CR's "manual trigger was a no-op because
# the commit was already incrementally reviewed" boilerplate.
CR_NOOP_RE='already reviewed commits|incremental review system'

# Grace window: how long after the ack we wait before declaring the trigger
# a no-op. CR sometimes posts the ack and the review separately within
# ~60s; bump only if a real review fails to land.
NOOP_GRACE_SECONDS=180

# CR's "auto-review is off for this repo" notice. Unlike a pause or rate limit
# this is a permanent repo setting (reviews.auto_review disabled in
# .coderabbit.yaml) — the review will NEVER land on its own. It's posted as a
# [!IMPORTANT] "Review skipped" callout, NOT a <summary>-emoji status block, so
# detect_status misses it. We notice it separately and auto-trigger once.
CR_AUTO_DISABLED_RE='Review skipped|[Aa]uto[ -]?reviews? (are|is)? ?disabled|Auto reviews are disabled'

# CR's "Review limit reached" notice (Fair Usage / adaptive limits). Posted as a
# [!WARNING] callout carrying the HTML marker "rate limited by coderabbit.ai",
# NOT a <summary>-emoji status block, so detect_status's (a) branch misses it.
# It's a temporary cap ("Next review available in: N minutes") — CR won't review
# again until it clears, so the caller should fall back to a local review rather
# than wait it out.
# NOTE: no backslash escapes here — this string is interpolated into a jq
# test("...") program, and jq rejects invalid JSON string escapes like \. .
CR_REVIEW_LIMIT_RE='rate limited by coderabbit|Review limit reached|Fair Usage Limits'

# Detect a status-only situation. Two flavors:
#   (a) CR posted a status-emoji summary (🛑 ⚠️ ❌ 🚫 ⏸️) — a real block
#   (b) CR posted a ✅ ack containing the "already reviewed" boilerplate
#       AND the ack is older than NOOP_GRACE_SECONDS AND no review followed
#       — silent no-op (this fires for manual @coderabbitai review against
#       a commit CR's incremental engine already saw)
# Both require "no review newer than SINCE" so we don't mis-fire when a
# review is actually pending.
# ISO-8601 UTC -> epoch seconds. BSD and GNU date disagree; try both.
iso_to_epoch() {
  local ts="$1"
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null \
    || date -u -d "$ts" +%s 2>/dev/null \
    || echo ""
}

# True if a "Review limit reached" comment is still in force.
#
# The notice carries its own expiry ("Next review available in: N minutes"), so
# comment_time + N + slack is when it stops meaning anything. Without this the
# comment reports a cap indefinitely — it is never edited or deleted when the cap
# clears, and CR does not post a fresh "cap lifted" notice.
#
# Unparseable timestamp or interval => assume still in force (fail safe: better
# to report a possibly-stale cap than to silently ignore a real one).
limit_comment_in_force() {
  local json="$1" created secs created_epoch now_epoch
  created=$(echo "$json" | jq -r .created_at 2>/dev/null)
  [ -n "$created" ] && [ "$created" != "null" ] || return 0
  secs=$(fair_usage_sleep_seconds "$(echo "$json" | jq -r .body)") || return 0
  created_epoch=$(iso_to_epoch "$created")
  [ -n "$created_epoch" ] || return 0
  now_epoch=$(date -u +%s)
  # 5min slack: CR's countdown is rounded and the cap can run slightly long.
  if [ "$now_epoch" -gt $((created_epoch + secs + 300)) ]; then
    echo "cr-check: ignoring a spent fair-usage notice from $created (its stated window elapsed)" >&2
    return 1
  fi
  return 0
}

detect_status() {
  # (a) Real status emoji.
  status_comment=$(cr_comment_obj "[.[] | select(.user.login | test(\"coderabbit\"; \"i\")) | select(.created_at > \"$SINCE\") | select(.body | test(\"$CR_STATUS_SUMMARY_RE\")) | {created_at, body}] | last // empty" || echo "")
  if [ -n "$status_comment" ] && [ "$status_comment" != "null" ]; then
    review_count=$(cr_reviews_since "$SINCE")
    if [ "$review_count" -eq 0 ]; then
      echo "$status_comment"
      return 0
    fi
  fi

  # (a2) "Review limit reached" (Fair Usage / adaptive limit). A [!WARNING]
  # callout, not a <summary> emoji, so (a) misses it. Deliberately NOT gated on
  # created_at > SINCE: the cap is PR-wide state that CR posts once and doesn't
  # re-post on each push, so it usually predates HEAD.
  #
  # But it MUST be aged out, or the comment reports a cap forever. Observed
  # 2026-07-26 on PR #67: a limit comment from 20:24 the previous evening was
  # still being reported at 06:37 — a phantom "50 minutes" that never counted
  # down, through two hours of waiting. The "no review since SINCE" guard below
  # does not catch it, because CR can legitimately produce no new review at all
  # ("does not re-review already reviewed commits").
  #
  # A cap states its own duration, so that bounds it: once
  # comment_time + stated_interval has passed, the notice is spent.
  limit_comment=$(cr_comment_obj "[.[] | select(.user.login | test(\"coderabbit\"; \"i\")) | select(.body | test(\"$CR_REVIEW_LIMIT_RE\"; \"i\")) | {created_at, body}] | last // empty" || echo "")
  if [ -n "$limit_comment" ] && [ "$limit_comment" != "null" ]; then
    if ! limit_comment_in_force "$limit_comment"; then
      limit_comment=""
    fi
  fi
  if [ -n "$limit_comment" ] && [ "$limit_comment" != "null" ]; then
    review_count=$(cr_reviews_since "$SINCE")
    if [ "$review_count" -eq 0 ]; then
      echo "$limit_comment"
      return 0
    fi
  fi

  # (b) Silent no-op: ✅ ack with "already reviewed" boilerplate, no
  # following review, ack is older than NOOP_GRACE_SECONDS.
  #
  # CR appends that boilerplate Note ("incremental review system ... does not
  # re-review already reviewed commits") to EVERY command ack now, including
  # "Review triggered" / "Review finished" acks that DO precede or accompany a
  # real review. So two extra guards distinguish a true no-op from a real
  # review in progress:
  #   - skip while a CR review check is still pending (the review is coming);
  #   - count reviews since SINCE, not since the ack (avoids the race where the
  #     review lands a second before the "Review finished" ack).
  cr_check_pending && return 1
  noop_ack=$(cr_comment_obj "[.[] | select(.user.login | test(\"coderabbit\"; \"i\")) | select(.created_at > \"$SINCE\") | select(.body | test(\"$CR_NOOP_RE\"; \"i\")) | {created_at, body}] | last // empty" || echo "")
  if [ -n "$noop_ack" ] && [ "$noop_ack" != "null" ]; then
    ack_iso=$(echo "$noop_ack" | jq -r .created_at)
    # Portable ISO-8601 to epoch: try BSD date first, then GNU date.
    ack_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$ack_iso" +%s 2>/dev/null || \
                date -u -d "$ack_iso" +%s 2>/dev/null || echo 0)
    now_epoch=$(date -u +%s)
    age=$(( now_epoch - ack_epoch ))
    if [ "$ack_epoch" -gt 0 ] && [ "$age" -ge "$NOOP_GRACE_SECONDS" ]; then
      review_count=$(cr_reviews_since "$SINCE")
      if [ "$review_count" -eq 0 ]; then
        echo "$noop_ack"
        return 0
      fi
    fi
  fi
  return 1
}

# True while a CR review is already in flight (its status check is pending /
# queued). Used to avoid re-triggering a review that's already running.
cr_check_pending() {
  local n
  n=$(gh pr view "$PR" --json statusCheckRollup \
    --jq '[.statusCheckRollup[] | select((.name // .context // "") | test("coderabbit";"i")) | select((.status // .state // "") | test("PENDING|IN_PROGRESS|QUEUED|EXPECTED";"i"))] | length' 2>/dev/null || echo 0)
  [ "${n:-0}" -gt 0 ]
}

# True if this repo has CR auto-review disabled — meaning a review will NEVER
# land on its own (initial OR after a push), so cr-check must trigger it. Two
# signals, cached after first resolution:
#   (a) deterministic: .coderabbit.yaml on the PR head sets
#       reviews.auto_review.enabled:false (or disable:true)
#   (b) fallback: CR posted a "Review skipped / Auto reviews are disabled"
#       notice since SINCE (covers org/UI-level disables not in the yaml)
AUTO_REVIEW_STATE=""
repo_auto_review_disabled() {
  if [ -z "$AUTO_REVIEW_STATE" ]; then
    local yaml ref="${PR_HEAD:-HEAD}"
    yaml=$(gh api "repos/$REPO/contents/.coderabbit.yaml?ref=$ref" \
      -H "Accept: application/vnd.github.raw" 2>/dev/null || echo "")
    if echo "$yaml" | grep -iA3 'auto_review:' | grep -qiE 'enabled:[[:space:]]*false|disable:[[:space:]]*true'; then
      AUTO_REVIEW_STATE=disabled
    else
      AUTO_REVIEW_STATE=enabled
    fi
  fi
  [ "$AUTO_REVIEW_STATE" = "disabled" ] && return 0
  # Fallback (b): the one-time "Review skipped" notice.
  local c
  c=$(cr_comment_count "[.[] | select(.user.login | test(\"coderabbit\"; \"i\")) | select(.created_at > \"$SINCE\") | select(.body | test(\"$CR_AUTO_DISABLED_RE\"; \"i\"))] | length")
  [ "${c:-0}" -gt 0 ]
}

# Classify a CR status comment body into one of:
#   PR_PAUSED    — per-PR pause, resumable via @coderabbitai resume
#   RATE_LIMIT   — concurrent / per-minute rate cap, clears on its own
#   PLAN_LIMIT   — monthly/hourly plan quota, NOT auto-resumable
#   FAIR_USAGE_LIMIT — temporary adaptive "Review limit reached" cap (~1hr),
#                  NOT auto-handled; fall back to a local review
#   ORG_DISABLED — disabled in CR org settings, NOT auto-resumable
#   UNKNOWN      — matched a status emoji but body doesn't fit above
classify_status_body() {
  local body="$1"
  # Check the Fair-Usage cap first: its body mentions "rate limits" ($0.25/file)
  # which would otherwise mis-classify as RATE_LIMIT.
  if echo "$body" | grep -qiE 'review limit reached|fair usage|adaptive limit|rate limited by coderabbit'; then
    echo FAIR_USAGE_LIMIT
  elif echo "$body" | grep -qiE 'plan limit|monthly limit|hourly limit|quota exceeded|usage limit'; then
    echo PLAN_LIMIT
  elif echo "$body" | grep -qiE 'rate.?limit|concurrent|too many requests|429'; then
    echo RATE_LIMIT
  # NOOP before PR_PAUSED, deliberately. CR's command-ack boilerplate reads
  # "This command is applicable only when automatic reviews are paused" —
  # conditional prose that the loose 'review.* paused' pattern below matches, so
  # checking PR_PAUSED first reported a paused PR for an ordinary "Review
  # finished" ack (seen on #67, 2026-07-26) and would make --auto-resume post a
  # pointless @coderabbitai resume. The no-op boilerplate is a specific marker;
  # if it is present, that is what the comment is.
  elif echo "$body" | grep -qiE 'already reviewed commits|incremental review system'; then
    echo MANUAL_TRIGGER_NOOP
  elif echo "$body" | grep -qiE 'paused for this (pr|pull)|@coderabbitai resume|review.* paused'; then
    echo PR_PAUSED
  elif echo "$body" | grep -qiE 'reviews? disabled|organization settings|not enabled'; then
    echo ORG_DISABLED
  else
    echo UNKNOWN
  fi
}

# Seconds to wait out a fair-usage cap, parsed from CR's own notice. CR has
# used at least two wordings — "Next review available in: 21 minutes" and
# "Next included review available in 40 minutes." — so "included" and the colon
# are both optional. A miss here is silent and expensive: --retry-on-fair-usage
# prints "no parseable reset time; not waiting" and returns, which reads like
# the cap is unrecoverable (observed 2026-09-02). Echoes nothing if
# unparseable, so the caller can decide whether to fall back.
fair_usage_sleep_seconds() {
  local body="$1" line mins secs
  line=$(echo "$body" | grep -ioE 'Next[[:space:]]+(included[[:space:]]+)?review available in:?[^<]*' | head -1)
  [ -n "$line" ] || return 1
  mins=$(echo "$line" | grep -oiE '[0-9]+[[:space:]]*(minute|min)' | grep -oE '[0-9]+' | head -1)
  secs=$(echo "$line" | grep -oiE '[0-9]+[[:space:]]*(second|sec)' | grep -oE '[0-9]+' | head -1)
  local total=0
  [ -n "${mins:-}" ] && total=$((total + mins * 60))
  [ -n "${secs:-}" ] && total=$((total + secs))
  [ "$total" -gt 0 ] || return 1
  # Buffer: CR's countdown is rounded down, so waking exactly on it re-trips.
  total=$((total + 45))
  [ "$total" -gt "$FAIR_USAGE_MAX_SLEEP" ] && total=$FAIR_USAGE_MAX_SLEEP
  echo "$total"
}

# The trap that makes a capped CR dangerous: it still posts a PASSING check run.
# Warn whenever we report a blocking status while that check reads green, since
# the PR then looks fully approved to anyone reading `gh pr checks`.
warn_if_check_is_falsely_green() {
  [ -n "${PR_HEAD:-}" ] || return 0
  local concl=""
  # CodeRabbit reports through the legacy COMMIT STATUS api ("context":"CodeRabbit",
  # "state":"success"), NOT check-runs — /commits/<sha>/check-runs comes back empty
  # for it. `gh pr checks` merges both, which is why the green looks like a check.
  # Query statuses first, then check-runs, so this keeps working if they migrate.
  concl=$(gh api "repos/$REPO/commits/$PR_HEAD/status" \
    --jq '[.statuses[] | select(.context | test("coderabbit"; "i"))] | last | .state' 2>/dev/null || echo "")
  if [ -z "$concl" ] || [ "$concl" = "null" ]; then
    concl=$(gh api "repos/$REPO/commits/$PR_HEAD/check-runs" \
      --jq '[.check_runs[] | select(.name | test("coderabbit"; "i"))] | last | .conclusion' 2>/dev/null || echo "")
  fi
  # Do not claim "no review exists" without checking. The callers only know
  # there is no review newer than SINCE, which is a weaker statement — HEAD can
  # already carry an APPROVED that predates SINCE. Saying the green is
  # meaningless when the PR is in fact approved is the same error in the other
  # direction, and it is the one that costs a merge.
  local v v_state
  v=$(head_verdict || true)
  # The state must be a REAL review state before we tell the caller the green is
  # trustworthy. A failed API call hands back an error document, whose .state is
  # null — and the old check ([ -n "$v" ] && [ "$v" != "null" ]) passed on it,
  # printing "does carry a null review; the green is not spurious" for a PR with
  # no reviews at all. That sentence is the single most dangerous thing this
  # script can say, because its whole job is gating merges.
  v_state=$(echo "$v" | jq -r '.state? // empty' 2>/dev/null || echo "")
  case "$v_state" in
    APPROVED|CHANGES_REQUESTED|COMMENTED|DISMISSED)
      echo "note: HEAD ${PR_HEAD:0:7} does carry a $v_state review; the green is not spurious." >&2
      return 0
      ;;
  esac
  if [ "$API_FAILED" -eq 1 ]; then
    echo "WARNING: could not read reviews for ${PR_HEAD:0:7} (API error) — verdict UNKNOWN." >&2
    echo "WARNING: do NOT treat this as approved. Check manually:" >&2
    echo "  gh pr view $PR --json reviews" >&2
    return 1
  fi
  case "$concl" in
    success|neutral|skipped)
      echo "WARNING: the 'CodeRabbit' status on ${PR_HEAD:0:7} reads '$concl' but NO review exists." >&2
      echo "WARNING: that green does not mean approved — CR posts it while capped, and" >&2
      echo "WARNING: also when it declines to re-review commits it considers already seen." >&2
      echo "WARNING: gate the merge on a review whose commit_id is HEAD, e.g." >&2
      echo "  gh pr view $PR --json reviews --jq '[.reviews[]|select(.user.login|test(\"coderabbit\";\"i\"))|select(.commit_id==\"$PR_HEAD\")]|last|.state'" >&2
      ;;
  esac
}

# Print a status block (used at both the --wait and no-wait exit paths). For a
# Fair-Usage cap, also surface the "Next review available in: N" line, which
# falls outside the 6-line body preview.
print_status() {
  local status="$1" kind="$2"
  echo "STATUS $kind"
  echo "$status" | jq -r '"[\(.created_at)] " + (.body | gsub("\r"; "") | split("\n")[0:6] | join(" \\n "))'
  if [ "$kind" = "FAIR_USAGE_LIMIT" ]; then
    local next
    next=$(echo "$status" | jq -r .body | grep -ioE 'Next[[:space:]]+(included[[:space:]]+)?review available in:?[^<]*' | head -1 | sed 's/[*]//g; s/[[:space:]]*$//')
    [ -n "$next" ] && echo "$next"
    if [ "$RETRY_FAIR_USAGE" -eq 0 ]; then
      echo "hint: re-run with --retry-on-fair-usage to wait this out; the cap is temporary." >&2
    fi
  fi
  warn_if_check_is_falsely_green
}

# Post @coderabbitai resume on the PR. Idempotent enough (CR ignores extra
# resumes). Returns 0 always.
post_resume() {
  gh pr comment "$PR" --body "@coderabbitai resume" >/dev/null 2>&1 || true
  echo "cr-check: posted @coderabbitai resume on PR #$PR" >&2
}

# Backoff sleeper for rate-limit retries. Walks 60s -> 300s -> 1800s -> 1800s ...
# Caller passes the attempt number (0-indexed).
rate_limit_backoff() {
  case "$1" in
    0) echo 60 ;;
    1) echo 300 ;;
    *) echo 1800 ;;
  esac
}

wait_for_review() {
  deadline=$(($(date +%s) + WAIT_SECONDS))
  rate_limit_attempt=0
  fair_usage_attempt=0
  pending_trigger=0
  auto_triggered=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    count=$(cr_reviews_since "$SINCE")
    if [ "$count" -gt 0 ]; then return 0; fi
    # Repo has auto-review disabled — the review will never land unless asked
    # (true for the initial review AND every re-review after a push). Notice it
    # and trigger once automatically, independent of --trigger, as long as a
    # review isn't already in flight. Guarded so we trigger at most once.
    if [ "$auto_triggered" -eq 0 ] && ! cr_check_pending && repo_auto_review_disabled; then
      echo "cr-check: CR auto-review disabled on this repo; triggering review automatically" >&2
      trigger_review
      auto_triggered=1
      SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      sleep 30
      continue
    fi
    if status=$(detect_status); then
      body=$(echo "$status" | jq -r .body)
      kind=$(classify_status_body "$body")
      # Auto-recovery paths.
      if [ "$AUTO_RESUME" -eq 1 ] && [ "$kind" = "PR_PAUSED" ]; then
        echo "cr-check: PR pause detected; auto-resuming" >&2
        post_resume
        sleep 5
        # Bump SINCE forward so the resume-ack doesn't re-match as a status.
        SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        if [ "$TRIGGER" -eq 1 ]; then trigger_review; fi
        sleep 30
        continue
      fi
      if [ "$RETRY_RATE_LIMIT" -eq 1 ] && [ "$kind" = "RATE_LIMIT" ]; then
        sleep_for=$(rate_limit_backoff "$rate_limit_attempt")
        echo "cr-check: rate-limited (attempt $((rate_limit_attempt+1))); sleeping ${sleep_for}s" >&2
        rate_limit_attempt=$((rate_limit_attempt+1))
        SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        sleep "$sleep_for"
        if [ "$TRIGGER" -eq 1 ]; then trigger_review; fi
        continue
      fi
      # Fair-usage cap: recoverable, and CR tells us exactly how long. Sleep the
      # stated interval and re-trigger — a capped run is DROPPED, not queued, so
      # without an explicit re-trigger CR never revisits these commits ("does not
      # re-review already reviewed commits").
      if [ "$RETRY_FAIR_USAGE" -eq 1 ] && [ "$kind" = "FAIR_USAGE_LIMIT" ]; then
        if sleep_for=$(fair_usage_sleep_seconds "$body"); then
          echo "cr-check: fair-usage cap; CR says it clears in ~$((sleep_for / 60))min — waiting" >&2
          fair_usage_attempt=$((fair_usage_attempt+1))
          if [ "$fair_usage_attempt" -gt 5 ]; then
            echo "cr-check: still capped after 5 waits; giving up so you can fall back" >&2
            print_status "$status" "$kind"
            return 2
          fi
          # Do NOT trigger here. Observed 2026-07-25 on PR #67: triggering while
          # still capped consumed quota and pushed the countdown UP (21min ->
          # 25min), so retrying tightened the noose. Sleep, then let the next
          # iteration re-detect; the trigger below fires only once the cap is
          # actually gone.
          pending_trigger=1
          SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
          # Deadline-aware. Sleeping past the deadline means waking with no
          # budget left to request the review, and the caller then sees a plain
          # timeout with no hint that the wait was structurally pointless.
          remaining=$((deadline - $(date +%s)))
          if [ "$sleep_for" -ge "$remaining" ]; then
            echo "cr-check: cap clears in ${sleep_for}s but only ${remaining}s of --wait-seconds remain." >&2
            echo "cr-check: refusing to sleep past the deadline. Re-run with --wait-seconds $((sleep_for + 600))." >&2
            print_status "$status" "$kind"
            return 2
          fi
          sleep "$sleep_for"
          continue
        fi
        echo "cr-check: fair-usage cap with no parseable reset time; not waiting" >&2
      fi
      # Anything else: report and stop.
      print_status "$status" "$kind"
      return 2
    fi
    # No blocking status this pass. If we slept out a fair-usage cap, THIS is the
    # moment to ask for the review — the cap has cleared, so the trigger will be
    # honoured instead of burning quota against a closed window.
    if [ "${pending_trigger:-0}" -eq 1 ]; then
      echo "cr-check: fair-usage cap cleared; requesting review" >&2
      trigger_review
      pending_trigger=0
      SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    fi
    sleep 30
  done
  if [ "${pending_trigger:-0}" -eq 1 ]; then
    echo "cr-check: deadline hit while a post-cap trigger was still PENDING." >&2
    echo "cr-check: the review was never requested, so none was ever coming." >&2
    echo "cr-check: post '@coderabbitai review' on PR #$PR, or re-run with a larger --wait-seconds." >&2
  fi
  return 3
}

# The merge gate is a DECISIVE review state on HEAD: APPROVED or
# CHANGES_REQUESTED. COMMENTED never moves a verdict, and CR posts a COMMENTED
# review for every inline thread reply, so the NEWEST review is routinely a
# COMMENTED that says nothing about approval.
#
# emit_findings shows one review — the newest — and used to print its state as
# though that were the verdict. On PR #199 (2026-07-31) CR posted APPROVED at
# 18:26:53Z and a COMMENTED thread reply at 18:27:03Z, both on the same commit.
# cr-check reported "(COMMENTED)" and the APPROVED was invisible, so the caller
# went off to query `gh pr view --json reviews` by hand to find the one state the
# whole script exists to surface. Compute it here instead, across every CR review
# on HEAD, independent of which review's findings get displayed.
# CR's last decisive review ON THE CURRENT HEAD, as {state, submitted_at}.
#
# GraphQL, not REST: `repos/N/pulls/N/reviews` 404s outright in some
# environments (seen 2026-08-17 on a private org repo, where every
# REST GET to it returned 404 while GraphQL returned the same data). The commit
# SHA is why this needs a hand-written query rather than `gh pr view --json
# reviews` — that shape omits the commit entirely, and a verdict that is not
# pinned to a SHA is exactly the stale-approval trap this function exists to
# avoid.
head_verdict() {
  [ -n "${PR_HEAD:-}" ] || return 1
  local owner name out
  owner=${REPO%%/*}
  name=${REPO##*/}
  out=$(gh api graphql -f query="
    {
      repository(owner: \"$owner\", name: \"$name\") {
        pullRequest(number: $PR) {
          reviews(first: 100) {
            nodes { state submittedAt author { login } commit { oid } }
          }
        }
      }
    }" --jq "
      [.data.repository.pullRequest.reviews.nodes[]
       | select(.author.login | test(\"coderabbit\"; \"i\"))
       | select(.commit.oid == \"$PR_HEAD\")
       | select(.state == \"APPROVED\" or .state == \"CHANGES_REQUESTED\" or .state == \"DISMISSED\")
       | {state, submitted_at: .submittedAt}]
      | sort_by(.submitted_at) | last // empty" 2>/dev/null) || { API_FAILED=1; return 1; }
  printf '%s' "$out"
}

# One block, always printed, whether or not any findings exist. Two lines,
# because they answer different questions and can legitimately disagree: the
# verdict is CR's own last decisive word on THIS commit, while reviewDecision is
# GitHub's aggregate across every reviewer and does not reset on a push.
print_head_verdict() {
  local v state ts d
  v=$(head_verdict || true)
  # .state must parse to a real review state. On an API failure $v is an error
  # document (or empty) whose .state is null, and the old check printed
  # "HEAD verdict: null" — which reads like a verdict and is not one.
  state=$(echo "$v" | jq -r '.state? // empty' 2>/dev/null || echo "")
  ts=$(echo "$v" | jq -r '.submitted_at? // empty' 2>/dev/null || echo "")
  case "$state" in
    APPROVED|CHANGES_REQUESTED|DISMISSED)
      echo "HEAD verdict: $state on ${PR_HEAD:0:8} ($ts)"
      ;;
    *)
      if [ "$API_FAILED" -eq 1 ]; then
        echo "HEAD verdict: UNKNOWN — could not read reviews for ${PR_HEAD:0:8} (API error)"
      else
        echo "HEAD verdict: NONE — no APPROVED/CHANGES_REQUESTED review on ${PR_HEAD:0:8}"
      fi
      ;;
  esac
  d=$(gh pr view "$PR" --json reviewDecision --jq '.reviewDecision // ""' 2>/dev/null || echo "")
  [ -n "$d" ] && echo "PR reviewDecision: $d"
  return 0
}

# Emit the actionable feedback for the latest CR review on this PR.
emit_findings() {
  # GraphQL, for the same reason head_verdict uses it: the REST reviews endpoint
  # 404s in some environments, and its error document is not distinguishable
  # from "no review" once it reaches the checks below.
  local owner name
  owner=${REPO%%/*}
  name=${REPO##*/}
  review=$(gh api graphql -f query="
    {
      repository(owner: \"$owner\", name: \"$name\") {
        pullRequest(number: $PR) {
          reviews(first: 100) {
            nodes { fullDatabaseId state body submittedAt author { login } commit { oid } }
          }
        }
      }
    }" --jq "
      [.data.repository.pullRequest.reviews.nodes[]
       | select(.author.login | test(\"coderabbit\"; \"i\"))
       | select(.submittedAt > \"$SINCE\")
       | {id: .fullDatabaseId, state, body, submitted_at: .submittedAt, commit_id: .commit.oid}]
      | sort_by(.submitted_at) | last // empty" 2>/dev/null) || { API_FAILED=1; review=""; }

  # An object with a real state, or nothing. Never an error document.
  if [ -n "$review" ]; then
    echo "$review" | jq -e 'type == "object" and (.state | type == "string")' >/dev/null 2>&1 || review=""
  fi

  if [ "$API_FAILED" -eq 1 ] && [ -z "$review" ]; then
    echo "could not read reviews for PR #$PR (API error) — status UNKNOWN, not 'no review'"
    print_head_verdict
    return 1
  fi

  if [ -z "$review" ] || [ "$review" = "null" ]; then
    echo "no CR review found since $SINCE"
    # Still report the verdict. A --since that lands after the approving review
    # finds no review to display while HEAD is in fact approved, and printing
    # only "no CR review found" reads as "not reviewed yet".
    print_head_verdict
    return 0
  fi

  state=$(echo "$review" | jq -r .state)
  rid=$(echo "$review" | jq -r .id)
  rdate=$(echo "$review" | jq -r .submitted_at)
  commit=$(echo "$review" | jq -r .commit_id | cut -c1-8)
  body=$(echo "$review" | jq -r .body)

  # Extract actionable count from review body header "Actionable comments posted: N"
  actionable=$(echo "$body" | grep -oE 'Actionable comments posted: [0-9]+' | head -1 | grep -oE '[0-9]+' || echo "?")

  echo "PR #$PR — commit $commit ($state) submitted $rdate"
  echo "actionable: $actionable"
  print_head_verdict
  # Say it out loud when the review being displayed is not the one that decides
  # the gate, so "(COMMENTED)" in the header above can never be read as the
  # verdict.
  if [ "$state" = "COMMENTED" ]; then
    echo "note: the review shown above is COMMENTED, which is not a verdict; read the HEAD verdict line."
  fi
  echo ""

  # Inline review comments belonging to this review.
  inline=$(gh api "repos/$REPO/pulls/$PR/comments?per_page=100" --paginate \
    --jq "[.[] | select(.pull_request_review_id == $rid) | {path, line: (.line // .original_line // .start_line), body}]" 2>/dev/null || echo "")
  # Must be a JSON array. On failure gh leaves its error document on STDOUT, and
  # `|| echo "[]"` APPENDS to it rather than replacing it — so the old code fed
  # jq a 404 body followed by "[]" and the length test died with "integer
  # expected", silently skipping every inline finding.
  echo "$inline" | jq -e 'type == "array"' >/dev/null 2>&1 || inline="[]"
  inline_n=$(echo "$inline" | jq 'length' 2>/dev/null || echo 0)
  case "$inline_n" in ''|*[!0-9]*) inline_n=0 ;; esac

  if [ "$inline_n" -gt 0 ]; then
    echo "$inline" | jq -r '.[] | "[\(.path):\(.line // "?")]\n\(.body | gsub("\r"; "") )"' | strip_cr_noise
  fi

  # Nitpicks live in review body, not inline comments. Extract them.
  if [ "$INCLUDE_NITPICKS" -eq 1 ]; then
    nits=$(echo "$body" | awk '/Nitpick comments \(/{p=1} p; /^<\/details>/{if(p)exit}' | strip_cr_noise || true)
    if [ -n "$nits" ]; then
      echo ""
      echo "--- nitpicks (from review body) ---"
      echo "$nits"
    fi
  fi
}

# Strip CR's noisy boilerplate from review prose:
# - Collapsed <details> blocks containing prompts, autofix, run-info
# - Markdown <summary> tags
# - "🤖 Prompt for AI Agents" sections
# - GitHub-flavored code-fence guidance
# - Long URLs and inline images
strip_cr_noise() {
  awk '
    BEGIN { skip = 0 }
    /<details>/ {
      # Read until matching </details>; if header mentions Prompt/Autofix/Run/Files, skip the whole block
      block = $0 "\n"
      depth = 1
      while ((getline line) > 0) {
        block = block line "\n"
        if (line ~ /<details>/) depth++
        if (line ~ /<\/details>/) { depth--; if (depth == 0) break }
      }
      if (block ~ /(Prompt for AI Agents|Autofix|Run configuration|Files selected|Path-based instructions|Additional context|Review profile|Plan:|Commits|Files skipped|Analysis chain|Patch sketch|Script executed|Web query|Committable suggestion|🧩|🤖|🪄|🧰|📓|📒|⚙️|📥|📝|ℹ️ Review info|Review details|🔇 Additional comments)/) next
      print block
      next
    }
    /^<summary>/ { gsub(/<\/?summary>/,""); print; next }
    /^---$/ { next }
    /^[[:space:]]*$/ { print ""; next }
    { print }
  ' | sed -E '/^<!--.*-->[[:space:]]*$/d; s/<\/?details>//g; s/<\/?blockquote>//g; s/^[[:space:]]+$//' \
    | awk 'BEGIN{blank=0} /./{print; blank=0; next} {if (blank==0) print; blank=1}'
}

# Warn (stderr only) when the caller is NOT waiting but HEAD isn't settled: either a CR
# review is in flight, or the latest review sits on an older commit than HEAD. In both cases
# nothing will notify the caller when the review lands, so a plain one-shot check silently
# misses the result (the failure this guard exists to prevent). Never touches stdout or the
# exit code — the skill parses stdout, and legit one-shot glances must stay usable.
warn_stale_head_if_not_waiting() {
  [ "$WAIT" -eq 1 ] && return 0
  [ -n "$PR_HEAD" ] || return 0
  local rc
  rc=$(gh api "repos/$REPO/pulls/$PR/reviews?per_page=50" \
    --jq "[.[] | select(.user.login | test(\"coderabbit\"; \"i\"))] | sort_by(.submitted_at) | last | .commit_id // empty" 2>/dev/null)
  if cr_check_pending; then
    echo "cr-check: ⚠ a CodeRabbit review is IN PROGRESS on HEAD ${PR_HEAD:0:8}; you are not waiting on it." >&2
    echo "cr-check:   nothing will notify you when it lands — re-run: cr-check $PR --wait  (with run_in_background)." >&2
  elif [ -n "$rc" ] && [ "$rc" != "$PR_HEAD" ]; then
    echo "cr-check: ⚠ HEAD ${PR_HEAD:0:8} is NOT yet reviewed (latest CR review is on ${rc:0:8})." >&2
    echo "cr-check:   if you just pushed, the incremental review is coming but won't notify you —" >&2
    echo "cr-check:   re-run: cr-check $PR --wait  (with run_in_background) to be pinged when it settles." >&2
  fi
}

if [ "$TRIGGER" -eq 1 ]; then
  trigger_review
fi

if [ "$WAIT" -eq 1 ]; then
  if wait_for_review; then
    emit_findings
  else
    rc=$?
    if [ "$rc" -eq 2 ]; then
      exit 2
    elif [ "$rc" -eq 3 ]; then
      echo "cr-check: no CR review within ${WAIT_SECONDS}s — check status manually" >&2
      exit 3
    fi
  fi
  exit 0
fi

# No --wait: just emit whatever's there now.
if status=$(detect_status); then
  body=$(echo "$status" | jq -r .body)
  kind=$(classify_status_body "$body")
  print_status "$status" "$kind"
  exit 2
fi
emit_findings
warn_stale_head_if_not_waiting
