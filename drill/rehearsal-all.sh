#!/usr/bin/env bash
# rehearsal-all.sh — run drill/rehearsal.sh once per role, one box each.
#
#   drill/rehearsal-all.sh [--agent <name>] [--tree <path>] [--remote <url>]
#     [--ref <git-ref>] [--roles "triage builder reviewer"] [--quick]
#     [--app-roster <path>]
#
# Three single-role boxes, not one multi-role box: fleet.roster deploys
# single-role members, and duty.sh gates every module on has_role. A box
# carrying all three would exercise a composite path nobody runs, and would
# hide exactly the class of defect that made a reviewer box quietly run
# triage sweeps for a whole rehearsal (heavy-duty/crew#28).
#
# The three boxes may share ONE gh identity. That is safe only because
# repos.txt is the scope for every module (heavy-duty/crew#7's doctrine
# change) and each box gets its own sandbox — disjoint registries, disjoint
# work. Under the previous org-wide review sweep all three would have seen
# each other's PRs and raced for the same verdicts.
#
# Each role runs to completion before the next starts, unless --parallel says
# otherwise (#776). Then the roles run at once, each into its own transcript
# with a [role] prefix on the console, and the summary is assembled after all
# of them end. The one cross-role read a shared identity makes — the attention
# census, which reads every demand the identity carries — grades suppression
# only for demands still standing after the tick, so another role resolving
# its own fixture mid-tick cannot red this one.
#
#   --legs a,b,…        run only these legs (the role sections always run)
#   --only-failed LOG   run only the legs LOG read FAIL or INCOMPLETE, and
#                       print the rest of LOG's leg states beside the result
#
# Both re-run the role sections on fresh boxes: a box an earlier --keep round
# left standing is refused before anything runs, with its teardown (#806).
set -uo pipefail
# #825: the round's own arguments and path, for the one restart provisioning
# may need (drill/provision.sh) once box setup-host has added the group.
ROUND_ARGS=("$@")
ROUND_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

ROLES="triage builder reviewer"
PASSTHRU=()
AGENT="claude"
# A green round tears itself down. Four boxes at 2 CPU / 4 GiB / 20 GiB, still
# armed and still ticking against their sandboxes, are what a rehearsal that
# passed leaves behind for no reason; a rehearsal that FAILED usually needs
# them, so a red round keeps them and says how to remove them (#217).
KEEP=0
# The fleet app is part of the rehearsal, not a separate errand: it is the
# thing an operator will be looking at when they decide whether the fleet is
# healthy, so a drill that proves the roles but never the console has only
# proved half of what gets trusted. Read-only by default — see
# drill/rehearsal-app.sh for why the control verbs are opt-in.
APP=1
APP_ARGS=()
APP_ROSTER=""
# #789: with no --app-roster, the round arms one of its own boxes, skews its
# clock and runs the armed pass against it (drill/rehearsal-armed-self.sh).
ARMED_SELF=1
# Operator-config convergence is a real-host rehearsal too. One installed box
# is enough to exercise the registry contract; running the destructive/restore
# cycle once per role adds risk without adding a distinct code path.
CONFIG_DRILL=1
CONFIG_BOX=""
CONFIG_ROLE=""
# The fleet-lifecycle leg (#656) — `crew restart/down/reset --all` over the
# round's own roster. It runs LAST of the independent phases, after the app
# passes and immediately before teardown, and the ordering is load-bearing
# rather than aesthetic: this is the only leg that STOPS boxes, snapshots them
# and rolls one back, so running it earlier would hand the app phase a fleet
# that is half down and turn a real comparison into the "NOT CREATED vs
# offline" non-comparison #494 exists to remove.
FLEET_DRILL=1
FLEET_STATUS=""
# The fleets-as-workspaces leg (#814) and the floor-built fleet leg (#815).
WORKSPACES_DRILL=1
PROVISION_DRILL=1
# crew as one service per machine (#822), under scratch names.
SERVICE_DRILL=1
# Section A's installer driver runs once, against the first role box this
# session actually reached. It acquires the same tree/ref as the role drills.
# That box is also the config phase's box, on purpose — and the two phases only
# survive sharing it because the installer drill hires it as the identity the
# role drill gave it. When Section A named its own role instead, the config
# phase re-roled the box back: the engine warns "ROLES CHANGED" and installs
# anyway, so the drill ran on duty loops nobody meant to swap (#180).
INSTALL_DRILL=1
INSTALL_TREE=""
INSTALL_REMOTE="${CREW_DRILL_REMOTE:-https://github.com/heavy-duty/crew.git}"
INSTALL_REF="${CREW_DRILL_REF:-main}"
RESOLVED_REF=""
# Where this round's findings go, derived below from the operator's own ref —
# not from RESOLVED_REF, which is a bare commit by construction and names no
# pull request. Empty means nothing was derivable and the summary says nothing
# about where to report rather than naming a PR this round never touched (#492).
REPORT_TARGET=""
RESUME_DRILL=1
ATTENTION_DRILL=1
# The board-audit leg is TRIAGE-role, unlike the two above it: the hygiene slot
# it belongs to is triage-only (duty.sh), so its aggregate row is gated on the
# triage role having run, never the builder's.
ATTENTION_AUDIT_DRILL=1
# The release-cut leg (#762) is TRIAGE-role for the same reason: the duty is
# triage-only (duty.sh), so its row is gated on the triage role having run.
RELEASE_DRILL=1
HYGIENE_DRILL=1
BREAKER_DRILL=1
# The notifier union leg runs inside every role's phase 2, so its verdict is
# the ROUND's, not one role's: a summary row that named a single role would
# hide a half the other two boxes also exercised.
NOTIFY_DRILL=1
# The leg writes its OWN verdict here, one line per role. It cannot travel on
# rehearsal.sh's exit code: rehearsal_notify_drill returns 0 both when the
# union is asserted and when the operator channel is unreachable and the leg
# skips, so reading the role's rc printed `ok notify` for a round that asserted
# nothing — and `FAIL notify` for a role that failed somewhere else entirely.
NOTIFY_STATUS=""
# The builder-only resume leg writes its own verdict here. Its role's exit
# code also covers every other builder assertion and cannot classify this leg.
RESUME_STATUS=""
ATTENTION_STATUS=""
ATTENTION_AUDIT_STATUS=""
RELEASE_STATUS=""
# Roles whose drill actually reached a box, for the app phase.
DRILLED=""
# #776: run the roles at once, select legs, re-run what a previous round left
# red. LEGS is the operator's selection, comma-separated; empty is every leg.
PARALLEL=0
LEGS=""
ONLY_FAILED=""
# #774: the pool entries the round logs its boxes in with — gh:<name>,agent:<name>.
CREDS=""
CREDS_BOX="" CREDS_ROUND_GH=""
# #776: the fast tier — plumbing only, never a promotion reading.
FAST=0

while [ $# -gt 0 ]; do
  case "$1" in
    --roles) ROLES="$2"; shift 2 ;;
    --agent) AGENT="$2"; PASSTHRU+=(--agent "$2"); shift 2 ;;
    --tree)
      INSTALL_TREE="$2"; PASSTHRU+=("$1" "$2"); shift 2 ;;
    --remote)
      INSTALL_REMOTE="$2"; shift 2 ;;
    --ref)
      INSTALL_REF="$2"; shift 2 ;;
    --quick) PASSTHRU+=(--quick); shift ;;
    --reuse) PASSTHRU+=(--reuse); shift ;;
    --keep) KEEP=1; shift ;;
    --no-app) APP=0; shift ;;
    --no-config-drill) CONFIG_DRILL=0; shift ;;
    --no-install-drill) INSTALL_DRILL=0; shift ;;
    --no-resume-drill) RESUME_DRILL=0; shift ;;
    --no-attention-drill) ATTENTION_DRILL=0; shift ;;
    --no-attention-audit-drill) ATTENTION_AUDIT_DRILL=0; shift ;;
    --no-release-drill) RELEASE_DRILL=0; shift ;;
    --no-hygiene-drill) HYGIENE_DRILL=0; shift ;;
    --no-breaker-drill) BREAKER_DRILL=0; shift ;;
    --no-notify-drill) NOTIFY_DRILL=0; shift ;;
    --no-fleet-drill) FLEET_DRILL=0; shift ;;
    --no-workspaces-drill) WORKSPACES_DRILL=0; shift ;;
    --no-floor-provision-drill) PROVISION_DRILL=0; shift ;;
    --no-service-drill) SERVICE_DRILL=0; shift ;;
    --app-boxes) APP_ARGS+=(--boxes "$2"); shift 2 ;;
    --app-allow-control) APP_ARGS+=(--allow-control); shift ;;
    --app-roster) APP_ROSTER="$2"; shift 2 ;;
    --no-app-armed-self) ARMED_SELF=0; shift ;;
    --app-shots) APP_ARGS+=(--shots "$2"); shift 2 ;;
    --parallel) PARALLEL=1; shift ;;
    --fast) FAST=1; shift ;;
    --creds) CREDS="$2"; shift 2 ;;
    --legs) LEGS="$2"; shift 2 ;;
    --only-failed) ONLY_FAILED="$2"; shift 2 ;;
    *) echo "usage: drill/rehearsal-all.sh [--agent <name>] [--roles \"triage builder reviewer\"] [--tree <path>] [--remote <url>] [--ref <git-ref>] [--quick]"
       echo "         [--reuse] [--keep] [--no-app] [--no-config-drill] [--no-install-drill] [--no-resume-drill] [--no-attention-drill] [--no-attention-audit-drill] [--no-release-drill] [--no-hygiene-drill] [--no-notify-drill] [--no-breaker-drill] [--no-fleet-drill] [--no-workspaces-drill] [--no-floor-provision-drill] [--no-service-drill] [--app-boxes \"a b\"] [--app-allow-control]"
       echo "         [--app-roster <path>] [--no-app-armed-self] [--app-shots <dir>] [--parallel] [--fast] [--legs a,b,...] [--only-failed <log>] [--creds gh:<name>[,gh:<name>],agent:<name>[,tg:<name>]]"; exit 1 ;;
  esac
done

# #825: the host brings nothing but sudo; the round installs what it needs —
# box at the drill's own pin, the host tools, the browser leg's — before
# anything below reads the host. A copy with no provision.sh beside it (a test
# harness) and DRILL_NO_PROVISION=1 skip it.
if [ -z "${DRILL_NO_PROVISION:-}" ] && [ -r "$(dirname "$ROUND_SELF")/provision.sh" ]; then
  # shellcheck source=drill/provision.sh
  . "$(dirname "$ROUND_SELF")/provision.sh"
  provision_round "$(cd "$(dirname "$ROUND_SELF")/.." && pwd)" "$ROUND_SELF" ${ROUND_ARGS[@]+"${ROUND_ARGS[@]}"}
  ROUND_BOX="$(platform_version_of "$(box --version 2>/dev/null </dev/null | head -1)")"
fi

# Validate operator input before source acquisition and the role round. The
# named pass runs last; discovering a typo there would otherwise waste the
# whole multi-role rehearsal before producing the same error.
[ -z "$APP_ROSTER" ] || [ -f "$APP_ROSTER" ] \
  || { echo "drill/rehearsal-all.sh: no app roster at '$APP_ROSTER'" >&2; exit 1; }

