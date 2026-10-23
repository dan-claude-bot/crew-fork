# duty-release.sh — the release cut (triage role, #762).
#
# The one duty in this engine that ends at a door a person opens. For every
# track in RELEASE_TRACKS (`owner/repo:path:tag-prefix[:auto|hold]`) the tick
# reads the main clone and the board, and decides — in shell, with every
# refusal's reason on the record — whether main carries a release nobody has
# cut: merges since the track's last tag that touch the track, fragments
# waiting in its changelog.d, VERSION armed `-dev`, CI green at main's head,
# no release PR open, main quiet for RELEASE_QUIET_S, the head not already
# cut. Only then does it buy a session, and the session does the half that
# needs judgment and a toolchain: the assembled section through ceremony's
# own `bin/changelog-assemble` at the consumer's pin, the drill record
# written honestly, one pull request carrying the release label — and then
# it STOPS. The approval is a person's (the site's *Publicar versión*, or a
# maintainer's merge); the engine never merges, tags or dispatches.
#
# One cut at a time, and a cut is never re-pushed: a release PR the engine
# opened is withdrawn when main moves past it (stale) and the next tick cuts
# the new head; one a person closed unmerged (refused) stays refused for that
# head — the ledger remembers the head, and only new merges make a new cut.
#
# The cut's memory is three files beside the other ledgers, so the store
# carries them across a reset and the host tick reads one of them:
#   .seen-release            `repo#<main sha> <ts>` — heads the engine cut
#                            or a person refused; never re-cut
#   .release-cut-<slug>      `<pr> <branch> <main sha>` — the open cut
#   .release-due-<slug>      `<repo> <epoch>` — a cut waiting for main to go
#                            quiet; the host tick starts the box when due
#
# shellcheck shell=bash

RELEASE_QUIET_S_DEFAULT=900
RELEASE_CEREMONY_REPO_DEFAULT="heavy-duty/ceremony"

_release_slug() { printf '%s\n' "${1//\//_}"; }

# _release_tracks — RELEASE_TRACKS parsed, one `repo path prefix rule` line
# per entry. Whitespace separates entries; colons separate fields; a missing
# path is `.`, a missing rule is `auto`. An unknown rule reads as `hold`,
# because a rule the operator wrote and the engine cannot read must not buy a
# cut by accident.
_release_tracks() {
  local entry repo path prefix rule
  # shellcheck disable=SC2086  # word-splitting the entries is the format
  for entry in ${RELEASE_TRACKS:-}; do
    IFS=: read -r repo path prefix rule <<<"$entry"
    [ -n "$repo" ] || continue
    [ -n "$path" ] || path=.
    rule="${rule:-auto}"
    case "$rule" in
      auto|hold) ;;
      *) warn "release: track $entry: rule '$rule' is neither auto nor hold; read as hold"; rule=hold ;;
    esac
    printf '%s %s %s %s\n' "$repo" "$path" "$prefix" "$rule"
  done
}

# _release_pin DIR — the ceremony pin the repository's release caller names on
# origin/main, or nothing. The pin is the consumer's, read from its tree and
# never from this engine's own: the two-contracts rule.
_release_pin() {
  local repo_re
  repo_re="$(printf '%s' "${RELEASE_CEREMONY_REPO:-$RELEASE_CEREMONY_REPO_DEFAULT}" | sed 's/[.[\*^$/]/\\&/g')"
  git -C "$1" show origin/main:.github/workflows/release.yml 2>/dev/null \
    | grep -oE "uses:[[:space:]]*$repo_re/\.github/workflows/release\.yml@[^[:space:]]+" \
    | head -1 | sed 's/.*@//'
}

# _release_ceremony_tree PIN — a checkout of ceremony at PIN under the work
# dir, printed; nonzero when it cannot be had. Cached per pin: the pin moves
# rarely and the clone is the one network read the cut makes beyond gh.
_release_ceremony_tree() {
  local pin="$1" dir
  dir="$WORK_DIR/.ceremony-$pin"
  if [ ! -x "$dir/bin/changelog-assemble" ]; then
    rm -rf "$dir"
    gh repo clone "${RELEASE_CEREMONY_REPO:-$RELEASE_CEREMONY_REPO_DEFAULT}" "$dir" \
        -- --quiet --depth 1 --branch "$pin" >/dev/null 2>&1 \
      || { rm -rf "$dir"; return 1; }
    [ -x "$dir/bin/changelog-assemble" ] || { rm -rf "$dir"; return 1; }
  fi
  printf '%s\n' "$dir"
}

