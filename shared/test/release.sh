#!/usr/bin/env bash
# Offline contract suite for the release cut (#762): the decision table, the
# cut's memory, withdrawal and refusal, against a git fixture shaped like a
# consumer with release tracks (la-familia-site's `apps/site`, `site-` tags).
# gh and the session are stubbed; git is real.
# shellcheck disable=SC2016  # the pins quote engine source lines verbatim
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=shared/test/lib.sh
source "$HERE/lib.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG
export XDG_CONFIG_HOME="$TMP/xdg-empty"
mkdir -p "$XDG_CONFIG_HOME"
export DUTY_DIR="$TMP/duty"
mkdir -p "$DUTY_DIR/work"
export HOME="${HOME:-$TMP}"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
# shellcheck source=shared/lib/common.sh
source "$SHARED/lib/common.sh"
PROMPTS_DIR="$SHARED/prompts"
# shellcheck source=shared/lib/duty-release.sh
source "$SHARED/lib/duty-release.sh"
ME=dan-claude-bot
REPOS_FILE="$TMP/repos.txt"
printf 'acme/site\n' >"$REPOS_FILE"

# ── the fixture: a consumer with two tracks, one released once ─────────────
ORIGIN="$TMP/origin"
gq() { git -C "$ORIGIN" "$@" >/dev/null 2>&1; }
git init -q -b main "$ORIGIN"
mkdir -p "$ORIGIN/apps/site/changelog.d" "$ORIGIN/apps/site/drills" "$ORIGIN/apps/admin" "$ORIGIN/.github/workflows"
printf '2.1.45-dev\n' >"$ORIGIN/apps/site/VERSION"
printf '# changelog.d\n' >"$ORIGIN/apps/site/changelog.d/README.md"
printf '## Unreleased\n' >"$ORIGIN/apps/site/CHANGELOG.md"
printf '2.0.0-rc50-dev\n' >"$ORIGIN/apps/admin/VERSION"
printf 'jobs:\n  release:\n    uses: heavy-duty/ceremony/.github/workflows/release.yml@0.7.11\n' >"$ORIGIN/.github/workflows/release.yml"
gq add -A; gq commit -q -m "init"
printf '2.1.45\n' >"$ORIGIN/apps/site/VERSION"; gq add -A; gq commit -q -m "release: site-2.1.45"
gq tag site-2.1.45
printf '2.1.46-dev\n' >"$ORIGIN/apps/site/VERSION"; gq add -A; gq commit -q -m "chore: re-arm 2.1.46-dev"
REARM_HEAD="$(git -C "$ORIGIN" rev-parse HEAD)"

# The stubs. ensure_main_clone is the engine's fork-aware clone; here a plain
# clone of the fixture, fetched, which is the part the duty reads.
ensure_main_clone() { # REPO DIR
  if [ ! -d "$2/.git" ]; then git clone -q "$ORIGIN" "$2" 2>/dev/null || return 1; fi
  git -C "$2" fetch -q origin 2>/dev/null
}
GH_CALLS="$TMP/gh-calls"
gh() {
  printf 'GH %s\n' "$*" >>"$GH_CALLS"
  case "$*" in
    "pr list"*"--jq"*)
      printf '%s\n' "${GH_PRS:-}" | awk 'NF' ;;
    "pr list"*)
      printf '%s\n' "${GH_PRS:-}" | awk 'NF' | jq -Rn '[inputs | split(" ") | {number: (.[0]|tonumber), author: {login: .[1]}, headRefName: .[2]}]' ;;
    "pr view"*"--json state,mergedAt"*)
      printf '%s\n' "${GH_PR_STATE:-OPEN }" ;;
    "pr close"*)
      return "${GH_CLOSE_RC:-0}" ;;
    "api repos/"*"/check-runs"*)
      case "${GH_CI:-green}" in
        green) echo '["completed success","completed skipped"]' ;;
        none) echo '[]' ;;
        pending) echo '["completed success","in_progress "]' ;;
        red) echo '["completed success","completed failure"]' ;;
        fail) return 1 ;;
      esac ;;
    "repo clone"*)
      [ -z "${GH_CEREMONY_FAIL:-}" ] || return 1
      # the clone target is the third word
      # shellcheck disable=SC2048,SC2086  # re-split: the clone target is the fourth word
      set -- $*; mkdir -p "$4/bin"; printf '#!/bin/sh\n' >"$4/bin/changelog-assemble"; chmod +x "$4/bin/changelog-assemble" ;;
    *) return 1 ;;
  esac
}
SESSION_LOG="$TMP/session"
run_session() { # kind key dir tmo prompt
  printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >>"$SESSION_LOG"
  printf '%s' "$5" >"$TMP/prompt"
  # The session's product, when the case says it opens one.
  [ -z "${SIM_PR_AFTER:-}" ] || GH_PRS="$SIM_PR_AFTER"
  return 0
}