for role in $ROLES; do
  case "$role" in
    triage|builder|reviewer) ;;
    *) echo "unknown role '$role' (triage, builder or reviewer)"; exit 1 ;;
  esac
done

# --only-failed LOG: the legs a previous round's summary read FAIL or
# INCOMPLETE, from its generated `## leg …` block — the record, never a guess.
ONLY_FAILED_CARRIED=""
if [ -n "$ONLY_FAILED" ]; then
  [ -z "$LEGS" ] || { echo "drill/rehearsal-all.sh: --legs and --only-failed are exclusive" >&2; exit 1; }
  [ -r "$ONLY_FAILED" ] || { echo "drill/rehearsal-all.sh: no readable log at '$ONLY_FAILED'" >&2; exit 1; }
  LEGS="$(sed -nE 's/^## leg (executed|not-executed) ([a-z-]+)  \((FAIL|INCOMPLETE)\b.*/\2/p' "$ONLY_FAILED" \
    | grep -vx teardown | paste -sd, -)"
  ONLY_FAILED_CARRIED="$(sed -nE 's/^## leg (executed|not-executed) ([a-z-]+)  \(([a-zA-Z]+).*/\2 \3/p' "$ONLY_FAILED")"
  [ -n "$ONLY_FAILED_CARRIED" ] \
    || { echo "drill/rehearsal-all.sh: '$ONLY_FAILED' carries no '## leg …' block — not a round summary" >&2; exit 1; }
  if [ -z "$LEGS" ]; then
    echo "drill/rehearsal-all.sh: '$ONLY_FAILED' has no FAIL or INCOMPLETE leg — nothing to re-run"
    exit 0
  fi
  echo "== --only-failed: re-running $LEGS (read from $ONLY_FAILED)"
fi
# --legs a,b,…: every leg off, then the named ones back on. A name that is not a
# declared leg is refused before anything runs: a typo would otherwise run a
# round that skipped exactly the leg the operator asked for.
if [ -n "$LEGS" ]; then
  RESUME_DRILL=0 ATTENTION_DRILL=0 ATTENTION_AUDIT_DRILL=0 RELEASE_DRILL=0
  HYGIENE_DRILL=0 BREAKER_DRILL=0 NOTIFY_DRILL=0 INSTALL_DRILL=0
  CONFIG_DRILL=0 APP=0 FLEET_DRILL=0 WORKSPACES_DRILL=0 PROVISION_DRILL=0 SERVICE_DRILL=0 KEEP=1
  for leg in ${LEGS//,/ }; do
    case "$leg" in
      hygiene) HYGIENE_DRILL=1 ;;
      breaker) BREAKER_DRILL=1 ;;
      resume) RESUME_DRILL=1 ;;
      attention) ATTENTION_DRILL=1 ;;
      attention-audit) ATTENTION_AUDIT_DRILL=1 ;;
      release) RELEASE_DRILL=1 ;;
      notify) NOTIFY_DRILL=1 ;;
      installer) INSTALL_DRILL=1 ;;
      config) CONFIG_DRILL=1 ;;
      app|browser|app-armed) APP=1 ;;
      fleet) FLEET_DRILL=1 ;;
      workspaces) WORKSPACES_DRILL=1 ;;
      floor-provision) PROVISION_DRILL=1 ;;
      service) SERVICE_DRILL=1 ;;
      teardown) KEEP=0 ;;
      *) echo "drill/rehearsal-all.sh: --legs: '$leg' is not a declared leg" >&2; exit 1 ;;
    esac
  done
fi
# --creds: the drill's own pool (#828: ~/.config/crew-drill/credentials, or
# CREW_CREDENTIALS_DIR), every named entry checked to be there before any role
# starts (#774). What it lacks is asked for on the terminal (drill/creds.sh);
# without one, the round refuses and prints the command that fills it. The
# round never assigns an entry: the boxes are off every roster, so each role
# pushes the entries by name.
if [ -n "$CREDS" ]; then
  creds_seen=""
  for creds_entry in ${CREDS//,/ }; do
    [[ "$creds_entry" =~ ^(gh|agent|tg):[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] \
      || { echo "drill/rehearsal-all.sh: --creds: '$creds_entry' is not gh:<name>, agent:<name> or tg:<name>" >&2; exit 1; }
    # Two gh entries are two credentials the round uses by case (#835): the
    # first logs the boxes in, the other makes the round's own GitHub calls —
    # the sandboxes' owner, the side that opens what the box works on.
    case "$creds_entry:$creds_seen " in
      gh:*" gh "*)
        if [ -z "$CREDS_ROUND_GH" ]; then
          case ",$CREDS_BOX," in *",$creds_entry,"*)
            echo "drill/rehearsal-all.sh: --creds: $creds_entry is named twice" >&2; exit 1 ;; esac
          CREDS_ROUND_GH="${creds_entry#gh:}"; continue
        fi ;;
    esac
    case " $creds_seen " in *" ${creds_entry%%:*} "*)
      echo "drill/rehearsal-all.sh: --creds: two gh, one agent and one tg entry at most" >&2; exit 1 ;; esac
    creds_seen="$creds_seen ${creds_entry%%:*}"
    CREDS_BOX="${CREDS_BOX:+$CREDS_BOX,}$creds_entry"
  done
  CREDS_LIB="$(dirname "$ROUND_SELF")/creds.sh"
  if [ -r "$CREDS_LIB" ]; then
    # shellcheck source=drill/creds.sh
    . "$CREDS_LIB"
    CREW_CREDENTIALS_DIR="$(drill_creds_dir)"
    creds_missing="$(drill_creds_missing "$CREDS")"
    if [ -n "$creds_missing" ] && drill_creds_have_tty; then
      echo "== --creds: the drill's pool ($CREW_CREDENTIALS_DIR) lacks: $(paste -sd' ' <<<"$creds_missing") — asking"
      drill_creds_ensure "$(cd "$(dirname "$ROUND_SELF")/.." && pwd)/cli/crew" "$AGENT" "$CREDS" \
        || { echo "drill/rehearsal-all.sh: --creds: the pool is still missing entries — nothing ran" >&2; exit 1; }
    elif [ -n "$creds_missing" ]; then
      while IFS= read -r m; do
        [ "$m" = tg-chat ] || echo "drill/rehearsal-all.sh: --creds: no pool entry $m in $CREW_CREDENTIALS_DIR" >&2
      done <<<"$creds_missing"
      if [ "$(grep -cvx tg-chat <<<"$creds_missing")" -gt 0 ]; then
        echo "drill/rehearsal-all.sh: --creds: no terminal to ask on — add them once, on this host: $(drill_creds_hint "$AGENT" "$CREDS")" >&2
        exit 1
      fi
    fi
  fi
  if [ -z "${CREW_CREDENTIALS_DIR:-}" ] || [ ! -d "$CREW_CREDENTIALS_DIR/entries" ]; then
    echo "drill/rehearsal-all.sh: --creds: no credential pool found (drill/creds.sh fills the drill's own, or point CREW_CREDENTIALS_DIR at one)" >&2
    exit 1
  fi
  for creds_entry in ${CREDS//,/ }; do
    [ -r "$CREW_CREDENTIALS_DIR/entries/${creds_entry%%:*}--${creds_entry#*:}/secret" ] \
      || { echo "drill/rehearsal-all.sh: --creds: no pool entry $creds_entry in $CREW_CREDENTIALS_DIR" >&2; exit 1; }
    # A bot without the fleet's group chat reaches no box (#788): refused
    # here, before an hour of round, not at the push.
    if [ "${creds_entry%%:*}" = tg ] && [ ! -s "$CREW_CREDENTIALS_DIR/tg-chat" ]; then
      echo "drill/rehearsal-all.sh: --creds: $creds_entry needs the fleet's Telegram group chat — set it first: crew creds chat <chat-id> (or drill/creds.sh asks for it)" >&2; exit 1
    fi
  done
  export CREW_CREDENTIALS_DIR
  echo "== --creds: the round logs its boxes in from the pool ($CREDS_BOX, $CREW_CREDENTIALS_DIR); no box is logged in by hand"
  # The box and the round are two GitHub accounts (#835): the round owns the
  # sandboxes and opens what the box works on; the box forks, pushes and
  # reviews. GitHub refuses a review of one's own pull request, so one account
  # on both sides fails builder and reviewer twenty minutes in. With two gh
  # entries the round's calls use the second; with one, the host's own gh
  # login, if it has one. Both accounts are read here, before anything is
  # minted.
  creds_gh="$(tr ',' '\n' <<<"$CREDS_BOX" | sed -n 's/^gh://p' | head -1)"
  if [ -n "$CREDS_ROUND_GH" ]; then
    GH_TOKEN="$(cat "$CREW_CREDENTIALS_DIR/entries/gh--$CREDS_ROUND_GH/secret" 2>/dev/null)" || GH_TOKEN=""
    export GH_TOKEN
    round_from="gh:$CREDS_ROUND_GH"
  else
    round_from="this host's gh login"
  fi
  if [ -n "$creds_gh" ]; then
    round_login="$(gh api user --jq .login 2>/dev/null | tr -d '\r')" || round_login=""
    if [ -z "$round_login" ]; then
      if [ -n "$CREDS_ROUND_GH" ]; then
        echo "drill/rehearsal-all.sh: --creds: GitHub answered no account for gh:$CREDS_ROUND_GH — replace its token: crew creds add gh $CREDS_ROUND_GH" >&2
      else
        echo "drill/rehearsal-all.sh: --creds: the round's own GitHub calls need a second account, another from the box's gh:$creds_gh — add a second gh entry: --creds gh:$creds_gh,gh:<name>,… (asked for with the rest)" >&2
      fi
      exit 1
    fi
    box_login="$(GH_TOKEN="$(cat "$CREW_CREDENTIALS_DIR/entries/gh--$creds_gh/secret" 2>/dev/null)" gh api user --jq .login 2>/dev/null | tr -d '\r')" || box_login=""
    case " $ROLES " in
      *" builder "*|*" reviewer "*)
        if [ -n "$box_login" ] && [ "$box_login" = "$round_login" ]; then
          echo "drill/rehearsal-all.sh: --creds: the round's calls ($round_from) and the boxes (gh:$creds_gh) are both GitHub account '$round_login' — builder and reviewer need two (GitHub refuses a review of one's own pull request)" >&2
          exit 1
        fi ;;
    esac
    echo "== gh: the boxes log in as ${box_login:-unread} (gh:$creds_gh); the round's own calls are $round_login ($round_from)"
  fi