# _release_last_tag DIR PREFIX — the track's newest release tag by creation
# date, bare `X.Y.Z` or `X.Y.Z-rcN` under the prefix. A bare-prefix track
# sees no other track's prefixed tags: the regex anchors on the digits.
_release_last_tag() {
  local dir="$1" prefix="$2" re
  re="$(printf '%s' "$prefix" | sed 's/[.[\*^$/]/\\&/g')"
  git -C "$dir" tag --sort=-creatordate -l "${prefix}*" 2>/dev/null \
    | grep -E "^${re}[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$" | head -1
}

# _release_version DIR PATH — the version main is armed for, from the track's
# VERSION: `X.Y.Z-dev` cuts X.Y.Z, `X.Y.Z-rcN-dev` cuts the candidate. Prints
# nothing when main is not armed, which is its own refusal.
_release_version() {
  local v sub="VERSION"
  [ "$2" = . ] || sub="${2%/}/VERSION"
  v="$(git -C "$1" show "origin/main:$sub" 2>/dev/null | head -1 | tr -d '[:space:]')"
  case "$v" in *-dev) printf '%s\n' "${v%-dev}" ;; *) return 1 ;; esac
}

# _release_pathspec PATH — sets _RELEASE_PATHSPEC, the `git` pathspec for the
# track: its directory, minus its own VERSION, because the merge door's re-arm
# commit (`X.Y.Z` → `X.Y.(Z+1)-dev`) touches VERSION and nothing else and is
# not a merge the track ships. A pull request that moves VERSION beside other
# files still counts, by those files.
_RELEASE_PATHSPEC=()
_release_pathspec() {
  if [ "$1" = . ]; then _RELEASE_PATHSPEC=(-- . ':(exclude)VERSION')
  else _RELEASE_PATHSPEC=(-- "${1%/}" ":(exclude)${1%/}/VERSION"); fi
}

# _release_merges DIR FROM PATH — `sha subject` lines of main's commits since
# FROM (a tag or sha) that touch the track; empty when main carries nothing
# for it. Squash merges are commits, so every row is one merged PR.
_release_merges() {
  local dir="$1" from="$2" path="$3"
  _release_pathspec "$path"
  git -C "$dir" log --no-merges --format='%h %s' "$from..origin/main" "${_RELEASE_PATHSPEC[@]}" 2>/dev/null
}

# _release_head_ts DIR REF — the committer date of REF, ISO-8601: the one
# timestamp a head has, so the seen-ledger row for a head is the same bytes
# every time the head is read, and a lexical compare suppresses it.
_release_head_ts() { git -C "$1" log -1 --format=%cI "$2" 2>/dev/null; }

# _release_fragments DIR PATH — the fragments waiting in the track's
# changelog.d on main, one name per line, the directory's own README and the
# declared `shape` anchor excluded (the two files changelog-assemble skips).
_release_fragments() {
  local dir="$1" path="$2" sub
  sub="${2%/}/changelog.d"; [ "$path" = . ] && sub="changelog.d"
  git -C "$dir" ls-tree --name-only "origin/main:$sub" 2>/dev/null \
    | grep -vx 'README.md' | grep -vx 'shape'
}

# _release_ci REPO SHA — green | pending | red | unknown, from the check runs
# at SHA. No runs at all is green: a repository without CI has no red to
# read. Unknown (the API did not answer) refuses like red — a cut is bought
# on evidence, never on its absence.
_release_ci() {
  local runs
  runs="$(gh api "repos/$1/commits/$2/check-runs?per_page=100" \
    --jq '[.check_runs[] | "\(.status) \(.conclusion // "")"]' 2>/dev/null)" || { echo unknown; return 0; }
  jq -r 'if length == 0 then "green"
         elif any(.[]; startswith("completed") | not) then "pending"
         elif any(.[]; test(" (failure|timed_out|cancelled|action_required|startup_failure)$")) then "red"
         else "green" end' <<<"$runs" 2>/dev/null || echo unknown
}

# _release_open_prs REPO — `num author branch` lines of the open pull requests
# carrying the release label, whoever opened them.
_release_open_prs() {
  gh pr list -R "$1" --state open --label "${LABEL_RELEASE:-release}" --limit 20 \
    --json number,author,headRefName \
    --jq '.[] | "\(.number) \(.author.login) \(.headRefName)"' 2>/dev/null
}

# _release_branch_is_other_track BRANCH REPO PREFIX — true when BRANCH is the
# cut branch of ANOTHER configured track of the same repository, so a second
# track's open cut does not hold this one (the site's cut does not wait for
# the admin's). A branch no configured track owns holds every track: a release
# PR a person opened by hand is still a release PR.
_release_branch_is_other_track() {
  local branch="$1" repo="$2" prefix="$3" trepo tprefix
  while read -r trepo _ tprefix _; do
    [ "$trepo" = "$repo" ] || continue
    [ "$tprefix" != "$prefix" ] || continue
    [ -n "$tprefix" ] || continue
    case "$branch" in release/"$tprefix"[0-9]*) return 0 ;; esac
  done < <(_release_tracks)
  return 1
}