rel_reset() {
  rm -f "$DUTY_DIR"/.seen-release "$DUTY_DIR"/.release-* "$SESSION_LOG" "$TMP/prompt"
  : >"$GH_CALLS"
}
rel_run() { # env assignments are the caller's; prints the duty's log
  duty_release 2>&1
}
sessions() { [ -f "$SESSION_LOG" ] && wc -l <"$SESSION_LOG" | tr -d ' ' || echo 0; }
SITE_TRACK="acme/site:apps/site:site-"
ADMIN_TRACK="acme/site:apps/admin:admin-:hold"

# ── RELEASE_TRACKS parses ────────────────────────────────────────────────────
t tracks-parse-every-field "$(printf 'a/b apps/x x- auto\nc/d . - auto\nc/d .  hold\n')" \
  "$(RELEASE_TRACKS=$'a/b:apps/x:x-\nc/d:.:-\nc/d:.::hold' _release_tracks)"
t tracks-missing-path-is-the-root "e/f . pre- auto" "$(RELEASE_TRACKS='e/f::pre-' _release_tracks | sed 's/[[:space:]]*$//')"
t tracks-unknown-rule-reads-as-hold 1 "$(RELEASE_TRACKS='e/f:p:q:weird' _release_tracks | grep -c '^e/f p q hold$')"
t tracks-unknown-rule-warns 1 "$(RELEASE_TRACKS='e/f:p:q:weird' _release_tracks 2>&1 | grep -c 'WARN: release: track e/f:p:q:weird')"
t tracks-empty-is-no-tracks "" "$(RELEASE_TRACKS='' _release_tracks)"

# ── the readers, against the fixture ─────────────────────────────────────────
CLONE="$DUTY_DIR/work/acme__site"
ensure_main_clone acme/site "$CLONE"
git -C "$CLONE" fetch -q --tags origin
t reads-the-pin-from-the-release-caller 0.7.11 "$(_release_pin "$CLONE")"
t reads-the-last-tag-under-the-prefix 2.1.45 "$(_release_last_tag "$CLONE" site- | sed 's/^site-//')"
t a-prefix-with-no-tag-reads-nothing "" "$(_release_last_tag "$CLONE" admin-)"
t reads-the-armed-version 2.1.46 "$(_release_version "$CLONE" apps/site)"
t a-root-track-reads-its-own-version "" "$(_release_version "$CLONE" . || true)"
t the-re-arm-commit-is-not-a-merge-of-the-track "" "$(_release_merges "$CLONE" site-2.1.45 apps/site)"
t fragments-exclude-the-directory-readme "" "$(_release_fragments "$CLONE" apps/site)"
GH_CI=green; t ci-green-reads-green green "$(_release_ci acme/site "$REARM_HEAD")"
GH_CI=none;  t ci-no-runs-reads-green green "$(_release_ci acme/site "$REARM_HEAD")"
GH_CI=pending; t ci-a-running-check-reads-pending pending "$(_release_ci acme/site "$REARM_HEAD")"
GH_CI=red;   t ci-a-failed-check-reads-red red "$(_release_ci acme/site "$REARM_HEAD")"
GH_CI=fail;  t ci-an-unanswered-api-reads-unknown unknown "$(_release_ci acme/site "$REARM_HEAD")"
GH_CI=green
t another-tracks-cut-branch-is-recognised 0 \
  "$(RELEASE_TRACKS="$SITE_TRACK $ADMIN_TRACK" _release_branch_is_other_track release/admin-2.0.0-rc51 acme/site site-; echo $?)"