fi
# Every role section mints a fresh box and phase 0 refuses one that already
# exists (#116), so a box a `--keep` round left behind fails its role a minute
# in, as a FAIL that names the role rather than the box. --legs and
# --only-failed re-run the role sections too: the obvious follow-up to a kept
# round could never work, and the rc5 round read three role FAILs that way
# (#806). Said here, before anything runs, with the one command that clears
# them. --reuse is the operator's recorded exception and is passed through.
# An unreadable `box list` says nothing: phase 0 still decides per role.
case " ${PASSTHRU[*]-} " in
  *" --reuse "*) ;;
  *)
    existing_boxes="$(box list --json 2>/dev/null | jq -r '.[]?.name // empty' 2>/dev/null)" \
      || existing_boxes="" # Decision-path empty fallback: phase 0 still refuses per role
    standing_roles="" standing_boxes=""
    for role in $ROLES; do
      case $'\n'"$existing_boxes"$'\n' in
        *$'\n'"crew-drill-$role"$'\n'*)
          standing_roles="$standing_roles${standing_roles:+ }$role"
          standing_boxes="$standing_boxes${standing_boxes:+ }crew-drill-$role" ;;
      esac
    done
    # The floor-provision leg's own box (#815), when that leg is to run.
    standing_floor=""
    if [ "$PROVISION_DRILL" -eq 1 ]; then
      case $'\n'"$existing_boxes"$'\n' in
        *$'\n'"crew-drill-floor"$'\n'*)
          standing_floor=" --box crew-drill-floor"
          standing_boxes="$standing_boxes${standing_boxes:+ }crew-drill-floor" ;;
      esac
    fi
    if [ -n "$standing_roles$standing_floor" ]; then
      echo "drill/rehearsal-all.sh: drill boxes from an earlier round still exist: $standing_boxes" >&2
      echo "         every role section mints a fresh box and refuses an existing one (#116);" >&2
      echo "         --legs and --only-failed re-run the role sections too. Clear them first:" >&2
      echo "           drill/teardown.sh${standing_roles:+ --roles \"$standing_roles\"}$standing_floor --yes" >&2
      echo "         then re-run this command. Nothing has run." >&2
      exit 1
    fi
    ;;
esac
# --fast (#776): the roles in parallel; no app or browser pass; and the legs
# whose every reading is a real agent session's output — the release cut, the
# resume wake, the attention dispatch — left out by name. Inside each role the
# stub agent stands in, and the sections that read agent output say so.
if [ "$FAST" -eq 1 ]; then
  PARALLEL=1 APP=0 RELEASE_DRILL=0 RESUME_DRILL=0 ATTENTION_DRILL=0 PROVISION_DRILL=0 SERVICE_DRILL=0
  echo "== --fast: plumbing only — roles in parallel, a zero-action agent, no app pass; NOT a promotion reading"
fi
# omitted FLAG — the reason a leg that did not run gives: the operator's flag,
# the fast tier, or the selection that left it out.
omitted() {
  if [ -n "$LEGS" ]; then printf 'not selected by --legs'
  elif [ "$FAST" -eq 1 ]; then
    case "$1" in
      --no-app|--no-release-drill|--no-resume-drill|--no-attention-drill) printf -- '--fast: reads a real agent session'"'"'s output' ;;
      --no-floor-provision-drill|--no-service-drill) printf -- '--fast: mints a box of its own' ;;
      *) printf '%s' "$1" ;;
    esac
  else printf '%s' "$1"; fi
}

# Resolve the operator-facing branch, tag or commit once for the whole role
# round. Each role then fetches this exact object from the canonical remote;
# a branch moving after this point cannot split one record across three trees.
# GitHub permits a fork-network commit to be fetched by object ID from the
# canonical repository, so this also needs no fork URL (#490).
if [ -z "$INSTALL_TREE" ]; then
  command -v git >/dev/null \
    || { echo "phase 0: git not found on the host (source resolution needs it)" >&2; exit 1; }
  resolve_tmp="$(mktemp -d)"
  resolve_error="$resolve_tmp/fetch.err"
  git -C "$resolve_tmp" init -q
  if ! GIT_TERMINAL_PROMPT=0 git -C "$resolve_tmp" fetch --quiet --depth=1 \
      "$INSTALL_REMOTE" "$INSTALL_REF" 2>"$resolve_error"; then
    echo "phase 0: cannot resolve remote '$INSTALL_REMOTE' ref '$INSTALL_REF' to one commit: $(cat "$resolve_error")" >&2
    rm -rf -- "$resolve_tmp"
    exit 1
  fi
  RESOLVED_REF="$(git -C "$resolve_tmp" rev-parse --verify 'FETCH_HEAD^{commit}' 2>/dev/null)" \
    || { echo "phase 0: remote '$INSTALL_REMOTE' ref '$INSTALL_REF' did not resolve to a commit" >&2; rm -rf -- "$resolve_tmp"; exit 1; }
  rm -rf -- "$resolve_tmp"
  PASSTHRU+=(--remote "$INSTALL_REMOTE" --ref "$RESOLVED_REF")
  SOURCE_RECORD="remote $INSTALL_REMOTE ref $INSTALL_REF"