_release_due_write() { # REPO DUE-EPOCH
  local f
  f="$DUTY_DIR/.release-due-$(_release_slug "$1")"
  printf '%s %s\n' "$1" "$2" >"$f.tmp" && mv -f "$f.tmp" "$f"
}
_release_due_clear() { rm -f "$DUTY_DIR/.release-due-$(_release_slug "$1")"; }

# _release_settle_cut REPO PATH DIR — what became of the cut the engine holds
# open for REPO, if any. Merged: forgotten. Closed unmerged by a person:
# refused — the head stays in the ledger so it is never re-cut. Still open
# and main moved past it on this track: stale — withdrawn, and the next tick
# cuts the new head. Still open and current: `open`, which holds the track.
# Sets RELEASE_SETTLED to one of none|shipped|refused|withdrawn|open — a
# variable and not stdout, because the function logs on the way and a caller
# reading it through `$(...)` would read the log lines too.
RELEASE_SETTLED=none
_release_settle_cut() {
  local repo="$1" path="$2" dir="$3" f num branch head state ahead
  RELEASE_SETTLED=none
  f="$DUTY_DIR/.release-cut-$(_release_slug "$repo")"
  [ -f "$f" ] || return 0
  read -r num branch head <"$f" || return 0
  state="$(gh pr view "$num" -R "$repo" --json state,mergedAt \
    --jq '"\(.state) \(.mergedAt // "")"' 2>/dev/null)" || { RELEASE_SETTLED=open; return 0; }
  case "$state" in
    MERGED*) rm -f "$f"; log "release: $repo#$num shipped ($branch) — the cut is forgotten"; RELEASE_SETTLED=shipped; return 0 ;;
    CLOSED*)
      rm -f "$f"
      printf '%s#%s %s\n' "$repo" "$head" "$(_release_head_ts "$dir" "$head")" | ledger_commit "$DUTY_DIR/.seen-release"
      log "release: $repo#$num was closed without merging ($branch) — refused; ${head:0:7} is not cut again"
      RELEASE_SETTLED=refused; return 0 ;;
  esac
  _release_pathspec "$path"
  ahead="$(git -C "$dir" rev-list --count "$head..origin/main" "${_RELEASE_PATHSPEC[@]}" 2>/dev/null || echo 0)"
  if [ "${ahead:-0}" -gt 0 ]; then
    if gh pr close "$num" -R "$repo" --delete-branch \
        --comment "Withdrawn by $ME: main moved past this cut (${ahead} merge(s) on the track since ${head:0:7}). The next tick cuts the new head; nothing here is re-pushed." >/dev/null 2>&1; then
      rm -f "$f"
      log "release: $repo#$num withdrawn ($branch) — main moved $ahead merge(s) past ${head:0:7}; the new head is cut next tick"
      RELEASE_SETTLED=withdrawn; return 0
    fi
    warn "release: $repo#$num is stale (main moved past ${head:0:7}) and could not be withdrawn; it holds the track until it can"
    RELEASE_SETTLED=open; return 0
  fi
  RELEASE_SETTLED=open
}