t a-hand-named-release-branch-is-nobodys-track 1 \
  "$(RELEASE_TRACKS="$SITE_TRACK $ADMIN_TRACK" _release_branch_is_other_track release/hotfix acme/site site-; echo $?)"
t ones-own-prefix-is-not-another-track 1 \
  "$(RELEASE_TRACKS="$SITE_TRACK $ADMIN_TRACK" _release_branch_is_other_track release/site-2.1.46 acme/site site-; echo $?)"

# ── the decision table ───────────────────────────────────────────────────────
rel_reset
t no-tracks-no-duty "" "$(RELEASE_TRACKS='' rel_run)"
t no-tracks-no-session 0 "$(sessions)"

rel_reset
OUT="$(RELEASE_TRACKS='other/repo:.:' rel_run)"
t a-track-outside-the-registry-is-skipped 1 "$(grep -c 'WARN: release: other/repo is in RELEASE_TRACKS but not in this box' <<<"$OUT")"

rel_reset
OUT="$(RELEASE_TRACKS="$ADMIN_TRACK" rel_run)"
t a-held-track-says-so 1 "$(grep -c 'no release duty: acme/site admin-@apps/admin — held by RELEASE_TRACKS' <<<"$OUT")"
t a-held-track-buys-nothing 0 "$(sessions)"

# nothing since the tag: only the re-arm
rel_reset
OUT="$(RELEASE_TRACKS="$SITE_TRACK" rel_run)"
t nothing-since-the-tag-is-named 1 "$(grep -c 'no release duty: acme/site site-@apps/site — main carries nothing for the track since site-2.1.45' <<<"$OUT")"
t nothing-since-the-tag-buys-nothing 0 "$(sessions)"

# a merge on the OTHER track is nothing for this one
printf 'x\n' >"$ORIGIN/apps/admin/thing.txt"; gq add -A; gq commit -q -m "feat(admin): thing (#1)"
rel_reset
OUT="$(RELEASE_TRACKS="$SITE_TRACK" rel_run)"
t an-off-track-merge-is-nothing-for-the-track 1 "$(grep -c 'main carries nothing for the track since site-2.1.45' <<<"$OUT")"

# a merge on the track, but no fragment
printf 'y\n' >"$ORIGIN/apps/site/page.txt"; gq add -A; gq commit -q -m "feat(site): page (#2)"
rel_reset
OUT="$(RELEASE_TRACKS="$SITE_TRACK" rel_run)"
t a-merge-without-a-fragment-is-refused 1 "$(grep -c 'no release duty: acme/site site-@apps/site — 1 merge(s) since site-2.1.45 but no fragment in changelog.d; a release publishes prose' <<<"$OUT")"
t a-merge-without-a-fragment-buys-nothing 0 "$(sessions)"

# the fragment lands: now the quiet window holds (the commit is seconds old)
printf '### Added\n\n- The page (#2).\n' >"$ORIGIN/apps/site/changelog.d/2.md"; gq add -A; gq commit -q -m "docs: fragment for #2"
HEAD1="$(git -C "$ORIGIN" rev-parse HEAD)"
rel_reset
OUT="$(RELEASE_TRACKS="$SITE_TRACK" rel_run)"
t a-fresh-head-waits-for-the-quiet-window 1 "$(grep -c 'no release duty: acme/site site-@apps/site — main moved [0-9]*s ago, under the 900s quiet window; due in [0-9]*s' <<<"$OUT")"
t the-wait-is-written-for-the-host-tick 1 "$(grep -c '^acme/site [0-9][0-9]*$' "$DUTY_DIR/.release-due-acme_site" 2>/dev/null || true)"
due="$(awk '{print $2}' "$DUTY_DIR/.release-due-acme_site" 2>/dev/null)"; now="$(date +%s)"
t the-due-time-is-inside-the-window 1 "$([ "${due:-0}" -gt "$now" ] && [ "${due:-0}" -le $((now + 900)) ] && echo 1 || echo 0)"
t a-waiting-head-buys-nothing 0 "$(sessions)"