else
  INSTALL_TREE="$(cd "$INSTALL_TREE" 2>/dev/null && pwd)" \
    || { echo "phase 0: --tree '$INSTALL_TREE' is not a readable directory" >&2; exit 1; }
  RESOLVED_REF="$(git -C "$INSTALL_TREE" rev-parse --verify HEAD 2>/dev/null)" \
    || { echo "phase 0: --tree '$INSTALL_TREE' is not a resolved git tree" >&2; exit 1; }
  SOURCE_RECORD="tree $INSTALL_TREE"
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The one door into a box (#792): box_in enters as the agent on box 0.11.0 and
# later. A copy of this script with no shared/lib beside it (a test harness)
# keeps today's door.
if [ -r "$HERE/../shared/lib/box-entry.sh" ]; then
  # shellcheck disable=SC1091
  . "$HERE/../shared/lib/box-entry.sh"
else
  # shellcheck disable=SC2317  # reached only without shared/lib
  box_in() { local b="$1"; shift; box exec "$b" "$@"; }
fi
# shellcheck source=drill/rehearsal-report.sh
. "$HERE/rehearsal-report.sh"
# --tree drills a local checkout, so a --ref passed beside it is not what was
# drilled and derives nothing. Otherwise the role boxes get the target too:
# they are handed RESOLVED_REF and could not derive it for themselves, and a
# per-role footer disagreeing with the round's summary is worse than neither.
if [ -z "$INSTALL_TREE" ]; then
  REPORT_TARGET="$(rehearsal_report_target "$INSTALL_REMOTE" "$INSTALL_REF")" \
    || REPORT_TARGET=""
  [ -z "$REPORT_TARGET" ] || PASSTHRU+=(--source-ref "$INSTALL_REF")
fi
# shellcheck source=drill/rehearsal-hygiene.sh
. "$HERE/rehearsal-hygiene.sh"
# shellcheck source=drill/rehearsal-breaker.sh
. "$HERE/rehearsal-breaker.sh"
# Sourced for rehearsal_notify_worst_verdict alone — the fold belongs beside
# the leg that writes the lines, not retyped here where the two could drift.
# shellcheck source=drill/rehearsal-notify.sh
. "$HERE/rehearsal-notify.sh"
# Sourced for fleet_worst_verdict alone, on the same reasoning: the fold belongs
# beside the classifiers the leg writes its verdicts with, not retyped here
# where the two could drift.
# shellcheck source=drill/fleet-lifecycle.sh
. "$HERE/fleet-lifecycle.sh"
# shellcheck source=drill/rehearsal-armed-self.sh
. "$HERE/rehearsal-armed-self.sh"
NOTIFY_STATUS="$(mktemp)"
RESUME_STATUS="$(mktemp)"
ATTENTION_STATUS="$(mktemp)"
ATTENTION_AUDIT_STATUS="$(mktemp)"
RELEASE_STATUS="$(mktemp)"
APP_AGREEMENT_STATUS="$(mktemp)"
APP_OUTPUT="$(mktemp)"
FLEET_STATUS="$(mktemp)"
WORKSPACES_STATUS="$(mktemp)"
PROVISION_STATUS="$(mktemp)"
SERVICE_STATUS="$(mktemp)"
# One row per independently runnable leg. The final record is checked against
# this list before it is printed: adding a leg here without wiring a result is
# therefore a visible red row, never an absence that looks like coverage.
declare -a DECLARED_LEGS=(
  hygiene breaker resume attention attention-audit release notify
  installer config app browser app-armed fleet workspaces floor-provision service teardown
)

leg_is_declared() {
  local candidate="$1" declared_leg
  for declared_leg in "${DECLARED_LEGS[@]}"; do
    [ "$candidate" != "$declared_leg" ] || return 0
  done
  return 1
}

leg_is_selected_role() {
  case " $ROLES " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

declare -a SUMMARY=()
declare -a ROLE_HYGIENE_FILES=()
declare -a ROLE_BREAKER_FILES=()
declare -a ROLE_BREAKER_REASON_FILES=()
declare -a ROLE_SECTION_STATUS_FILES=()
overall=0
hygiene_result=2
breaker_result=2
breaker_reason=""
phase2_attempted=0

# shellcheck disable=SC2317  # invoked indirectly by the EXIT trap
cleanup_role_hygiene_files() {
  local result_file
  for result_file in "${ROLE_HYGIENE_FILES[@]}"; do
    rm -f -- "$result_file"
  done
  for result_file in "${ROLE_BREAKER_FILES[@]}"; do
    rm -f -- "$result_file"
  done
  for result_file in "${ROLE_BREAKER_REASON_FILES[@]}"; do
    rm -f -- "$result_file"
  done
  for result_file in "${ROLE_SECTION_STATUS_FILES[@]}"; do
    rm -f -- "$result_file"
  done
  # The notify leg's verdict file goes here too, and not under a second
  # `trap … EXIT`: bash keeps exactly ONE EXIT handler, so the later trap
  # silently REPLACES the earlier one and whichever leg lost the race leaks
  # its temp file every round. One handler, both legs' temporaries.
  [ -z "${NOTIFY_STATUS:-}" ] || rm -f -- "$NOTIFY_STATUS"
  [ -z "${RESUME_STATUS:-}" ] || rm -f -- "$RESUME_STATUS"
  [ -z "${ATTENTION_STATUS:-}" ] || rm -f -- "$ATTENTION_STATUS"
  [ -z "${ATTENTION_AUDIT_STATUS:-}" ] || rm -f -- "$ATTENTION_AUDIT_STATUS"
  [ -z "${RELEASE_STATUS:-}" ] || rm -f -- "$RELEASE_STATUS"
  [ -z "${APP_AGREEMENT_STATUS:-}" ] || rm -f -- "$APP_AGREEMENT_STATUS"
  [ -z "${APP_OUTPUT:-}" ] || rm -f -- "$APP_OUTPUT"
  [ -z "${FLEET_STATUS:-}" ] || rm -f -- "$FLEET_STATUS"
  [ -z "${WORKSPACES_STATUS:-}" ] || rm -f -- "$WORKSPACES_STATUS"
  [ -z "${PROVISION_STATUS:-}" ] || rm -f -- "$PROVISION_STATUS"
  [ -z "${SERVICE_STATUS:-}" ] || rm -f -- "$SERVICE_STATUS"
  # A round interrupted inside the self-armed pass (#789) must not leave its
  # box armed or skewed: the stage says what was changed, and only that is
  # undone. Here and not under a second trap, for the reason given above.
  if [ "${ARMED_SELF_STAGE:-0}" -gt 0 ] && [ -n "${ARMED_SELF_BOX:-}" ]; then
    armed_self_restore "$ARMED_SELF_BOX" >&2 || true
  fi
}
trap cleanup_role_hygiene_files EXIT

# host_token_scope_gap HEADERS SCOPE — the response headers of `gh api -i
# user`; prints a refusal reason when the host token's classic scopes are
# readable and do not include SCOPE, and nothing otherwise. A fine-grained
# token answers no X-OAuth-Scopes header at all, and then this says nothing:
# the leg's own write is the only judge of what such a token may do (#775).
host_token_scope_gap() {
  local scopes
  scopes="$(printf '%s\n' "$1" | tr -d '\r' | sed -n 's/^[Xx]-[Oo][Aa][Uu][Tt][Hh]-[Ss][Cc][Oo][Pp][Ee][Ss]:[[:space:]]*//p' | head -1)"
  [ -n "$scopes" ] || return 0
  case ", $scopes," in
    *", $2,"*) return 0 ;;
  esac
  printf 'host token lacks the %s scope (gh auth refresh -h github.com -s %s)\n' "$2" "$2"
}

# The release leg seeds `.github/workflows/release.yml` with the HOST's gh, and
# GitHub answers a workflow-file write from a token without `workflow` with a
# bare 404 that names nothing. The rc1 round's G3 went unread on exactly that.
# Read once, before any role: a missing scope is an omission the round
# DISCOVERED, so the leg reads INCOMPLETE with the remedy, never FAIL (#775).
REHEARSAL_RELEASE_REFUSED=""
HOST_TOKEN_HEADERS=""
if [ "$RELEASE_DRILL" -ne 0 ] && leg_is_selected_role triage; then
  HOST_TOKEN_HEADERS="$(gh api -i user 2>/dev/null | sed '/^\r\{0,1\}$/q' || true)"
  REHEARSAL_RELEASE_REFUSED="$(host_token_scope_gap "$HOST_TOKEN_HEADERS" workflow)"
  [ -z "$REHEARSAL_RELEASE_REFUSED" ] \
    || echo "preflight: the release leg will not run: $REHEARSAL_RELEASE_REFUSED"
fi
# Teardown deletes the sandboxes with the host's gh. Without `delete_repo` it
# cannot, and says so only at the very end of a multi-hour round; say it now.
if [ "$KEEP" -eq 0 ]; then
  [ -n "$HOST_TOKEN_HEADERS" ] || HOST_TOKEN_HEADERS="$(gh api -i user 2>/dev/null | sed '/^\r\{0,1\}$/q' || true)"
  teardown_gap="$(host_token_scope_gap "$HOST_TOKEN_HEADERS" delete_repo)"
  [ -z "$teardown_gap" ] \
    || echo "preflight: WARNING — a green round's teardown will not delete the sandboxes: $teardown_gap"
fi

# The browser leg's two needs (#789), said NOW rather than in the summary an
# hour later. The same probes rehearsal-app.sh runs before its walk: the module
# resolved from the checkout the page reader lives in (node looks beside the
# script, so it is resolved from ROOT, not the cwd), and a browser binary.
browser_preflight_gap() { # ROOT — prints what is missing, nothing when ready
  local root="$1" gap="" cand found="${PW_CHROME:-}"
  if ! command -v node >/dev/null 2>&1; then
    gap="node is not installed"
  elif ! (cd "$root" && node -e "require('playwright-core')") >/dev/null 2>&1; then
    gap="playwright-core is not installed in $root — (cd $root && npm i --no-save playwright-core)"
  fi
  if [ -z "$found" ]; then
    for cand in /usr/bin/google-chrome /usr/bin/google-chrome-stable \
                /opt/google/chrome/chrome /usr/bin/chromium-browser /usr/bin/chromium; do
      if [ -x "$cand" ]; then found="$cand"; break; fi
    done
  fi
  if [ -z "$found" ] || [ ! -x "$found" ]; then
    gap="${gap}${gap:+; }no Chrome/Chromium found — install one, or set PW_CHROME=/path/to/chrome"
  fi
  printf '%s' "$gap"
}
if [ "$APP" -eq 1 ]; then
  browser_gap="$(browser_preflight_gap "$(dirname "$HERE")")"
  [ -z "$browser_gap" ] \
    || echo "preflight: the browser leg will read INCOMPLETE: $browser_gap"
fi

# --- the role sections ---------------------------------------------------
# Three steps per role, so the same code runs them in sequence or at once
# (#776): prepare its result files, invoke its drill, collect its results. The
# collection always runs in role order, whatever order the roles ended in, so
# a parallel round's summary is built exactly as a sequential one's is.
declare -A ROLE_HYGIENE_FILE=() ROLE_BREAKER_FILE=() ROLE_BREAKER_REASON_FILE=()
declare -A ROLE_SECTION_FILE=() ROLE_RESULT_FILE=() ROLE_TRANSCRIPT=()
# "name seconds" per section, for the summary's wall-time block (#776).
declare -a TIMINGS=()
ROUND_START=$SECONDS

role_banner() {
  echo
  echo "############################################################"
  echo "## $1 — box crew-drill-$1"
  echo "############################################################"
}

role_prepare() {
  local role="$1"
  ROLE_HYGIENE_FILE[$role]="$(mktemp)"
  ROLE_BREAKER_FILE[$role]="$(mktemp)"
  ROLE_BREAKER_REASON_FILE[$role]="$(mktemp)"
  ROLE_SECTION_FILE[$role]="$(mktemp)"
  ROLE_HYGIENE_FILES+=("${ROLE_HYGIENE_FILE[$role]}")
  ROLE_BREAKER_FILES+=("${ROLE_BREAKER_FILE[$role]}")
  ROLE_BREAKER_REASON_FILES+=("${ROLE_BREAKER_REASON_FILE[$role]}")
  ROLE_SECTION_STATUS_FILES+=("${ROLE_SECTION_FILE[$role]}")
  printf '2\n' >"${ROLE_HYGIENE_FILE[$role]}"
  printf '2\n' >"${ROLE_BREAKER_FILE[$role]}"
  : >"${ROLE_SECTION_FILE[$role]}"
}

# role_siblings ROLE — the other roles of this round that tick WHILE this one
# does: every other role under --parallel, none when the roles run one after
# another (#783). Their boxes answer as the same login, so a demand of their
# sandbox that this role's census records can be picked up by them, legitimately,
# inside this role's tick — and a comment by that login cannot say which box
# wrote it.
role_siblings() {
  local r out=""
  [ "$PARALLEL" -eq 1 ] || return 0
  for r in $ROLES; do
    [ "$r" = "$1" ] || out="$out${out:+ }$r"
  done
  printf '%s' "$out"
}

role_invoke() {
  local role="$1"
  REHEARSAL_RESUME_DRILL="$RESUME_DRILL" \
  REHEARSAL_RESUME_STATUS="$RESUME_STATUS" \
  REHEARSAL_ATTENTION_DRILL="$ATTENTION_DRILL" \
  REHEARSAL_ATTENTION_STATUS="$ATTENTION_STATUS" \
  REHEARSAL_ATTENTION_AUDIT_DRILL="$ATTENTION_AUDIT_DRILL" \
  REHEARSAL_ATTENTION_AUDIT_STATUS="$ATTENTION_AUDIT_STATUS" \
  REHEARSAL_RELEASE_DRILL="$RELEASE_DRILL" \
  REHEARSAL_RELEASE_STATUS="$RELEASE_STATUS" \
  REHEARSAL_RELEASE_REFUSED="$REHEARSAL_RELEASE_REFUSED" \
  REHEARSAL_HYGIENE_DRILL="$HYGIENE_DRILL" \
  REHEARSAL_HYGIENE_RESULT_FILE="${ROLE_HYGIENE_FILE[$role]}" \
  REHEARSAL_BREAKER_DRILL="$BREAKER_DRILL" \
  REHEARSAL_BREAKER_RESULT_FILE="${ROLE_BREAKER_FILE[$role]}" \
  REHEARSAL_BREAKER_REASON_FILE="${ROLE_BREAKER_REASON_FILE[$role]}" \
  REHEARSAL_NOTIFY_DRILL="$NOTIFY_DRILL" \
  REHEARSAL_NOTIFY_STATUS="$NOTIFY_STATUS" \
  REHEARSAL_CREDS="$CREDS_BOX" \
  REHEARSAL_FAST="$FAST" \
  REHEARSAL_SIBLING_ROLES="$(role_siblings "$role")" \
  REHEARSAL_SECTION_STATUS="${ROLE_SECTION_FILE[$role]}" \
    "$HERE/rehearsal.sh" --role "$role" "${PASSTHRU[@]+"${PASSTHRU[@]}"}"
}

role_collect() {
  local role="$1" rc="$2"
  local role_hygiene_file="${ROLE_HYGIENE_FILE[$role]}"
  local role_breaker_file="${ROLE_BREAKER_FILE[$role]}"
  local role_breaker_reason_file="${ROLE_BREAKER_REASON_FILE[$role]}"
  local role_section_status_file="${ROLE_SECTION_FILE[$role]}"
  local role_section_status role_hygiene_result role_breaker_result role_breaker_reason
  role_section_status="$(cat "$role_section_status_file" 2>/dev/null || true)"
  [ "$role_section_status" != phase2 ] || phase2_attempted=1
  role_hygiene_result="$(cat "$role_hygiene_file" 2>/dev/null || printf '2\n')"
  role_breaker_result="$(cat "$role_breaker_file" 2>/dev/null || printf '2\n')"
  role_breaker_reason="$(cat "$role_breaker_reason_file" 2>/dev/null || true)"
  rm -f -- "$role_hygiene_file"
  rm -f -- "$role_breaker_file"
  rm -f -- "$role_breaker_reason_file"
  rm -f -- "$role_section_status_file"
  case "$role_hygiene_result" in 0|1|2) ;; *) role_hygiene_result=2 ;; esac
  hygiene_result="$(rehearsal_hygiene_combine_result \
    "$hygiene_result" "$role_hygiene_result")"
  case "$role_breaker_result" in 0|1|2) ;; *) role_breaker_result=2 ;; esac
  breaker_result="$(rehearsal_breaker_combine_result \
    "$breaker_result" "$role_breaker_result")"
  if [ -z "$breaker_reason" ] && [ -n "$role_breaker_reason" ]; then
    breaker_reason="$role_breaker_reason"
  fi
  # Roles whose box the drill actually REACHED, for the independent phases
  # below. A phase-2 failure is still an installed box; the explicit status
  # keeps it from being confused with an rc=1 before the box existed (#491).
  # Handing the app drill a box that is not there recreates, in miniature, the
  # "NOT CREATED vs offline" non-comparisons this wiring exists to remove — and
  # they would now count as real comparisons under #50's floor.
  case "$rc:$role_section_status" in
    0:*|2:*|*:installed|*:phase2)
      DRILLED="$DRILLED $role"
      if [ -z "$CONFIG_BOX" ]; then
        CONFIG_BOX="crew-drill-$role"
        CONFIG_ROLE="$role"
      fi
      ;;
  esac
  # 2 is "nothing failed, but phase 2 never ran". It is NOT a pass: the role
  # loop is unproven, and collapsing it into ok is how a rehearsal that
  # tested nothing gets reported as clearing the rollout.
  case "$rc" in
    0) SUMMARY+=("ok         $role  (phase 2 ran)") ;;
    2) SUMMARY+=("INCOMPLETE $role  (phase 2 skipped — loop UNPROVEN)")
       [ "$overall" -eq 1 ] || overall=2 ;;
    *)
      case "$role_section_status" in
        phase2) SUMMARY+=("FAIL       $role  (phase 2 failed)") ;;
        installed) SUMMARY+=("FAIL       $role  (failed after install, before phase 2)") ;;
        *) SUMMARY+=("FAIL       $role  (failed before an installed box existed)") ;;
      esac
      overall=1 ;;
  esac
}