# _release_gate REPO PATH PREFIX RULE DIR — the decision table, one row per
# refusal, each a `no release duty:` line. Sets RELEASE_VERSION,
# RELEASE_LAST_TAG, RELEASE_MAIN_HEAD, RELEASE_MERGES, RELEASE_FRAGMENTS,
# RELEASE_PIN, RELEASE_TREE for the caller on success.
RELEASE_VERSION=""; RELEASE_LAST_TAG=""; RELEASE_MAIN_HEAD=""; RELEASE_MAIN_TS=""
RELEASE_MERGES=""; RELEASE_FRAGMENTS=""; RELEASE_PIN=""; RELEASE_TREE=""
_release_gate() {
  local repo="$1" path="$2" prefix="$3" rule="$4" dir="$5"
  local name="$repo ${prefix:-<bare>}@$path" prs num author branch
  local head ci age now quiet fresh
  RELEASE_VERSION=""; RELEASE_LAST_TAG=""; RELEASE_MAIN_HEAD=""; RELEASE_MAIN_TS=""
  RELEASE_MERGES=""; RELEASE_FRAGMENTS=""; RELEASE_PIN=""; RELEASE_TREE=""
  if [ "$rule" = hold ]; then
    log "no release duty: $name — held by RELEASE_TRACKS (rule hold); the operator cuts"; return 1
  fi
  _release_settle_cut "$repo" "$path" "$dir"
  case "$RELEASE_SETTLED" in
    open) log "no release duty: $name — the engine's own release PR is open and current; the approval is a person's"; return 1 ;;
    withdrawn) return 1 ;;
  esac
  prs="$(_release_open_prs "$repo")"
  while read -r num author branch; do
    [ -n "$num" ] || continue
    _release_branch_is_other_track "$branch" "$repo" "$prefix" && continue
    log "no release duty: $name — release PR #$num by $author ($branch) is already open"; return 1
  done <<<"$prs"
  if ! RELEASE_VERSION="$(_release_version "$dir" "$path")"; then
    log "no release duty: $name — VERSION on main is not armed (no -dev suffix); nothing to stamp"; return 1
  fi
  RELEASE_LAST_TAG="$(_release_last_tag "$dir" "$prefix")"
  if [ -z "$RELEASE_LAST_TAG" ]; then
    log "no release duty: $name — no release tag under the prefix yet; the first cut is the operator's (the known first-release edge)"; return 1
  fi
  RELEASE_MERGES="$(_release_merges "$dir" "$RELEASE_LAST_TAG" "$path")"
  if [ -z "$RELEASE_MERGES" ]; then
    _release_due_clear "$repo"
    log "no release duty: $name — main carries nothing for the track since $RELEASE_LAST_TAG"; return 1
  fi
  RELEASE_FRAGMENTS="$(_release_fragments "$dir" "$path")"
  case "$RELEASE_VERSION" in
    *-rc[0-9]*) ;;  # a candidate is tag-only: fragments survive it (RELEASES.md)
    *)
      if [ -z "$RELEASE_FRAGMENTS" ]; then
        log "no release duty: $name — $(printf '%s\n' "$RELEASE_MERGES" | awk 'NF' | wc -l | tr -d ' ') merge(s) since $RELEASE_LAST_TAG but no fragment in changelog.d; a release publishes prose"; return 1
      fi ;;
  esac
  head="$(git -C "$dir" rev-parse origin/main 2>/dev/null)"
  [ -n "$head" ] || { warn "release: $name — origin/main unreadable in $dir"; return 1; }
  RELEASE_MAIN_HEAD="$head"
  RELEASE_MAIN_TS="$(_release_head_ts "$dir" "$head")"
  fresh="$(printf '%s#%s %s\n' "$repo" "$head" "$RELEASE_MAIN_TS" | ledger_filter "$DUTY_DIR/.seen-release")"
  if [ -z "$fresh" ]; then
    log "no release duty: $name — ${head:0:7} was already cut or refused; only new merges make a new cut"; return 1
  fi
  now="$(date +%s)"
  age=$((now - $(git -C "$dir" log -1 --format=%ct origin/main 2>/dev/null || echo "$now")))
  quiet="${RELEASE_QUIET_S:-$RELEASE_QUIET_S_DEFAULT}"
  case "$quiet" in ''|*[!0-9]*) quiet="$RELEASE_QUIET_S_DEFAULT" ;; esac
  if [ "$age" -lt "$quiet" ]; then
    _release_due_write "$repo" $((now + quiet - age))
    log "no release duty: $name — main moved ${age}s ago, under the ${quiet}s quiet window; due in $((quiet - age))s"; return 1
  fi
  _release_due_clear "$repo"
  ci="$(_release_ci "$repo" "$head")"
  case "$ci" in
    green) ;;
    pending) log "no release duty: $name — CI at ${head:0:7} is still running; a cut is bought on a green head"; return 1 ;;
    *) log "no release duty: $name — CI at ${head:0:7} is $ci; a cut is bought on a green head"; return 1 ;;
  esac
  RELEASE_PIN="$(_release_pin "$dir")"
  if [ -z "$RELEASE_PIN" ]; then
    log "no release duty: $name — the repository names no ceremony pin in .github/workflows/release.yml; the assembler has no version to run at"; return 1
  fi
  if ! RELEASE_TREE="$(_release_ceremony_tree "$RELEASE_PIN")"; then
    warn "release: $name — ceremony@$RELEASE_PIN could not be checked out; the cut waits"; return 1
  fi
  return 0
}