# quiet satisfied: CI decides
for ci in pending red fail; do
  rel_reset
  OUT="$(GH_CI=$ci RELEASE_QUIET_S=0 RELEASE_TRACKS="$SITE_TRACK" rel_run)"
  case "$ci" in
    pending) t "ci-$ci-refuses-the-cut" 1 "$(grep -c "no release duty: acme/site site-@apps/site — CI at ${HEAD1:0:7} is still running" <<<"$OUT")" ;;
    red)     t "ci-$ci-refuses-the-cut" 1 "$(grep -c "no release duty: acme/site site-@apps/site — CI at ${HEAD1:0:7} is red" <<<"$OUT")" ;;
    fail)    t "ci-$ci-refuses-the-cut" 1 "$(grep -c "no release duty: acme/site site-@apps/site — CI at ${HEAD1:0:7} is unknown" <<<"$OUT")" ;;
  esac
  t "ci-$ci-buys-nothing" 0 "$(sessions)"
done
t quiet-satisfied-clears-the-wait 0 "$(find "$DUTY_DIR" -maxdepth 1 -name '.release-due-*' | wc -l | tr -d ' ')"

# a release PR someone else opened holds the track; another track's does not
rel_reset
OUT="$(GH_PRS='77 danmt release/site-2.1.46' RELEASE_QUIET_S=0 RELEASE_TRACKS="$SITE_TRACK" rel_run)"
t an-open-release-pr-holds-the-track 1 "$(grep -c 'no release duty: acme/site site-@apps/site — release PR #77 by danmt (release/site-2.1.46) is already open' <<<"$OUT")"
t an-open-release-pr-buys-nothing 0 "$(sessions)"
rel_reset
OUT="$(GH_PRS='78 danmt release/admin-2.0.0-rc51' GH_CEREMONY_FAIL=1 RELEASE_QUIET_S=0 RELEASE_TRACKS="$SITE_TRACK $ADMIN_TRACK" rel_run)"
t another-tracks-open-cut-does-not-hold-this-one 0 "$(grep -c 'is already open' <<<"$OUT")"
t ceremony-unreachable-warns-and-waits 1 "$(grep -c 'WARN: release: acme/site site-@apps/site — ceremony@0.7.11 could not be checked out; the cut waits' <<<"$OUT")"
t ceremony-unreachable-buys-nothing 0 "$(sessions)"
t ceremony-unreachable-leaves-no-half-tree 0 "$(find "$DUTY_DIR/work" -maxdepth 1 -name '.ceremony-*' | wc -l | tr -d ' ')"

# the pin must be readable
gq mv .github/workflows/release.yml .github/workflows/release.yml.off; gq commit -q -m "chore: no caller"
rel_reset
OUT="$(RELEASE_QUIET_S=0 RELEASE_TRACKS="$SITE_TRACK" rel_run)"
t no-ceremony-pin-is-refused 1 "$(grep -c 'names no ceremony pin in .github/workflows/release.yml' <<<"$OUT")"
gq mv .github/workflows/release.yml.off .github/workflows/release.yml; gq commit -q -m "chore: caller back"
HEAD2="$(git -C "$ORIGIN" rev-parse HEAD)"