if [ "$PARALLEL" -eq 1 ] && [ "$(wc -w <<<"$ROLES")" -gt 1 ]; then
  echo
  echo "== --parallel: running $ROLES at once (#776); each role's transcript is printed whole, in role order, once all of them end"
  for role in $ROLES; do
    role_prepare "$role"
    ROLE_RESULT_FILE[$role]="$(mktemp)"
    ROLE_TRANSCRIPT[$role]="$(mktemp)"
    ROLE_SECTION_STATUS_FILES+=("${ROLE_RESULT_FILE[$role]}" "${ROLE_TRANSCRIPT[$role]}")
    (
      role_start=$SECONDS
      role_invoke "$role" >"${ROLE_TRANSCRIPT[$role]}" 2>&1 </dev/null
      printf '%s %s\n' "$?" "$((SECONDS - role_start))" >"${ROLE_RESULT_FILE[$role]}"
    ) &
  done
  # A heartbeat, so a console with nothing on it for an hour still says what
  # it is waiting for.
  while :; do
    running=""
    for role in $ROLES; do
      [ -s "${ROLE_RESULT_FILE[$role]}" ] || running="$running $role"
    done
    [ -n "$running" ] || break
    sleep "${REHEARSAL_PARALLEL_HEARTBEAT_S:-60}"
    running_now=""
    for role in $ROLES; do
      [ -s "${ROLE_RESULT_FILE[$role]}" ] || running_now="$running_now $role"
    done
    [ -z "$running_now" ] || echo "== --parallel: still running:$running_now ($(( (SECONDS - ROUND_START) / 60 ))m)"
  done
  wait
  for role in $ROLES; do
    role_banner "$role"
    # shellcheck disable=SC2086  # ROLES is a word list by construction
    echo "## (ran in parallel with: $(printf '%s\n' $ROLES | grep -vx "$role" | paste -sd' ' -))"
    cat "${ROLE_TRANSCRIPT[$role]}"
    read -r rc role_seconds <"${ROLE_RESULT_FILE[$role]}"
    TIMINGS+=("$role ${role_seconds:-0}")
    role_collect "$role" "${rc:-1}"
  done
else
  for role in $ROLES; do
    role_banner "$role"
    role_prepare "$role"
    role_start=$SECONDS
    role_invoke "$role"
    rc=$?
    TIMINGS+=("$role $((SECONDS - role_start))")
    role_collect "$role" "$rc"
  done
fi

hygiene_incomplete_reason="phase 2 skipped"
[ "$phase2_attempted" -eq 0 ] \
  || hygiene_incomplete_reason="phase 2 ran without a hygiene result"
hygiene_row="$(rehearsal_hygiene_summary \
  "$HYGIENE_DRILL" "$DRILLED" "$hygiene_result" "$hygiene_incomplete_reason")"
breaker_row="$(rehearsal_breaker_summary \
  "$BREAKER_DRILL" "$DRILLED" "$breaker_result" "$breaker_reason")"
SUMMARY+=("${hygiene_row/(--no-hygiene-drill)/($(omitted --no-hygiene-drill))}")
SUMMARY+=("${breaker_row/(--no-breaker-drill)/($(omitted --no-breaker-drill))}")
overall="$(rehearsal_hygiene_round_result "$overall" "$hygiene_result")"
overall="$(rehearsal_breaker_round_result \
  "$overall" "$BREAKER_DRILL" "$breaker_result")"
if [ "$HYGIENE_DRILL" -ne 0 ] && [ -z "${DRILLED// /}" ]; then
  [ "$overall" -eq 1 ] || overall=2
fi

RESUME_VERDICT="$(rehearsal_worst_verdict "$(cat "$RESUME_STATUS" 2>/dev/null)")" \
  || RESUME_VERDICT=""
RESUME_WHY="${RESUME_VERDICT#* }"
RESUME_VERDICT="${RESUME_VERDICT%% *}"
if [ "$RESUME_DRILL" -eq 0 ]; then
  SUMMARY+=("skip       resume  ($(omitted --no-resume-drill))")
elif [[ " $ROLES " != *" builder "* ]]; then
  SUMMARY+=("INCOMPLETE resume  (builder role omitted)")
  [ "$overall" -eq 1 ] || overall=2
elif [ -z "$RESUME_VERDICT" ]; then
  SUMMARY+=("INCOMPLETE resume  (builder phase 2 never reached the leg)")
  [ "$overall" -eq 1 ] || overall=2
elif [ "$RESUME_VERDICT" = ok ]; then
  SUMMARY+=("ok         resume  (wake + zero-action stop)")
elif [ "$RESUME_VERDICT" = skip ]; then
  SUMMARY+=("INCOMPLETE resume  (leg skipped: $RESUME_WHY)")
  [ "$overall" -eq 1 ] || overall=2
else
  SUMMARY+=("FAIL       resume  ($RESUME_WHY)")
  overall=1
fi

ATTENTION_VERDICT="$(rehearsal_worst_verdict "$(cat "$ATTENTION_STATUS" 2>/dev/null)")" \
  || ATTENTION_VERDICT=""
ATTENTION_WHY="${ATTENTION_VERDICT#* }"
ATTENTION_VERDICT="${ATTENTION_VERDICT%% *}"
if [ "$ATTENTION_DRILL" -eq 0 ]; then
  SUMMARY+=("skip       attention  ($(omitted --no-attention-drill))")
elif [[ " $ROLES " != *" builder "* ]]; then
  SUMMARY+=("INCOMPLETE attention  (builder role omitted)")
  [ "$overall" -eq 1 ] || overall=2
elif [ -z "$ATTENTION_VERDICT" ]; then
  SUMMARY+=("INCOMPLETE attention  (builder phase 2 never reached the leg)")
  [ "$overall" -eq 1 ] || overall=2
elif [ "$ATTENTION_VERDICT" = ok ]; then
  SUMMARY+=("ok         attention  (dispatch without code + timeout report)")
elif [ "$ATTENTION_VERDICT" = skip ]; then
  SUMMARY+=("INCOMPLETE attention  (leg skipped: $ATTENTION_WHY)")
  [ "$overall" -eq 1 ] || overall=2
else
  SUMMARY+=("FAIL       attention  ($ATTENTION_WHY)")
  overall=1
fi

# The triage-role board-audit leg (#441). Same partition as every row above:
# `skip` is an omission the OPERATOR asked for, INCOMPLETE is one the round
# merely discovered, and a leg that never ran is never an `ok`.
ATTENTION_AUDIT_VERDICT="$(rehearsal_worst_verdict "$(cat "$ATTENTION_AUDIT_STATUS" 2>/dev/null)")" \
  || ATTENTION_AUDIT_VERDICT=""
ATTENTION_AUDIT_WHY="${ATTENTION_AUDIT_VERDICT#* }"
ATTENTION_AUDIT_VERDICT="${ATTENTION_AUDIT_VERDICT%% *}"
if [ "$ATTENTION_AUDIT_DRILL" -eq 0 ]; then
  SUMMARY+=("skip       attention-audit  ($(omitted --no-attention-audit-drill))")
elif [[ " $ROLES " != *" triage "* ]]; then
  SUMMARY+=("INCOMPLETE attention-audit  (triage role omitted)")
  [ "$overall" -eq 1 ] || overall=2
elif [ -z "$ATTENTION_AUDIT_VERDICT" ]; then
  SUMMARY+=("INCOMPLETE attention-audit  (triage phase 2 never reached the leg)")
  [ "$overall" -eq 1 ] || overall=2
elif [ "$ATTENTION_AUDIT_VERDICT" = ok ]; then
  SUMMARY+=("ok         attention-audit  (both shapes reported, not repaired, alerts on transition)")
elif [ "$ATTENTION_AUDIT_VERDICT" = skip ]; then
  SUMMARY+=("INCOMPLETE attention-audit  (leg skipped: $ATTENTION_AUDIT_WHY)")
  [ "$overall" -eq 1 ] || overall=2
else
  SUMMARY+=("FAIL       attention-audit  ($ATTENTION_AUDIT_WHY)")
  overall=1
fi

# The triage-role release-cut leg (#762), on the same partition.
RELEASE_VERDICT="$(rehearsal_worst_verdict "$(cat "$RELEASE_STATUS" 2>/dev/null)")" \
  || RELEASE_VERDICT=""
RELEASE_WHY="${RELEASE_VERDICT#* }"
RELEASE_VERDICT="${RELEASE_VERDICT%% *}"
if [ "$RELEASE_DRILL" -eq 0 ]; then
  SUMMARY+=("skip       release  ($(omitted --no-release-drill))")
elif [[ " $ROLES " != *" triage "* ]]; then
  SUMMARY+=("INCOMPLETE release  (triage role omitted)")
  [ "$overall" -eq 1 ] || overall=2
elif [ -z "$RELEASE_VERDICT" ]; then
  SUMMARY+=("INCOMPLETE release  (triage phase 2 never reached the leg)")
  [ "$overall" -eq 1 ] || overall=2
elif [ "$RELEASE_VERDICT" = ok ]; then
  SUMMARY+=("ok         release  (one cut per tick on a fresh track, held by its open PR, refused when closed)")
elif [ "$RELEASE_VERDICT" = skip ]; then
  SUMMARY+=("INCOMPLETE release  (leg skipped: $RELEASE_WHY)")
  [ "$overall" -eq 1 ] || overall=2
else
  SUMMARY+=("FAIL       release  ($RELEASE_WHY)")
  overall=1
fi

# The leg's own verdict, folded across the roles that wrote one — never the
# role's exit code, which says nothing about this leg either way.
NOTIFY_VERDICT="$(rehearsal_notify_worst_verdict "$(cat "$NOTIFY_STATUS" 2>/dev/null)")" \
  || NOTIFY_VERDICT=""
NOTIFY_WHY="${NOTIFY_VERDICT#* }"
NOTIFY_VERDICT="${NOTIFY_VERDICT%% *}"
if [ "$NOTIFY_DRILL" -eq 0 ]; then
  # An omission the OPERATOR asked for is a skip; one the round merely
  # discovered is INCOMPLETE. That is this file's own partition — `skip` rows
  # are `--no-*-drill` flags and nothing else — and the distinction is the
  # whole point: the operator who knows their host has no channel says so and
  # gets a clean round, and nobody else gets one by accident.
  SUMMARY+=("skip       notify  ($(omitted --no-notify-drill))")