# _release_after REPO BRANCH HEAD TS — the session's product, verified on the
# board: the ledger row is EARNED by the pull request existing, the rule every
# seen-ledger follows, so a session that died before `gh pr create` leaves
# the head uncut and the next tick cuts it again.
_release_after() {
  local repo="$1" branch="$2" head="$3" ts="$4" num
  num="$(gh pr list -R "$repo" --state open --label "${LABEL_RELEASE:-release}" --limit 20 \
    --json number,author,headRefName 2>/dev/null \
    | jq -r --arg b "$branch" --arg me "$ME" \
        '.[] | select(.headRefName == $b and .author.login == $me) | .number' 2>/dev/null | head -1)"
  if [ -z "$num" ]; then
    warn "release: $repo — the session ended without opening $branch; ${head:0:7} is cut again next tick"
    return 1
  fi
  printf '%s %s %s\n' "$num" "$branch" "$head" >"$DUTY_DIR/.release-cut-$(_release_slug "$repo").tmp" \
    && mv -f "$DUTY_DIR/.release-cut-$(_release_slug "$repo").tmp" "$DUTY_DIR/.release-cut-$(_release_slug "$repo")"
  printf '%s#%s %s\n' "$repo" "$head" "$ts" | ledger_commit "$DUTY_DIR/.seen-release"
  log "release: $repo#$num opened ($branch at ${head:0:7}) — the approval is a person's; the engine stops here"
  return 0
}

duty_release() {
  local repo path prefix rule dir slug name branch wt_rules merges fragments
  [ -n "${RELEASE_TRACKS:-}" ] || return 0
  while read -r repo path prefix rule; do
    [ -n "$repo" ] || continue
    if ! read_repo_list "$REPOS_FILE" | grep -Fx -- "$repo" >/dev/null; then
      warn "release: $repo is in RELEASE_TRACKS but not in this box's registry; skipped"
      continue
    fi
    slug="${repo//\//__}"; name="${repo##*/}"
    dir="$WORK_DIR/$slug"
    ensure_main_clone "$repo" "$dir" || { warn "release: $repo — main clone unavailable; the cut waits"; continue; }
    git -C "$dir" fetch -q --tags origin 2>/dev/null || warn "release: $repo — tag fetch failed; the last tag may be stale"
    _release_gate "$repo" "$path" "$prefix" "$rule" "$dir" || continue
    branch="release/${prefix}${RELEASE_VERSION}"
    merges="$(printf '%s\n' "$RELEASE_MERGES" | awk 'NF' | paste -sd';' - | sed 's/;/; /g')"
    fragments="$(printf '%s\n' "$RELEASE_FRAGMENTS" | awk 'NF' | paste -sd' ' -)"
    [ -n "$fragments" ] || fragments="none (a candidate is tag-only)"
    wt_rules="$(render_prompt fragment-wt-rules.txt WT_DIR="$TREES_DIR/$slug" ME="$ME" NAME="$name")"
    log "release: $repo — cutting ${prefix}${RELEASE_VERSION} from ${RELEASE_MAIN_HEAD:0:7} (since $RELEASE_LAST_TAG; ceremony@$RELEASE_PIN)"
    run_session release "$repo" "$dir" "${TIMEOUT_RELEASE:-2400}" \
      "$(render_prompt release.txt ME="$ME" REPO="$repo" NAME="$name" TRACK_PATH="$path" TAG_PREFIX="$prefix" VERSION="$RELEASE_VERSION" LAST_TAG="$RELEASE_LAST_TAG" MAIN_HEAD="$RELEASE_MAIN_HEAD" MERGES="$merges" FRAGMENTS="$fragments" CEREMONY_PIN="$RELEASE_PIN" CEREMONY_TREE="$RELEASE_TREE" BRANCH="$branch" LABEL_RELEASE="${LABEL_RELEASE:-release}" WT_RULES="$wt_rules")"
    _release_after "$repo" "$branch" "$RELEASE_MAIN_HEAD" "$RELEASE_MAIN_TS" || true
  done < <(_release_tracks)
  return 0
}