# ── the green path ───────────────────────────────────────────────────────────
rel_reset
OUT="$(SIM_PR_AFTER="91 dan-claude-bot release/site-2.1.46" RELEASE_QUIET_S=0 RELEASE_TRACKS="$SITE_TRACK" rel_run)"
t green-head-announces-the-cut 1 "$(grep -c "release: acme/site — cutting site-2.1.46 from ${HEAD2:0:7} (since site-2.1.45; ceremony@0.7.11)" <<<"$OUT")"
t green-head-buys-one-session 1 "$(sessions)"
t the-session-is-the-release-kind-at-its-timeout "release|acme/site|$CLONE|2400" "$(cat "$SESSION_LOG")"
t the-ceremony-tree-is-checked-out-at-the-pin 1 "$([ -x "$DUTY_DIR/work/.ceremony-0.7.11/bin/changelog-assemble" ] && echo 1 || echo 0)"
t every-prompt-slot-is-filled 0 "$(grep -c '{{' "$TMP/prompt" || true)"
for needle in "cutting the release of the track at apps/site" "tags site-X.Y.Z" "since site-2.1.45" "feat(site): page (#2)" "changelog.d are: 2.md" "armed 2.1.46-dev" "pin 0.7.11" "$DUTY_DIR/work/.ceremony-0.7.11/bin/changelog-assemble 2.1.46" "Create branch release/site-2.1.46" "git push -u fork release/site-2.1.46" "--head dan-claude-bot:release/site-2.1.46 --label release" "$TREES_DIR/acme__site/" "(5) STOP"; do
  t "prompt-names-${needle//[^a-zA-Z0-9]/-}" 1 "$(grep -cF -- "$needle" "$TMP/prompt" || true)"
done
t the-cut-is-remembered "91 release/site-2.1.46 $HEAD2" "$(cat "$DUTY_DIR/.release-cut-acme_site")"
t the-head-is-in-the-seen-ledger 1 "$(grep -c "^acme/site#$HEAD2 " "$DUTY_DIR/.seen-release")"
t the-opening-is-logged 1 "$(grep -c "release: acme/site#91 opened (release/site-2.1.46 at ${HEAD2:0:7}) — the approval is a person's; the engine stops here" <<<"$OUT")"

# the second tick: the engine's own PR is open and current — nothing
: >"$SESSION_LOG"
OUT="$(GH_PRS="91 dan-claude-bot release/site-2.1.46" GH_PR_STATE="OPEN " RELEASE_QUIET_S=0 RELEASE_TRACKS="$SITE_TRACK" rel_run)"
t second-tick-holds-on-the-open-cut 1 "$(grep -c "no release duty: acme/site site-@apps/site — the engine's own release PR is open and current; the approval is a person's" <<<"$OUT")"
t second-tick-buys-nothing 0 "$(sessions)"

# shipped: the PR merged — the memory is forgotten and the new head is the re-arm
OUT="$(GH_PRS="" GH_PR_STATE="MERGED 2026-10-23T12:00:00Z" RELEASE_QUIET_S=0 RELEASE_TRACKS="$SITE_TRACK" rel_run)"
t a-shipped-cut-is-forgotten 1 "$(grep -c 'release: acme/site#91 shipped (release/site-2.1.46) — the cut is forgotten' <<<"$OUT")"
t a-shipped-cut-leaves-no-memory 0 "$(find "$DUTY_DIR" -maxdepth 1 -name '.release-cut-*' | wc -l | tr -d ' ')"
t the-shipped-head-is-not-cut-again 1 "$(grep -c "${HEAD2:0:7} was already cut or refused; only new merges make a new cut" <<<"$OUT")"