elif [ -z "$NOTIFY_VERDICT" ]; then
  if [ -z "${DRILLED// /}" ]; then
    SUMMARY+=("INCOMPLETE notify  (no role reached a box — union UNPROVEN)")
  else
    SUMMARY+=("INCOMPLETE notify  (phase 2 never reached the leg — union UNPROVEN)")
  fi
  [ "$overall" -eq 1 ] || overall=2
elif [ "$NOTIFY_VERDICT" = ok ]; then
  SUMMARY+=("ok         notify  (repos.txt + notify-repos.txt union)")
elif [ "$NOTIFY_VERDICT" = skip ]; then
  # Reached only where the leg skipped for a reason nobody asked for — the
  # operator channel. It is NOT a pass: the union was never asserted, and a
  # round that reported one anyway is the invisible regression #423 exists to
  # end, the same shape as the INCOMPLETE role rows above.
  SUMMARY+=("INCOMPLETE notify  (leg skipped: $NOTIFY_WHY — union UNPROVEN)")
  [ "$overall" -eq 1 ] || overall=2
else
  SUMMARY+=("FAIL       notify  ($NOTIFY_WHY)")
  overall=1
fi

section_start=$SECONDS
if [ "$INSTALL_DRILL" -eq 1 ]; then
  echo
  echo "############################################################"
  echo "## Section A — versioned install and distribution"
  echo "############################################################"
  if [ -z "$CONFIG_BOX" ]; then
    echo "## (installer phase: no role reached a box this run — nothing safe to inspect)"
    SUMMARY+=("SKIPPED    installer  (blocked by role install: no installed drill box)")
    [ "$overall" -eq 1 ] || overall=2
  else
    INSTALL_ARGS=(--box "$CONFIG_BOX")
    if [ -n "$INSTALL_TREE" ]; then
      INSTALL_ARGS+=(--tree "$INSTALL_TREE")
    else
      INSTALL_ARGS+=(--remote "$INSTALL_REMOTE" --ref "$RESOLVED_REF")
    fi
    "$HERE/install-drill.sh" "${INSTALL_ARGS[@]}"
    rc=$?
    # shellcheck disable=SC2016  # expanded by bash inside the box
    return_state="$(box_in "$CONFIG_BOX" -- bash -lc \
      'command -v crontab >/dev/null 2>&1 || exit 2
       tmp=$(mktemp) || exit 2
       error=$(mktemp) || { rm -f -- "$tmp"; exit 2; }
       if LC_ALL=C crontab -l >"$tmp" 2>"$error"; then
         if grep -F "/duty/bin/tick.sh" "$tmp" >/dev/null; then
           printf "armed\\n"
         else
           printf "disarmed\\n"
         fi
       else
         read_rc=$?
         [ "$read_rc" -eq 1 ] && grep -q "^no crontab for " "$error" ||
           { rm -f -- "$tmp" "$error"; exit "$read_rc"; }
         printf "absent\\n"
       fi
       rm -f -- "$tmp" "$error"' </dev/null)" || return_state=unreadable
    case "$return_state" in
      disarmed|absent)
        echo "- PASS: Section A returned \`$CONFIG_BOX\` disarmed" ;;
      armed)
        echo "- FAIL: Section A returned \`$CONFIG_BOX\` armed"
        rc=1 ;;
      *)
        echo "- FAIL: Section A returned \`$CONFIG_BOX\` with crontab state unreadable"
        rc=1 ;;
    esac
    case "$rc" in
      0) SUMMARY+=("ok         installer  (Section A record emitted)") ;;
      *) SUMMARY+=("FAIL       installer"); overall=1 ;;
    esac
  fi
else
  SUMMARY+=("skip       installer  ($(omitted --no-install-drill))")
fi
[ "$INSTALL_DRILL" -eq 0 ] || TIMINGS+=("installer $((SECONDS - section_start))")
section_start=$SECONDS

if [ "$CONFIG_DRILL" -eq 1 ]; then
  echo
  echo "############################################################"
  echo "## operator config — registry convergence on a real box"
  echo "############################################################"
  if [ -z "$CONFIG_BOX" ]; then
    echo "## (config phase: no role reached a box this run — nothing safe to mutate)"
    SUMMARY+=("SKIPPED    config  (blocked by role install: no installed drill box)")
    [ "$overall" -eq 1 ] || overall=2
  else
    "$HERE/rehearsal-config.sh" --box "$CONFIG_BOX" --agent "$AGENT" --role "$CONFIG_ROLE"
    rc=$?
    case "$rc" in
      0) SUMMARY+=("ok         config  (operator mode + registry contract)") ;;
      *) SUMMARY+=("FAIL       config"); overall=1 ;;
    esac
  fi
else
  SUMMARY+=("skip       config  ($(omitted --no-config-drill))")
fi
[ "$CONFIG_DRILL" -eq 0 ] || TIMINGS+=("config $((SECONDS - section_start))")
section_start=$SECONDS

APP_ROW_EMITTED=0
GENERATED_APP=0
if [ "$APP" -eq 1 ]; then
  echo
  echo "############################################################"
  echo "## fleet app — crew floor against this host's boxes"
  echo "############################################################"
  # Point the app drill at the boxes THIS run just drilled, unless the operator
  # named a roster. Without this it fell through to fleet.roster, which on a
  # drill host names the real fleet's members — boxes that do not exist here —
  # so every comparison was "NOT CREATED vs offline": three assertions that
  # agree about nothing being there.
  #
  # --agent goes WITH the roles, and that pairing is the whole point. The agent
  # column selects the vendor profile both the floor and `crew status` probe
  # with, so generating the roles correctly while defaulting the agent to
  # `claude` mislabels every non-default rehearsal — and both readers then share
  # the one wrong file, so their agreement still passes. A generated fact is
  # only safer than a hand-written one if ALL of it is generated from something
  # true; the role came from the drill, the agent silently did not.
  if [ -n "${DRILLED// /}" ]; then
    APP_ARGS+=(--drill-roles "${DRILLED# }" --agent "$AGENT")
    GENERATED_APP=1
  else
    echo "## (generated app pass: no role reached a box this run — no generated member to compare)"
    SUMMARY+=("SKIPPED    app  (generated pass blocked by role install: no installed drill box)")
    SUMMARY+=("SKIPPED    browser  (generated pass blocked by role install: no installed drill box)")
    APP_ROW_EMITTED=1
    [ "$overall" -eq 1 ] || overall=2
  fi
  # Say what was left out rather than quietly narrowing: a shorter roster that
  # nobody announced reads as full coverage.
  if [ "$APP" -eq 1 ] && [ -n "${DRILLED// /}" ] && [ "${DRILLED# }" != "$ROLES" ]; then
    echo "## (app phase covers ${DRILLED# } — roles whose drill never reached a box are excluded)"
  fi
fi

if [ "$APP" -eq 0 ] && [ "$APP_ROW_EMITTED" -eq 0 ]; then
  SUMMARY+=("skip       app  ($(omitted --no-app))")
  SUMMARY+=("skip       browser  ($(omitted --no-app))")
  APP_ROW_EMITTED=1
fi

if [ "$APP" -eq 1 ] && [ "$GENERATED_APP" -eq 1 ]; then
  : >"$APP_AGREEMENT_STATUS"
  REHEARSAL_AGREEMENT_STATUS="$APP_AGREEMENT_STATUS" \
    "$HERE/rehearsal-app.sh" ${APP_ARGS[@]+"${APP_ARGS[@]}"} \
      | tee "$APP_OUTPUT"
  # PIPESTATUS belongs on its own line for the same reason the role rc does:
  # the app command's verdict, not tee's, is the round fact (#30).
  rc="${PIPESTATUS[0]}"
  app_agreement="$(cat "$APP_AGREEMENT_STATUS" 2>/dev/null || true)"
  case "$rc" in
    0)
      case "$app_agreement:$APP_ROSTER$([ "$ARMED_SELF" -eq 0 ] || echo self)" in
        compared:*) SUMMARY+=("ok         app  (agreement compared; collector + page)") ;;
        could-not-compare:?*) SUMMARY+=("ok         app  (agreement could-not-compare; armed comparison follows)") ;;
        could-not-compare:)
          SUMMARY+=("INCOMPLETE app  (agreement could-not-compare: no armed, ticking, clock-skewed box)")
          [ "$overall" -eq 1 ] || overall=2 ;;
        *) SUMMARY+=("FAIL       app  (agreement verdict missing)"); overall=1 ;;
      esac ;;
    *) SUMMARY+=("FAIL       app"); overall=1 ;;
  esac
  APP_ROW_EMITTED=1

  if grep -q '^ok   browser walk against the real fleet (read-only)$' "$APP_OUTPUT"; then
    SUMMARY+=("ok         browser  (read-only browser walk executed)")
  elif browser_skip="$(sed -n 's/^skip browser walk[[:space:]]*—[[:space:]]*//p' "$APP_OUTPUT" | head -1)" \
      && [ -n "$browser_skip" ]; then
    SUMMARY+=("INCOMPLETE browser  (not executed: $browser_skip)")
    [ "$overall" -eq 1 ] || overall=2
  elif grep -q '^FAIL browser walk' "$APP_OUTPUT"; then
    SUMMARY+=("FAIL       browser  (browser walk executed and failed)")
    overall=1
  else
    SUMMARY+=("INCOMPLETE browser  (app phase emitted no browser verdict)")
    [ "$overall" -eq 1 ] || overall=2
  fi
fi

# A named roster is an additional reading after the drill-role pass, never a
# replacement for it. It also remains readable when no role reached a generated
# drill member: that failure is recorded above and must not silently suppress
# independent evidence from an already-armed member (#494).
if [ "$APP" -eq 1 ] && [ -n "$APP_ROSTER" ]; then
  echo
  echo "############################################################"
  echo "## fleet app — armed roster comparison"
  echo "############################################################"
  # Comparison-only: repeating browser or control flags would spend a second
  # walk and could mutate the armed member this pass exists only to read.
  : >"$APP_AGREEMENT_STATUS"
  REHEARSAL_AGREEMENT_STATUS="$APP_AGREEMENT_STATUS" \
    "$HERE/rehearsal-app.sh" --roster "$APP_ROSTER" --no-browser
  rc=$?
  app_agreement="$(cat "$APP_AGREEMENT_STATUS" 2>/dev/null || true)"
  case "$rc" in
    0)
      case "$app_agreement" in
        compared) SUMMARY+=("ok         app-armed  (agreement compared; named roster, no additional boxes)") ;;
        could-not-compare)
          SUMMARY+=("INCOMPLETE app-armed  (agreement could-not-compare: no armed, ticking, clock-skewed box)")
          [ "$overall" -eq 1 ] || overall=2 ;;
        *) SUMMARY+=("FAIL       app-armed  (agreement verdict missing)"); overall=1 ;;
      esac ;;
    *) SUMMARY+=("FAIL       app-armed"); overall=1 ;;
  esac