# refused: a person closed it unmerged — the head stays refused
rel_reset
OUT="$(SIM_PR_AFTER="92 dan-claude-bot release/site-2.1.46" RELEASE_QUIET_S=0 RELEASE_TRACKS="$SITE_TRACK" rel_run)"
: >"$SESSION_LOG"
OUT="$(GH_PRS="" GH_PR_STATE="CLOSED " RELEASE_QUIET_S=0 RELEASE_TRACKS="$SITE_TRACK" rel_run)"
t a-refused-cut-is-named 1 "$(grep -c "release: acme/site#92 was closed without merging (release/site-2.1.46) — refused; ${HEAD2:0:7} is not cut again" <<<"$OUT")"
t a-refused-head-is-not-re-pushed 1 "$(grep -c "${HEAD2:0:7} was already cut or refused" <<<"$OUT")"
t a-refused-cut-buys-nothing 0 "$(sessions)"
OUT="$(GH_PRS="" RELEASE_QUIET_S=0 RELEASE_TRACKS="$SITE_TRACK" rel_run)"
t a-refused-head-stays-refused-next-tick 1 "$(grep -c "${HEAD2:0:7} was already cut or refused" <<<"$OUT")"

# stale: main moved past the engine's open cut — withdrawn, then re-cut
rel_reset
OUT="$(SIM_PR_AFTER="93 dan-claude-bot release/site-2.1.46" RELEASE_QUIET_S=0 RELEASE_TRACKS="$SITE_TRACK" rel_run)"
printf 'z\n' >"$ORIGIN/apps/site/other.txt"; printf -- '- Other (#3).\n' >"$ORIGIN/apps/site/changelog.d/3.md"; gq add -A; gq commit -q -m "feat(site): other (#3)"
HEAD3="$(git -C "$ORIGIN" rev-parse HEAD)"
: >"$SESSION_LOG"; : >"$GH_CALLS"
OUT="$(GH_PRS="93 dan-claude-bot release/site-2.1.46" GH_PR_STATE="OPEN " RELEASE_QUIET_S=0 RELEASE_TRACKS="$SITE_TRACK" rel_run)"
t a-stale-cut-is-withdrawn 1 "$(grep -c "release: acme/site#93 withdrawn (release/site-2.1.46) — main moved 1 merge(s) past ${HEAD2:0:7}; the new head is cut next tick" <<<"$OUT")"
t withdrawal-closes-the-pr-and-its-branch 1 "$(grep -c '^GH pr close 93 -R acme/site --delete-branch --comment Withdrawn by dan-claude-bot: main moved past this cut' "$GH_CALLS")"
t withdrawal-buys-nothing-this-tick 0 "$(sessions)"
t withdrawal-forgets-the-cut 0 "$(find "$DUTY_DIR" -maxdepth 1 -name '.release-cut-*' | wc -l | tr -d ' ')"
OUT="$(GH_PRS="" SIM_PR_AFTER="94 dan-claude-bot release/site-2.1.46" RELEASE_QUIET_S=0 RELEASE_TRACKS="$SITE_TRACK" rel_run)"
t the-new-head-is-cut-next-tick 1 "$(grep -c "release: acme/site — cutting site-2.1.46 from ${HEAD3:0:7}" <<<"$OUT")"
t the-new-cut-is-remembered "94 release/site-2.1.46 $HEAD3" "$(cat "$DUTY_DIR/.release-cut-acme_site")"
# a withdrawal that fails holds the track rather than cutting twice
rel_reset
OUT="$(SIM_PR_AFTER="95 dan-claude-bot release/site-2.1.46" RELEASE_QUIET_S=0 RELEASE_TRACKS="$SITE_TRACK" rel_run)"
printf 'w\n' >"$ORIGIN/apps/site/w.txt"; gq add -A; gq commit -q -m "feat(site): w (#4)"
: >"$SESSION_LOG"
OUT="$(GH_CLOSE_RC=1 GH_PRS="95 dan-claude-bot release/site-2.1.46" GH_PR_STATE="OPEN " RELEASE_QUIET_S=0 RELEASE_TRACKS="$SITE_TRACK" rel_run)"
t a-failed-withdrawal-holds-the-track 1 "$(grep -c 'WARN: release: acme/site#95 is stale (main moved past' <<<"$OUT")"
t a-failed-withdrawal-buys-nothing 0 "$(sessions)"
t a-failed-withdrawal-keeps-the-memory 1 "$(find "$DUTY_DIR" -maxdepth 1 -name '.release-cut-*' | wc -l | tr -d ' ')"

# a session that opened nothing earns no ledger row: the head is cut again
rel_reset
OUT="$(SIM_PR_AFTER="" GH_PRS="" RELEASE_QUIET_S=0 RELEASE_TRACKS="$SITE_TRACK" rel_run)"
t a-session-without-a-pr-warns 1 "$(grep -c 'WARN: release: acme/site — the session ended without opening release/site-2.1.46; .* is cut again next tick' <<<"$OUT")"
t a-session-without-a-pr-earns-no-row 0 "$([ -f "$DUTY_DIR/.seen-release" ] && grep -c . "$DUTY_DIR/.seen-release" || echo 0)"
: >"$SESSION_LOG"
OUT="$(SIM_PR_AFTER="96 dan-claude-bot release/site-2.1.46" GH_PRS="" RELEASE_QUIET_S=0 RELEASE_TRACKS="$SITE_TRACK" rel_run)"
t the-uncut-head-is-cut-again 1 "$(sessions)"

# a candidate is tag-only: no fragment is needed
printf '2.2.0-rc1-dev\n' >"$ORIGIN/apps/site/VERSION"; gq add -A; gq commit -q -m "chore: open the 2.2.0 rc window"
rm -f "$ORIGIN/apps/site/changelog.d/2.md" "$ORIGIN/apps/site/changelog.d/3.md"; gq add -A; gq commit -q -m "chore: fragments consumed elsewhere"
printf 'q\n' >"$ORIGIN/apps/site/q.txt"; gq add -A; gq commit -q -m "feat(site): q (#5)"
rel_reset
OUT="$(SIM_PR_AFTER="97 dan-claude-bot release/site-2.2.0-rc1" GH_PRS="" RELEASE_QUIET_S=0 RELEASE_TRACKS="$SITE_TRACK" rel_run)"
t a-candidate-cuts-without-fragments 1 "$(grep -c 'release: acme/site — cutting site-2.2.0-rc1 from' <<<"$OUT")"
t a-candidate-prompt-says-tag-only 1 "$(grep -cF 'changelog.d are: none (a candidate is tag-only)' "$TMP/prompt" || true)"

# VERSION not armed: nothing to stamp
printf '2.2.0-rc1\n' >"$ORIGIN/apps/site/VERSION"; gq add -A; gq commit -q -m "release: site-2.2.0-rc1"
rel_reset
OUT="$(GH_PRS="" RELEASE_QUIET_S=0 RELEASE_TRACKS="$SITE_TRACK" rel_run)"
t an-unarmed-version-is-refused 1 "$(grep -c 'no release duty: acme/site site-@apps/site — VERSION on main is not armed (no -dev suffix); nothing to stamp' <<<"$OUT")"

# a track with no tag yet is the operator's first cut
printf '1.0.0-dev\n' >"$ORIGIN/apps/admin/VERSION"; gq add -A; gq commit -q -m "chore: arm admin"
rel_reset
OUT="$(GH_PRS="" RELEASE_QUIET_S=0 RELEASE_TRACKS="acme/site:apps/admin:admin-" rel_run)"
t a-track-without-a-tag-is-the-operators-first-cut 1 "$(grep -c 'no release duty: acme/site admin-@apps/admin — no release tag under the prefix yet; the first cut is the operator' <<<"$OUT")"