elif [ "$APP" -eq 1 ] && [ "$ARMED_SELF" -eq 1 ] && [ "$GENERATED_APP" -eq 1 ]; then
  # #789, option 1: the round's OWN box, armed, ticked and clock-skewed for
  # this one pass, and put back after it whatever the pass said.
  ARMED_SELF_BOX="crew-drill-${DRILLED# }"; ARMED_SELF_BOX="${ARMED_SELF_BOX%% *}"
  ARMED_SELF_ROLE="${ARMED_SELF_BOX#crew-drill-}"
  echo
  echo "############################################################"
  echo "## fleet app — armed comparison on the round's own box ($ARMED_SELF_BOX)"
  echo "############################################################"
  # In THIS shell, not `$(…)`: the stage it reaches is what the restore undoes.
  if armed_self_prepare "$ARMED_SELF_BOX"; then
    echo "== $ARMED_SELF_WHY"
    : >"$APP_AGREEMENT_STATUS"
    # --drill-roles, not --roster (#838): the generated pass serves a fleet
    # definition of its own (#800). A bare --roster fell back to the drill
    # host's own config, which a fresh drill host does not have.
    REHEARSAL_AGREEMENT_STATUS="$APP_AGREEMENT_STATUS" \
      "$HERE/rehearsal-app.sh" --drill-roles "$ARMED_SELF_ROLE" --agent "$AGENT" --no-browser
    rc=$?
    app_agreement="$(cat "$APP_AGREEMENT_STATUS" 2>/dev/null || true)"
  else
    echo "== the round could not present an armed, skewed box: $ARMED_SELF_WHY"
    rc=0; app_agreement=not-presented
  fi
  armed_self_back="$(armed_self_restore "$ARMED_SELF_BOX")"; armed_self_back_rc=$?
  echo "== $armed_self_back"
  if [ "$armed_self_back_rc" -ne 0 ]; then
    # A box left armed or skewed is a box the rest of the round (and the
    # operator) reads wrong: that outranks whatever the pass said.
    SUMMARY+=("FAIL       app-armed  (the round's own box was not restored: ${armed_self_back#* NOT fully restored: })"); overall=1
  else
    case "$rc:$app_agreement" in
      0:compared) SUMMARY+=("ok         app-armed  (agreement compared; the round's own box, armed and skewed ${ARMED_SELF_SKEW_S}s for the pass, then restored)") ;;
      0:could-not-compare)
        SUMMARY+=("INCOMPLETE app-armed  (agreement could-not-compare on the round's own armed, skewed box)")
        [ "$overall" -eq 1 ] || overall=2 ;;
      0:not-presented)
        SUMMARY+=("INCOMPLETE app-armed  (not presented: $ARMED_SELF_WHY)")
        [ "$overall" -eq 1 ] || overall=2 ;;
      0:*) SUMMARY+=("FAIL       app-armed  (agreement verdict missing)"); overall=1 ;;
      *) SUMMARY+=("FAIL       app-armed"); overall=1 ;;
    esac
  fi
elif [ "$APP" -eq 1 ] && [ "$ARMED_SELF" -eq 0 ]; then
  SUMMARY+=("skip       app-armed  (not requested: --no-app-armed-self and no --app-roster)")
elif [ "$APP" -eq 1 ]; then
  SUMMARY+=("SKIPPED    app-armed  (no drill box reached: nothing to arm)")
else
  SUMMARY+=("skip       app-armed  ($(omitted --no-app))")
fi

[ "$APP" -eq 0 ] || TIMINGS+=("app $((SECONDS - section_start))")
section_start=$SECONDS
# The fleet-lifecycle leg (#656). LAST of the independent phases, immediately
# before teardown: it is the only one that stops boxes, cuts snapshots and rolls
# one back, so anything downstream of it would be reading a fleet this leg had
# moved. It returns the boxes standing — teardown removes them, and a red round
# leaves them for the operator to inspect the way every other leg does.
#
# The leg's row is its OWN verdict and never this script's rc, for the reason
# the notify row is: the three verbs return one number for a whole roster, so an
# rc can say "something was skipped busy" and never which box, and a leg that
# skipped every busy-box reading because the round drilled one box is not a
# pass. Same partition as every row above it — `skip` is an omission the
# OPERATOR asked for, INCOMPLETE is one the round merely discovered.
if [ "$FLEET_DRILL" -eq 1 ]; then
  echo
  echo "############################################################"
  echo "## fleet lifecycle — restart/down/reset --all over this round's roster"
  echo "############################################################"
  if [ -z "${DRILLED// /}" ]; then
    echo "## (fleet phase: no role reached a box this run — no roster to drive the verbs over)"
    SUMMARY+=("SKIPPED    fleet  (blocked by role install: no installed drill box)")
    [ "$overall" -eq 1 ] || overall=2
  else
    FLEET_BOXES=""
    for drilled_role in $DRILLED; do
      FLEET_BOXES="$FLEET_BOXES crew-drill-$drilled_role"
    done
    : >"$FLEET_STATUS"
    REHEARSAL_FLEET_STATUS="$FLEET_STATUS" \
      "$HERE/rehearsal-fleet.sh" --boxes "${FLEET_BOXES# }" --agent "$AGENT" \
        --roles "${DRILLED# }"
    rc=$?
    FLEET_VERDICT="$(fleet_worst_verdict "$(cat "$FLEET_STATUS" 2>/dev/null)")" \
      || FLEET_VERDICT=""
    FLEET_WHY="${FLEET_VERDICT#* }"
    FLEET_VERDICT="${FLEET_VERDICT%% *}"
    # The rc is read FIRST and only here: a leg that fell over is a FAILURE,
    # and a leg that ran and discovered a blocker is INCOMPLETE. Asking the
    # verdict channel first would collapse the first into the second — a script
    # that died before writing anything looks exactly like one that reached no
    # case — and a round would then report a crashed leg as merely unproven.
    # This is the ONLY thing the rc is consulted for; every per-box reading
    # inside the leg comes out of the verbs' output.
    if [ "$rc" -ne 0 ] || [ "$FLEET_VERDICT" = FAIL ]; then
      SUMMARY+=("FAIL       fleet  (${FLEET_WHY:-the leg exited $rc})")
      overall=1
    elif [ -z "$FLEET_VERDICT" ]; then
      SUMMARY+=("INCOMPLETE fleet  (the leg reached no case — per-box outcomes UNPROVEN)")
      [ "$overall" -eq 1 ] || overall=2
    elif [ "$FLEET_VERDICT" = skip ]; then
      # A reading the round could not take — a one-box roster has no busy-skip
      # to exercise, and a round where nothing was refused cannot answer #652's
      # composition question either way. Not a pass: the mechanism is exactly
      # what this leg exists to prove, and reporting one it never took is the
      # invisible regression the INCOMPLETE partition exists for.
      SUMMARY+=("INCOMPLETE fleet  (leg skipped a reading: $FLEET_WHY)")
      [ "$overall" -eq 1 ] || overall=2
    else
      SUMMARY+=("ok         fleet  (per-box outcomes on restart/down/cut + restore and canary-first upgrade)")
    fi
  fi
else
  SUMMARY+=("skip       fleet  ($(omitted --no-fleet-drill))")
fi
[ "$FLEET_DRILL" -eq 0 ] || TIMINGS+=("fleet $((SECONDS - section_start))")

# The workspaces (#814) and floor-provision (#815) legs: one floor in front of
# two fleets, and a fleet built from the floor's buttons. AFTER the fleet leg,
# which moves the round's boxes, and before teardown. Both run from one script
# under its own XDG and host state, so nothing of the operator's is read; each
# leg's row is its own folded verdict, read the way the fleet row is.
section_start=$SECONDS
workspaces_row() { # LEG STATUS-FILE RC OK-DETAIL
  local verdict why
  verdict="$(fleet_worst_verdict "$(cat "$2" 2>/dev/null)")" || verdict="" # Decision-path empty fallback: the leg reached no case
  why="${verdict#* }"; verdict="${verdict%% *}"
  if [ "$3" -ne 0 ] || [ "$verdict" = FAIL ]; then
    SUMMARY+=("FAIL       $1  (${why:-the leg exited $3})"); overall=1
  elif [ -z "$verdict" ]; then
    SUMMARY+=("INCOMPLETE $1  (the leg reached no case)"); [ "$overall" -eq 1 ] || overall=2
  elif [ "$verdict" = skip ]; then
    SUMMARY+=("INCOMPLETE $1  (leg skipped a reading: $why)"); [ "$overall" -eq 1 ] || overall=2
  else
    SUMMARY+=("ok         $1  ($4)")
  fi
}
WS_LEGS=""
[ "$WORKSPACES_DRILL" -eq 0 ] || WS_LEGS="workspaces"
[ "$PROVISION_DRILL" -eq 0 ] || WS_LEGS="$WS_LEGS${WS_LEGS:+ }floor-provision"
if [ -n "$WS_LEGS" ] && [ -z "${DRILLED// /}" ]; then
  [ "$WORKSPACES_DRILL" -eq 0 ] || SUMMARY+=("SKIPPED    workspaces  (blocked by role install: no installed drill box)")
  [ "$PROVISION_DRILL" -eq 0 ] || SUMMARY+=("SKIPPED    floor-provision  (blocked by role install: no installed drill box)")
  [ "$overall" -eq 1 ] || overall=2
elif [ -n "$WS_LEGS" ]; then
  echo
  echo "############################################################"
  echo "## fleets on one floor — workspaces and a floor-built fleet"
  echo "############################################################"
  WS_BOXES=""
  for drilled_role in $DRILLED; do WS_BOXES="$WS_BOXES crew-drill-$drilled_role"; done
  : >"$WORKSPACES_STATUS"; : >"$PROVISION_STATUS"
  REHEARSAL_WORKSPACES_STATUS="$WORKSPACES_STATUS" REHEARSAL_PROVISION_STATUS="$PROVISION_STATUS" \
  REHEARSAL_KEEP="$KEEP" REHEARSAL_CREDS="$CREDS_BOX" \
    "$HERE/rehearsal-workspaces.sh" --boxes "${WS_BOXES# }" --agent "$AGENT" --legs "$WS_LEGS"
  rc=$?
  [ "$WORKSPACES_DRILL" -eq 0 ] || workspaces_row workspaces "$WORKSPACES_STATUS" "$rc" \
    "two fleets on one floor: pages, actions and roster saves stay in their fleet; the host cap counts both"
  [ "$PROVISION_DRILL" -eq 0 ] || workspaces_row floor-provision "$PROVISION_STATUS" "$rc" \
    "a fleet made, a member created, hired and logged in from the floor, one job at a time"
  TIMINGS+=("workspaces $((SECONDS - section_start))")
fi
[ "$WORKSPACES_DRILL" -eq 1 ] || SUMMARY+=("skip       workspaces  ($(omitted --no-workspaces-drill))")
[ "$PROVISION_DRILL" -eq 1 ] || SUMMARY+=("skip       floor-provision  ($(omitted --no-floor-provision-drill))")