# ── the wiring, pinned ───────────────────────────────────────────────────────
DUTY_SH="$SHARED/bin/duty.sh"
t duty-sources-the-release-module-for-triage 1 "$(grep -c 'source "$DUTY_DIR/lib/duty-release.sh"' "$DUTY_SH")"
t duty-runs-the-cut-after-hygiene-and-before-the-reaper 1 "$(awk '/duty_hygiene && echo/{h=NR} /^  duty_release$/{r=NR} /source "\$DUTY_DIR\/lib\/duty-reaper.sh"/{p=NR} END{print (h && r && p && h<r && r<p) ? 1 : 0}' "$DUTY_SH")"
t duty-guards-the-cut-with-the-triage-role 1 "$(grep -B3 '^  duty_release$' "$DUTY_SH" | grep -c '^if has_role triage; then')"
TRIAGE_CONF="$SHARED/conf/roles/triage.conf"
t triage-conf-times-the-cut 1 "$(grep -c '^TIMEOUT_RELEASE=2400$' "$TRIAGE_CONF")"
t triage-conf-tiers-the-cut-at-the-top 1 "$(grep -c '^MODEL_RELEASE=$' "$TRIAGE_CONF")"
t triage-conf-budgets-the-cut "BUDGET_MINUTES_RELEASE=160 BUDGET_SESSIONS_RELEASE=4" "$(grep -E '^BUDGET_(SESSIONS|MINUTES)_RELEASE=' "$TRIAGE_CONF" | sort | paste -sd' ' -)"
DEFAULTS="$SHARED/conf/fleet.defaults.conf"
t defaults-ship-no-track 1 "$(grep -c '^RELEASE_TRACKS=""$' "$DEFAULTS")"
t defaults-quiet-window-matches-the-module 1 "$(grep -c "^RELEASE_QUIET_S=$RELEASE_QUIET_S_DEFAULT\$" "$DEFAULTS")"
t defaults-ceremony-repo-matches-the-module 1 "$(grep -c "^RELEASE_CEREMONY_REPO=\"$RELEASE_CEREMONY_REPO_DEFAULT\"\$" "$DEFAULTS")"
t defaults-name-the-release-label 1 "$(grep -c '^LABEL_RELEASE="release"$' "$DEFAULTS")"
t example-conf-shows-the-site-tracks-commented 1 "$(grep -c '^# RELEASE_TRACKS="heavy-duty/la-familia-site:apps/site:site- heavy-duty/la-familia-site:apps/admin:admin-:hold"$' "$ROOT/examples/fleet.conf")"
t example-conf-ships-no-live-track 0 "$(grep -c '^RELEASE_TRACKS=' "$ROOT/examples/fleet.conf" || true)"
t probe-ships-the-cuts-memory 1 "$(grep -c '"$DUTY_DIR"/.release-\*' "$ROOT/fleet-floor/server/probe.sh")"
t the-host-tick-joins-the-release-reasons 1 "$(grep -c 'reasons="$reasons$(wake_release_reasons "$name")"' "$ROOT/cli/crew")"
t the-suite-is-planned-for-the-module 1 "$(grep -c $'^shared/lib/duty-release.sh\trelease$' "$ROOT/.github/ci/suites.map")"
t the-suite-is-planned-for-the-prompts 1 "$(grep -c $'^shared/prompts/\\*\tbuilder,review,triage,hygiene,release$' "$ROOT/.github/ci/suites.map")"
t the-runbook-exists 1 "$([ -s "$SHARED/docs/release-cut.md" ] && echo 1 || echo 0)"
t the-runbook-walks-the-doors 1 "$(grep -c 'Llevar a GitHub' "$SHARED/docs/release-cut.md" 2>/dev/null || true)"
t the-worked-example-names-the-site 1 "$(grep -c '^## A worked example: heavy-duty/la-familia-site' "$ROOT/examples/README.md" 2>/dev/null || true)"
for real in apps/site/drills/README.md .github/labels.conf release-approve.yml build-images.yml apps/admin/lib/tickets.mjs; do
  t "the-worked-example-names-${real//[^a-zA-Z0-9]/-}" 1 "$(grep -cF -- "$real" "$ROOT/examples/README.md" 2>/dev/null | awk '{print ($1>0)?1:0}')"
done
t no-old-ceremony-pin-survives 0 "$(grep -rl '@0\.7\.7\b' "$ROOT" --exclude-dir=.git --exclude-dir=changelog.d --exclude=CHANGELOG.md 2>/dev/null | grep -vc '^$' || true)"

suite_finish