# The service leg (#822): one service per machine, stood up under scratch names
# (account crew-drill-svc, /etc and /var/lib crew-drill-svc), read end to end and
# purged. It needs passwordless sudo and box 0.11.0; without them its readings
# are skips and the row is INCOMPLETE. Like every independent leg, it runs only
# once a role reached a box: a round that installed nothing acts on nothing.
if [ "$SERVICE_DRILL" -eq 1 ] && [ -z "${DRILLED// /}" ]; then
  SUMMARY+=("SKIPPED    service  (blocked by role install: no installed drill box)")
  [ "$overall" -eq 1 ] || overall=2
elif [ "$SERVICE_DRILL" -eq 1 ]; then
  echo
  echo "############################################################"
  echo "## crew as a service — one per machine, under scratch names"
  echo "############################################################"
  section_start=$SECONDS
  : >"$SERVICE_STATUS"
  REHEARSAL_SERVICE_STATUS="$SERVICE_STATUS" "$HERE/rehearsal-service.sh" "$AGENT"
  rc=$?
  workspaces_row service "$SERVICE_STATUS" "$rc" \
    "the service set up, read and purged: its account, grant, floor, a box in its project, its tick"
  TIMINGS+=("service $((SECONDS - section_start))")
else
  SUMMARY+=("skip       service  ($(omitted --no-service-drill))")
fi

# Validate the declaration/result agreement before teardown decides whether a
# green round may remove its fixtures. Teardown's own row does not exist yet,
# but its declaration must; every other independently runnable leg must have
# exactly one result, and every non-role result must name a declared leg.
for declared_leg in "${DECLARED_LEGS[@]}"; do
  [ "$declared_leg" = teardown ] && continue
  leg_result_count=0
  for summary_row in "${SUMMARY[@]}"; do
    read -r _state row_leg _detail <<<"$summary_row"
    [ "$row_leg" != "$declared_leg" ] || leg_result_count=$((leg_result_count + 1))
  done
  [ "$leg_result_count" -eq 1 ] || overall=1
done
leg_is_declared teardown || overall=1
for summary_row in "${SUMMARY[@]}"; do
  read -r _state row_leg _detail <<<"$summary_row"
  leg_is_declared "$row_leg" || leg_is_selected_role "$row_leg" || overall=1
done

# Teardown is decided by the WHOLE round's verdict, so it runs after every
# phase and before the summary — and it gets its own summary line, because a
# cleanup that failed must not hide under a green drill.
#
# overall=2 is INCOMPLETE, not a pass: phase 2 never ran, and that is exactly
# the round whose boxes an operator needs standing to find out why. So it
# keeps them, like a failure does.
TEARDOWN_HINT="drill/teardown.sh --roles \"$ROLES\""
# The floor-provision leg's own box (#815) is the one the role list cannot
# name. The leg removes it unless the round keeps its boxes, or the removal
# failed; either way, if it still stands, the line the operator copies clears
# it too, so the next round is not refused for it (#806, #818).
if [ "$PROVISION_DRILL" -eq 1 ]; then
  floor_boxes="$(box list --json 2>/dev/null | jq -r '.[]?.name // empty' 2>/dev/null)" \
    || floor_boxes="" # Decision-path empty fallback: the next round's up-front check still names it
  case $'\n'"$floor_boxes"$'\n' in
    *$'\n'"crew-drill-floor"$'\n'*) TEARDOWN_HINT="$TEARDOWN_HINT --box crew-drill-floor" ;;
  esac
fi
if [ "$KEEP" -eq 1 ] && [ -n "$LEGS" ]; then
  SUMMARY+=("keep       teardown  (not selected by --legs: boxes and sandbox repos RETAINED)")
elif [ "$KEEP" -eq 1 ]; then
  SUMMARY+=("keep       teardown  (--keep: boxes and sandbox repos RETAINED)")
elif [ "$overall" -ne 0 ]; then
  SUMMARY+=("kept       teardown  (round not green — boxes LEFT STANDING to inspect)")
else
  echo
  echo "############################################################"
  echo "## teardown — a green round removes what it created"
  echo "############################################################"
  # --yes because this ran unattended behind three role drills; the operator
  # asked for the round, and a prompt at the end of a two-hour rehearsal is a
  # prompt nobody is sitting in front of. --keep is how they say no.
  section_start=$SECONDS
  "$HERE/teardown.sh" --roles "$ROLES" --yes
  rc=$?
  TIMINGS+=("teardown $((SECONDS - section_start))")
  # 2 is teardown's INCOMPLETE: a class it was asked to clear could not be
  # inspected at all, so `ok teardown (boxes and sandbox repos removed)` would
  # be a claim nobody measured. It gets its own row rather than collapsing
  # into FAIL, because nothing went wrong with the cleanup — the host simply
  # could not be read, and the operator needs to know which of the two it is.
  case "$rc" in
    0) SUMMARY+=("ok         teardown  (boxes and sandbox repos removed)") ;;
    2) SUMMARY+=("INCOMPLETE teardown  (part of the round could NOT be inspected — it may still stand)")
       overall=1 ;;
    *) SUMMARY+=("FAIL       teardown  (the round PASSED — this is cleanup, not the drill)")
       overall=1 ;;
  esac
fi

echo
echo "############################################################"
echo "## fleet rehearsal summary ($AGENT)"
# Said first, so a summary pasted from the tail can never be read as a round
# that counts: a fast round proves plumbing and promotes nothing (#776).
[ "$FAST" -eq 0 ] || echo "## TIER: fast — plumbing only; NOT a promotion reading (drills/README.md: cite the full round, never this one)"
if [ -n "$RESOLVED_REF" ]; then
  echo "## drilled source: $RESOLVED_REF ($SOURCE_RECORD)"
fi
[ -z "${ROUND_BOX:-}" ] || echo "## drill host: box $ROUND_BOX (the drill's pin: ${DRILL_BOX_REF:-unset})"
# The door this round used into every box (#792): the record says which box
# the host ran and whether crew entered as the agent with `--user` (box 0.11.0
# and later) or as the box's stamped user (before it).
if declare -F box_entry_mode >/dev/null; then
  round_box="$(box --version 2>/dev/null | head -1)" || round_box="" # Decision-path empty fallback: named unknown below
  round_entry="$(box_entry_mode 2>/dev/null)" || round_entry="" # Decision-path empty fallback: named unknown below
  echo "## box: ${round_box:-unknown} — entry mode ${round_entry:-unknown} (#792)"
fi

# The inventory is the round's declaration-to-result agreement block. It is
# generated from SUMMARY rather than maintained beside it, so the detailed
# verdict and the executed/not-executed reading cannot disagree. A missing or
# duplicate result is itself recorded and reds the round.
declare -a LEG_RECORD=()
for declared_leg in "${DECLARED_LEGS[@]}"; do
  declare -a leg_rows=()
  for summary_row in "${SUMMARY[@]}"; do
    read -r _state row_leg _detail <<<"$summary_row"
    [ "$row_leg" != "$declared_leg" ] || leg_rows+=("$summary_row")
  done
  if [ "${#leg_rows[@]}" -ne 1 ]; then
    LEG_RECORD+=("not-executed $declared_leg  (recorded ${#leg_rows[@]} results; expected exactly one)")
    overall=1
    continue
  fi
  read -r leg_state _leg_name leg_detail <<<"${leg_rows[0]}"
  case "${leg_rows[0]}" in
    ok\ *|FAIL\ *)
      if [ -z "$leg_detail" ] || [ "$leg_detail" = "()" ]; then
        LEG_RECORD+=("executed $declared_leg  ($leg_state)")
      else
        LEG_RECORD+=("executed $declared_leg  ($leg_state; ${leg_detail#(}")
      fi
      ;;
    *)
      if [ -z "$leg_detail" ] || [ "$leg_detail" = "()" ]; then
        LEG_RECORD+=("not-executed $declared_leg  (missing blocker reason)")
        overall=1
      else
        LEG_RECORD+=("not-executed $declared_leg  ($leg_state; ${leg_detail#(}")
      fi
      ;;
  esac
done
for summary_row in "${SUMMARY[@]}"; do
  read -r _state row_leg _detail <<<"$summary_row"
  if ! leg_is_declared "$row_leg" && ! leg_is_selected_role "$row_leg"; then
    LEG_RECORD+=("undeclared $row_leg  (summary result has no declaration)")
    overall=1
  fi
done

echo "## declared leg states:"
printf '## leg %s\n' "${LEG_RECORD[@]}"
summary_passed=0
summary_failed=0
summary_skipped=0
for summary_row in "${SUMMARY[@]}"; do
  case "$summary_row" in
    ok\ *) summary_passed=$((summary_passed + 1)) ;;
    FAIL\ *) summary_failed=$((summary_failed + 1)) ;;
    skip\ *|SKIPPED\ *|INCOMPLETE\ *|keep\ *|kept\ *)
      summary_skipped=$((summary_skipped + 1)) ;;
  esac
done
echo "## section states: $summary_passed passed, $summary_failed failed, $summary_skipped skipped/not-run"
printf '##   %s\n' "${SUMMARY[@]}"
# Where the round's time went (#776): one line per section that ran, and the
# whole. The waits inside a section print their own times on their rows.
fmt_duration() { printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); }
timing_line=""
for timing in ${TIMINGS[@]+"${TIMINGS[@]}"}; do
  timing_line="$timing_line${timing_line:+ · }${timing%% *} $(fmt_duration "${timing##* }")"
done
parallel_note=""
[ "$PARALLEL" -eq 0 ] || parallel_note=" (roles in parallel)"
echo "## wall time: ${timing_line:+$timing_line · }total $(fmt_duration $((SECONDS - ROUND_START)))$parallel_note"
if [ -n "$ONLY_FAILED_CARRIED" ]; then
  # A selective re-run is never mistaken for a whole round (#776): every leg
  # this run did not re-run is listed with the state the earlier log read.
  echo "## re-run of $ONLY_FAILED: only $LEGS re-ran; every other leg's reading is that log's:"
  while read -r carried_leg carried_state; do
    case ",$LEGS," in *",$carried_leg,"*) continue ;; esac
    echo "##   carried  $carried_leg  ($carried_state in $ONLY_FAILED)"
  done <<<"$ONLY_FAILED_CARRIED"
elif [ -n "$LEGS" ]; then
  echo "## selective run (--legs $LEGS): the legs not selected were not read by this run"
fi
echo "############################################################"
if [ "$KEEP" -eq 1 ] || [ "$overall" -ne 0 ]; then
  # "remain" rather than "were kept": this line also covers a teardown that
  # ran and failed, where some of the round is gone and the rest is not. What
  # exactly survived is named above, by the teardown's own FAIL lines.
  echo "## drill boxes and sandbox repositories remain on this host."
  echo "## When you are done with them:  $TEARDOWN_HINT"
fi
if [ "$overall" -eq 2 ]; then
  # The footer names what read INCOMPLETE (#805), from the summary itself.
  incomplete_rows=""
  for summary_row in "${SUMMARY[@]}"; do
    case "$summary_row" in
      INCOMPLETE\ *)
        read -r _state row_leg _detail <<<"$summary_row"
        incomplete_rows="$incomplete_rows${incomplete_rows:+ }$row_leg" ;;
    esac
  done
  rehearsal_report_footer round-incomplete "$REPORT_TARGET" "$incomplete_rows"
fi
exit "$overall"
