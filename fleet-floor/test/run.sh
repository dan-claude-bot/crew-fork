#!/usr/bin/env bash
# fleet-floor/test/run.sh — test the collector and the page with no fleet.
#
#   fleet-floor/test/run.sh [--no-browser]                 every part, one after another
#   fleet-floor/test/run.sh [--no-browser] --part <name>   one part (a,b for several)
#   fleet-floor/test/run.sh [--no-browser] --changed <ref> the parts a diff against <ref> needs
#   fleet-floor/test/run.sh --print-parts [--changed <ref> | --paths-from <file|->]
#
# The suite is four PARTS (#902), each its own process with its own scratch
# dir, stub state, operator config and collectors, so no part reads another's
# leftovers and CI runs them side by side:
#
#   collector  the Python suites, floor/*.sh (but workspaces.sh) and boxside.sh
#   cli        cli.sh: `crew floor` itself
#   page       the walk-count ledger, the browser walk, DEMO and motion
#   page-live  workspaces.sh (its two walks), then stale, churn, transition,
#              stopped and hired, each on a collector of its own
#
# test/parts.map says which parts a changed path needs; a path it does not
# name runs every part, so a missing row costs time, never coverage. Each part
# prints its wall time, and a run of several prints them side by side.
#
# A stub `box` CLI (test/stub-box) stands in for Incus, driven by
# test/fixtures/fleet.txt, so every box state the floor must render — running,
# stopped, unreachable, wedged, cron-silent, paused, freshly hired with no
# sessions, unauthenticated, and a box whose log is hostile or corrupt — is
# reachable here instead of only on a real host. The drill covers the other
# half (drill/rehearsal-app.sh: the same assertions against real boxes).
#
# The browser half needs playwright-core; it is SKIPPED, loudly, when absent,
# because a silently-skipped UI test reads exactly like a passing one.
# The source-path directive below makes each `source "$HERE/floor/<m>.sh"`
# resolve, so shellcheck can see that the helpers defined here ARE called
# from the module suites and stops reporting every one as unreachable.
# A line must never OPEN with the word after a `#` being `shellcheck`: that
# parses as a directive and reds the whole file (SC1073).
# shellcheck source-path=SCRIPTDIR
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOOR="$(dirname "$HERE")"

PARTS_ALL=(collector cli page page-live)
PARTS_MAP="${FLOOR_TEST_PARTS_MAP:-$HERE/parts.map}"

usage() { sed -n '4,7p' "$HERE/run.sh" | sed 's/^# \{0,1\}//'; }
die2() { echo "run.sh: $*" >&2; exit 2; }

BROWSER=1
PART="" CHANGED="" PATHS_FROM="" PRINT_PARTS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-browser) BROWSER=0 ;;
    --part) [ -n "${2:-}" ] || die2 "--part needs a name (${PARTS_ALL[*]})"; PART="${PART:+$PART,}$2"; shift ;;
    --part=*) PART="${PART:+$PART,}${1#--part=}" ;;
    --changed) [ -n "${2:-}" ] || die2 "--changed needs a git ref"; CHANGED="$2"; shift ;;
    --changed=*) CHANGED="${1#--changed=}" ;;
    --paths-from) [ -n "${2:-}" ] || die2 "--paths-from needs a file or -"; PATHS_FROM="$2"; shift ;;
    --print-parts) PRINT_PARTS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die2 "unknown argument: $1" ;;
  esac
  shift
done
[ -n "$PART" ] && [ -n "$CHANGED$PATHS_FROM" ] && die2 "--part and --changed/--paths-from choose the parts two ways; pass one"
[ -n "$CHANGED" ] && [ -n "$PATHS_FROM" ] && die2 "--changed and --paths-from both name the paths; pass one"

is_part() { local p; for p in "${PARTS_ALL[@]}"; do [ "$p" = "$1" ] && return 0; done; return 1; }

# parts_for <path> — the parts one repository-relative path needs, one per
# line, read from parts.map: <pattern><TAB><parts>, the FIRST matching rule
# decides, `all` and `none` mean what they say, and no matching rule is `all`.
# A part name the map misspells stops the run rather than dropping a part.
parts_for() {
  local path="$1" pattern parts p
  while IFS=$'\t' read -r pattern parts; do
    [ -n "$pattern" ] || continue
    case "$pattern" in '#'*) continue ;; esac
    # shellcheck disable=SC2053  # the rule's text IS a pattern; matching it as one is the point
    [[ "$path" == $pattern ]] || continue
    case "$parts" in
      all) printf '%s\n' "${PARTS_ALL[@]}" ;;
      none) ;;
      *) for p in ${parts//,/ }; do
           is_part "$p" || die2 "parts.map: '$pattern' names no part '$p' (${PARTS_ALL[*]})"
           echo "$p"
         done ;;
    esac
    return 0
  done <"$PARTS_MAP"
  printf '%s\n' "${PARTS_ALL[@]}"
}

# select_parts — read paths on stdin, print the parts they need in the suite's
# own order. No paths at all is doubt, and doubt runs everything.
select_parts() {
  local path any=0 p want=""
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    any=1
    want="$want $(parts_for "$path" | tr '\n' ' ')" || exit 2
  done
  [ "$any" -eq 1 ] || { printf '%s\n' "${PARTS_ALL[@]}"; return 0; }
  for p in "${PARTS_ALL[@]}"; do
    case " $want " in *" $p "*) echo "$p" ;; esac
  done
}

# changed_paths <ref> — every path that differs between the merge base of
# <ref> and HEAD and the working tree, untracked files included, so a run
# before a commit sees what it is about to commit.
changed_paths() {
  local root base
  root="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null)" || return 1
  base="$(git -C "$root" merge-base "$1" HEAD 2>/dev/null)" || return 1
  git -C "$root" diff --name-only "$base" -- || return 1
  git -C "$root" ls-files --others --exclude-standard
}

fmt_wall() { printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); }

# ---- more than one part: run each as its own process ----------------------
# A part is a separate `run.sh --part X`, not a function in this shell, so the
# one thing that made the old single script leak — a sourced file re-exporting
# FLOOR_STATE, a collector the previous block left polling — cannot reach the
# next part by construction.
if [ -z "$PART" ] || [ "$PART" != "${PART%%,*}" ] || [ "$PRINT_PARTS" -eq 1 ]; then
  if [ -n "$PART" ]; then
    SELECTED=()
    for _p in ${PART//,/ }; do is_part "$_p" || die2 "no part '$_p' (${PARTS_ALL[*]})"; SELECTED+=("$_p"); done
  elif [ -n "$CHANGED$PATHS_FROM" ]; then
    if [ -n "$CHANGED" ]; then
      if ! _paths="$(changed_paths "$CHANGED")"; then
        echo "run.sh: could not diff against '$CHANGED'; running every part" >&2
        _paths=""
      fi
    elif [ "$PATHS_FROM" = - ]; then _paths="$(cat)"
    else [ -r "$PATHS_FROM" ] || die2 "cannot read $PATHS_FROM"; _paths="$(cat "$PATHS_FROM")"; fi
    # A misspelled map row fails the selection, and the run with it, rather
    # than running a selection the map never meant.
    _sel="$(select_parts <<<"$_paths")" || exit 2
    SELECTED=()
    [ -z "$_sel" ] || mapfile -t SELECTED <<<"$_sel"
  else
    SELECTED=("${PARTS_ALL[@]}")
  fi
  if [ "$PRINT_PARTS" -eq 1 ]; then
    [ "${#SELECTED[@]}" -eq 0 ] || printf '%s\n' "${SELECTED[@]}"
    exit 0
  fi
  if [ "${#SELECTED[@]}" -eq 0 ]; then
    echo "== no part covers the changed paths (every one is a 'none' row in parts.map)"
    echo
    echo "== summary: 0 ok, 0 skipped, 0 failed"
    exit 0
  fi
  echo "== parts: ${SELECTED[*]}"
  RUN_LOGS="$(mktemp -d)"
  trap 'rm -rf "$RUN_LOGS"' EXIT
  T_PASS=0 T_SKIP=0 T_FAIL=0
  declare -a T_ROWS=() T_FAILS=()
  _child_args=()
  [ "$BROWSER" -eq 0 ] && _child_args+=(--no-browser)
  for _p in "${SELECTED[@]}"; do
    echo
    echo "######## part: $_p"
    _start=$SECONDS
    "$HERE/run.sh" "${_child_args[@]}" --part "$_p" 2>&1 | tee "$RUN_LOGS/$_p.log"
    _rc="${PIPESTATUS[0]}"
    _wall=$((SECONDS - _start))
    _sum="$(sed -n 's/^== summary: \([0-9]*\) ok, \([0-9]*\) skipped, \([0-9]*\) failed$/\1 \2 \3/p' "$RUN_LOGS/$_p.log" | tail -1)"
    if [ -z "$_sum" ]; then
      # A part that died before its summary (a collector that never came up)
      # asserted an unknown amount; it is a failure, named, never a zero.
      _sum="0 0 1"
      T_FAILS+=("[$_p] the part exited $_rc before its summary line")
    else
      while IFS= read -r _f; do T_FAILS+=("[$_p] $_f"); done \
        < <(sed -n 's/^  failed: //p' "$RUN_LOGS/$_p.log")
      # A summary that reports no failure over a non-zero exit is still red.
      if [ "$_rc" -ne 0 ] && [ "${_sum##* }" = 0 ]; then
        _sum="${_sum% *} 1"; T_FAILS+=("[$_p] the part exited $_rc with no failure in its summary")
      fi
    fi
    read -r _ok _sk _fl <<<"$_sum"
    T_PASS=$((T_PASS + _ok)) T_SKIP=$((T_SKIP + _sk)) T_FAIL=$((T_FAIL + _fl))
    T_ROWS+=("$(printf '  %-10s %5d ok %3d skipped %3d failed   %s' "$_p" "$_ok" "$_sk" "$_fl" "$(fmt_wall "$_wall")")")
  done
  echo
  echo "== parts, with wall time"
  printf '%s\n' "${T_ROWS[@]}"
  echo
  echo "== summary: $T_PASS ok, $T_SKIP skipped, $T_FAIL failed"
  if [ "$T_FAIL" -gt 0 ]; then
    printf '  failed: %s\n' "${T_FAILS[@]}"
    exit 1
  fi
  exit 0
fi
is_part "$PART" || die2 "no part '$PART' (${PARTS_ALL[*]})"
PART_START=$SECONDS

PASS=0 SKIP=0
declare -a FAILS=()
ok()   { echo "ok   $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1${2:+  — $2}"; FAILS+=("$1"); }
skip() { echo "skip $1${2:+  — $2}"; SKIP=$((SKIP + 1)); }
# t NAME EXPECTED ACTUAL — the fixture-test idiom from shared/test/run.sh
t() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected [$2] got [$3]"; fi; }

command -v python3 >/dev/null || { echo "python3 required"; exit 1; }

# A busy port surfaced as a python traceback from deep inside socketserver,
# which reads like the collector is broken rather than like another copy of
# this suite is already running. Say so plainly, and name the way out.
port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && { exec 3<&- 3>&-; return 0; }; return 1; }
# Every port this suite binds is its band, FLOOR_TEST_PORT+0 to +25, and every
# part uses the same band, because the parts of one run go one after another
# (CI gives each part a runner of its own). The collector part: the main
# collector at +0, store.sh's at +4, roster.sh's editor at +5. The page part:
# the main collector at +0. The page-live part: the collector-death one at +1,
# churn's at +2, #204's empty floor at +3, transition's at +6, stopped's at +9
# and workspaces.sh's at +7 and +8. The cli part: cli.sh's at +5..+25. A
# second run overlaps that band only from a base within 25 of this one, so
# +-25 is probed up front, by each part: a busy port discovered four minutes
# in reads as a broken collector, and a band shared with a live run reads as
# a collector answering the wrong suite (#767).
_base="${FLOOR_TEST_PORT:-8791}"
for _p in $(seq $((_base - 25)) $((_base + 25))); do
  if port_busy "$_p"; then
    echo "port $_p is already in use — another run of this suite is probably still going," >&2
    echo "  and this suite's ports are FLOOR_TEST_PORT+0..25, so a base within 25 of it meets it." >&2
    echo "  re-run with a different base:  FLOOR_TEST_PORT=$((_base + 200)) $0 --part $PART" >&2
    exit 1
  fi
done
unset _base _p   # no later file may build a port on them (#767 round 6)

TMP="$(mktemp -d)"
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG DUTY_DIR
export XDG_CONFIG_HOME="$TMP/xdg-empty"
mkdir -p "$XDG_CONFIG_HOME"
PORT="${FLOOR_TEST_PORT:-8791}"
USER=operator
PASSWD="test-$$"

# Resolve the ping fixture knobs once. The collector and any suite that imports
# its effective production constants must describe the same running server.
FLOOR_TEST_PING_INTERVAL="${FLOOR_TEST_PING_INTERVAL:-2}"
FLOOR_TEST_PING_TIMEOUT="${FLOOR_TEST_PING_TIMEOUT:-4}"
FLOOR_TEST_PING_FAILS="${FLOOR_TEST_PING_FAILS:-2}"
# The staleness bound, DERIVED from the tier's resolved timeout (#626). The
# collector's default, PING_INTERVAL_S * (PING_FAILS_TO_WEDGE + 2), is safe
# only while the interval dominates the timeout, which production's 10 s / 5 s
# satisfies and this tier inverts: at 2 s / 4 s the default is 8 s while a
# round can take PING_TIMEOUT + 5 and a ping lives its own round plus one
# period, so `ff-wedged`'s served age reached 10–11 s and its wedge verdict
# flipped stale between a block's read and its POST. The worst case is
# 2 * (PING_TIMEOUT + 5) + 2 — the per-round bound twice, plus the sleep
# floor — so a changed timeout moves the bound with it. Exported, because
# every module suite that imports floor.ping must resolve the same number as
# the running collector; a suite that needs a SHORT bound sets it locally.
FLOOR_TEST_PING_STALE_AFTER="${FLOOR_TEST_PING_STALE_AFTER:-$(( 2 * (FLOOR_TEST_PING_TIMEOUT + 5) + 2 ))}"
export FLOOR_TEST_PING_INTERVAL FLOOR_TEST_PING_TIMEOUT FLOOR_TEST_PING_FAILS FLOOR_TEST_PING_STALE_AFTER
export CREW_FLOOR_PING_STALE_AFTER="$FLOOR_TEST_PING_STALE_AFTER"

export FLOOR_FIXTURE="$HERE/fixtures/fleet.txt"
# The fleet under the page is the fixture, so the walk may demand the states
# only the fixture guarantees: a hostile-log box, a first-session box, several
# offline. The drill deliberately does NOT set this -- a real fleet has no such
# boxes, and a healthy one has nothing offline, so those demands would fail on
# every host forever. cli.sh asserts both halves of that split.
export FLOOR_TEST_FIXTURE=1
export FLOOR_CALLS="$TMP/box-calls.log"
export FLOOR_STATE="$TMP/state"
# The main collector's stub state under its own name: test/cli.sh, sourced
# later, re-exports FLOOR_STATE for its own stub and removes that directory,
# so a reader after it (browser.js resetting a fixture) names this one.
export FLOOR_MAIN_STATE="$FLOOR_STATE"
export PATH="$TMP/bin:$PATH"
mkdir -p "$TMP/bin" "$FLOOR_STATE"
ln -sf "$HERE/stub-box" "$TMP/bin/box"
: > "$FLOOR_CALLS"

# Keep ambient operator and duty configuration out of fixture resolution.
# These static assertions make removing either half fail in this suite. They
# read this file, not a part's state, so one part makes them: the collector.
if [ "$PART" = collector ]; then
  if grep -Fqx 'unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG DUTY_DIR' "$HERE/run.sh"; then
    ok "suite unsets ambient crew and duty config"
  else
    fail "suite unsets ambient crew and duty config" "guard missing"
  fi
  # shellcheck disable=SC2016  # Match the literal assignment in this file.
  if grep -Fqx 'export XDG_CONFIG_HOME="$TMP/xdg-empty"' "$HERE/run.sh"; then
    ok "suite pins empty XDG config"
  else
    fail "suite pins empty XDG config" "guard missing"
  fi
fi

# The fixture fleet is handed to the collector by env, NOT by swapping the
# tracked fleet.roster and restoring it on exit: any killed run then left the
# real roster clobbered in the working tree, one `git add -A` away from being
# committed.
export CREW_FLOOR_ROSTER="$HERE/fixtures/roster.txt"
export FLOOR_TEST_VERSION="crew 9.8.7-fixture ($FLOOR)"
# Exercise the same prerelease grammar used by candidate drills. The stub box
# emits this as its installed engine stamp; browser.js then has to carry the
# suffix all the way through the tile's integrity verdict.
export FLOOR_TEST_ENGINE_VERSION="9.9.9-rc1"

# ...and the suite's own operator fleet DEFINITION, which is a different thing
# (#244). `crew floor` and floor.py now refuse under the examples fallback,
# and CREW_FLOOR_ROSTER does not lift that: it selects a roster file while
# fleet.conf and the agent profiles still come from the resolved config dir.
# Exporting only the roster left every case here resolving that dir to the
# shipped examples/ — i.e. to the refusal. Built under $TMP, so it is the
# suite's own definition and not anything ambient: the unset above still keeps
# the operator's real config out, and this puts a known one in its place.
export CREW_CONFIG_DIR="$TMP/opconfig"
mkdir -p "$CREW_CONFIG_DIR"
cp "$HERE/fixtures/roster.txt" "$CREW_CONFIG_DIR/fleet.roster"
printf 'FLEET_HUMAN=fixture\n' >"$CREW_CONFIG_DIR/fleet.conf"
printf 'heavy-duty/crew\n' >"$CREW_CONFIG_DIR/repos.txt"
# The alert sink is a host command from fleet.conf. `tee` is deliberately
# boring: it makes every delivered stdin message observable without a network
# service, credential, or box-side helper.
export FLOOR_ALERT_LOG="$TMP/reachability-alerts.log"
: >"$FLOOR_ALERT_LOG"
printf 'FLEET_FLOOR_ALERT_CHANNEL="tee -a %s"\n' "$FLOOR_ALERT_LOG" \
  >>"$CREW_CONFIG_DIR/fleet.conf"
# Every part builds this definition; the collector part asserts it, once.
if [ "$PART" = collector ]; then
  if [ -f "$CREW_CONFIG_DIR/fleet.roster" ] && [ "$CREW_CONFIG_DIR" = "$TMP/opconfig" ]; then
    ok "suite serves its own operator fleet definition, not the shipped examples"
  else
    fail "suite serves its own operator fleet definition, not the shipped examples" \
         "every floor.py in this suite would hit the #244 refusal"
  fi
fi

# shellcheck disable=SC2317  # invoked by the traps below, which shellcheck
# does not treat as a call site.
cleanup() {
  [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null
  [ -n "${SRV2:-}" ] && kill "$SRV2" 2>/dev/null
  [ -n "${SRV3:-}" ] && kill "$SRV3" 2>/dev/null
  [ -n "${SRV4:-}" ] && kill "$SRV4" 2>/dev/null
  [ -n "${SRV5:-}" ] && kill "$SRV5" 2>/dev/null
  [ -n "${SRV6:-}" ] && kill "$SRV6" 2>/dev/null
  [ -n "${SRV7:-}" ] && kill "$SRV7" 2>/dev/null
  [ -n "${SRV8:-}" ] && kill "$SRV8" 2>/dev/null
  [ -n "${SRV9:-}" ] && kill "$SRV9" 2>/dev/null
  [ -n "${SRV10:-}" ] && kill "$SRV10" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

# ---- part: collector (the Python suites) ---------------------------------
if [ "$PART" = collector ]; then
  if python3 "$HERE/concurrent-actions.py"; then
    ok "fleet-wide actions run concurrently in stable order"
  else
    fail "fleet-wide actions run concurrently in stable order" "see output above"
  fi

  # #875: a member the host tick stopped is asleep, not a lost signal.
  if python3 "$HERE/asleep.py"; then
    ok "units: a stopped member the store saw hired is asleep; one the operator holds is held (#875, #898)"
  else
    fail "units: a stopped member the store saw hired is asleep; one the operator holds is held (#875, #898)" "see output above"
  fi

  # #898, #899: a member's intent, the verb each lifecycle action runs, the
  # state laid over a unit, a removal refused on duty, the health window.
  if python3 "$HERE/member-state.py"; then
    ok "member: intent, lifecycle verbs, held state and the health window (#898, #899)"
  else
    fail "member: intent, lifecycle verbs, held state and the health window (#898, #899)" "see output above"
  fi

  # #847: a job that reads finished has released its slot, so the next one starts.
  if python3 "$HERE/job-slot.py"; then
    ok "jobs: a job that reads finished has released its slot (#847)"
  else
    fail "jobs: a job that reads finished has released its slot (#847)" "see output above"
  fi

  # #879: the fleet's review panel — what the page reads and what a save writes.
  if python3 "$HERE/panel.py"; then
    ok "panel: the fleet's review panel is read, flagged and written in place (#879)"
  else
    fail "panel: the fleet's review panel is read, flagged and written in place (#879)" "see output above"
  fi

  # #864: the engine's GitHub App — tokens, the manifest flow, the floor's routes.
  if python3 "$HERE/engine.py"; then
    ok "engine: the host reads GitHub as its App, and no reply or journal holds the key (#864)"
  else
    fail "engine: the host reads GitHub as its App, and no reply or journal holds the key (#864)" "see output above"
  fi
fi

api() {  # api METHOD PATH [BODY] -> "<status>\n<body>"
  local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -s -u "$USER:$PASSWD" -X "$m" -H 'Content-Type: application/json' \
      -d "$b" -w '\n%{http_code}' "http://127.0.0.1:$PORT$p"
  else
    curl -s -u "$USER:$PASSWD" -X "$m" -w '\n%{http_code}' "http://127.0.0.1:$PORT$p"
  fi
}
status() { api "$@" | tail -1; }
body()   { api "$@" | sed '$d'; }
jqf()    { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)" 2>/dev/null; }
unit()   { body GET /api/fleet | python3 -c "
import json,sys
d=json.load(sys.stdin)
u=[x for x in d['units'] if x['box']=='$1']
print(json.dumps(u[0]) if u else '{}')"; }
uf()     { unit "$1" | python3 -c "import json,sys;u=json.load(sys.stdin);print($2)" 2>/dev/null; }
# ufg BOX EXPR — like uf, with `g` bound to the snapshot's own `generated`
# epoch: a reading that is "on the host timeline" is on the timeline of the
# poll that produced it, not of whatever wall clock the assertion runs under
# (a slower poll — the store's full pull, a loaded runner — made the old
# `time.time()` comparison stale by the time units.sh reached it, #758).
ufg()    { body GET /api/fleet | python3 -c "
import json,sys,datetime
d=json.load(sys.stdin)
u=[x for x in d['units'] if x['box']=='$1'][0]
g=datetime.datetime.strptime(d['generated'],'%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()
print($2)" 2>/dev/null; }

# The main collector: the collector part asserts against it, and the page
# part walks it. Each part boots its own over its own stub state, so the walk
# stands on the fixture as written, not on what the control verbs left.
if [ "$PART" = collector ] || [ "$PART" = page ]; then
  echo "== collector"
  CREW_FLOOR_PASS="$PASSWD" CREW_FLOOR_USER="$USER" CREW_FLOOR_PORT="$PORT" \
  CREW_FLOOR_BIND=127.0.0.1 CREW_FLOOR_INTERVAL=3600 \
  CREW_FLOOR_PROBE_TIMEOUT="${FLOOR_TEST_PROBE_TIMEOUT:-6}" \
      CREW_FLOOR_ACTION_TIMEOUT="${FLOOR_TEST_ACTION_TIMEOUT:-8}" \
  CREW_FLOOR_PING_INTERVAL="$FLOOR_TEST_PING_INTERVAL" \
  CREW_FLOOR_PING_TIMEOUT="$FLOOR_TEST_PING_TIMEOUT" \
  CREW_FLOOR_PING_FAILS="$FLOOR_TEST_PING_FAILS" \
  CREW_FLOOR_VERSION="$FLOOR_TEST_VERSION" \
    python3 "$FLOOR/server/floor.py" >"$TMP/server.log" 2>&1 &
  SRV=$!

  for _ in $(seq 1 60); do
    curl -fsS -u "$USER:$PASSWD" "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break
    kill -0 "$SRV" 2>/dev/null || { echo "collector died:"; cat "$TMP/server.log"; exit 1; }
    sleep 0.5
  done
  # The first poll must finish before any fleet assertion, or every one of them
  # races the collector's startup and fails intermittently.
  for _ in $(seq 1 80); do
    [ "$(body GET /api/fleet | jqf "len(d['units'])")" != "0" ] && break
    sleep 0.5
  done
fi

export PORT USER PASSWD TMP
# ---- part: collector (the module suites) ---------------------------------
if [ "$PART" = collector ]; then
  # One suite per collector module, at the path that mirrors it (#508 D2). They
  # share this collector and this file's reporters rather than each booting their
  # own: eight servers would cost CI eight first polls to assert what one does.
  #
  # The ORDER is load-bearing, and what it constrains is READS, not writes: a
  # suite belongs after whatever writes the stub state it reads. ping.sh is last
  # because the ping tier reads state the control verbs write; `wake-silent`
  # runs after the fixture's stopped box has been started, same rule, same
  # direction.
  #
  # "A suite that mutates stub state belongs at or after actions.sh" would be a
  # tidier rule and it is FALSE one file away: floor/server.sh's concurrency
  # block fires five real `pause` commands at ff-idle and is sourced before
  # actions.sh. That is fine, and why it is fine is the actual rule — `pause`
  # writes ff-idle.cron, the only assertions that read ff-idle read .state
  # (actions.sh's power verbs), and nothing downstream reads ff-idle's paused
  # flag at all. No read to order against, so no constraint. In cases.sh that
  # block ran AFTER those power verbs (line 379 against 247) and here it runs
  # before them; both trees green is the evidence that the distinction is real
  # and not a story.
  #
  # What this does NOT preserve is cases.sh's exact interleaving, and it cannot:
  # grouping by module is the whole of D2, and cases.sh ran each module's blocks
  # scattered through the file. Measured at the split on the --no-browser set,
  # branch against 394bdad, pivoting on the first actions.sh assertion
  # (`cmd: pause ok`) in each tree:
  #
  #   after -> before   51 names
  #   before -> after    0 names
  #
  # One direction, all of it. Nothing that ran before the control verbs now runs
  # after them, so no assertion reads state that is MORE mutated than it used to
  # be; the 51 read state that is less. They are `server.sh`'s HTTP/`logs:`/
  # concurrency rows, `fleet.sh`'s wedged-and-garbage rows, `units.sh`'s
  # snapshot-shape rows, and the `integrity:`/`ping:`/`creds:` rows that are
  # static greps or read fields the control verbs do not write. Both trees run
  # all of them green, which is the two-sided evidence: each asserts the same
  # value before the control verbs that it asserted after them.
  #
  # Re-measuring this needs one normalisation. `flow: a fresh tick is reported
  # as an age (N s)` puts a MEASURED duration in the assertion name, so two runs
  # of the same tree can differ by that one name; strip the parenthetical before
  # comparing the sets or it reports a difference that is a clock, not an order.
  #
  # So the invariant to keep when adding a suite is the read: place it after
  # whatever writes the state it reads, and if nothing it reads is written here,
  # position is free.
  # init.sh reads no stub state at all — it imports the package and asks what is
  # on it — so by the rule above its position is free. It goes first because it
  # is the package root, and because if the compatibility block is broken the
  # clearest possible report is the first suite saying so.
  # shellcheck source=floor/init.sh
  source "$HERE/floor/init.sh"
  # shellcheck source=floor/units.sh
  source "$HERE/floor/units.sh"
  # shellcheck source=floor/roster.sh
  source "$HERE/floor/roster.sh"
  # shellcheck source=floor/fleet.sh
  source "$HERE/floor/fleet.sh"
  # store.sh reads no state another suite writes — its first half drives
  # store.py in-process over fixture records and its second boots a collector
  # of its own on PORT+4 over a private fixture — so by the rule above its
  # position is free; it sits with the collector suites it is about (#758).
  # shellcheck source=floor/store.sh
  source "$HERE/floor/store.sh"
  # shellcheck source=floor/server.sh
  source "$HERE/floor/server.sh"
  # shellcheck source=floor/actions.sh
  source "$HERE/floor/actions.sh"
  # shellcheck source=floor/credentials.sh
  source "$HERE/floor/credentials.sh"
  # shellcheck source=floor/pages.sh
  source "$HERE/floor/pages.sh"
  # shellcheck source=floor/pool.sh
  source "$HERE/floor/pool.sh"
  # shellcheck source=floor/inflight.sh
  source "$HERE/floor/inflight.sh"
  # shellcheck source=floor/ping.sh
  source "$HERE/floor/ping.sh"
  # Reachability transitions ride the ping tier and are asserted last, after the
  # earlier suites have left that tier running through many unchanged rounds.
  # That ordering is what makes alerts.sh's one-edge assertion a deduplication
  # test rather than a single-poll happy path.
  # shellcheck source=floor/alerts.sh
  source "$HERE/floor/alerts.sh"
  # registry.sh WRITES the fleet definition this whole file resolves against, so
  # by the read rule above it goes after every suite that reads it — and it puts
  # a `gh` stub on PATH, which boxside.sh below must not inherit. It restores
  # both before it returns; the position is the belt to that file's braces.
  # shellcheck source=floor/registry.sh
  source "$HERE/floor/registry.sh"
  # workspaces.sh moved to the page-live part (#902): it boots its own
  # collector over its own host and drives the workspaces and lobby walks.
  # boxentry.sh reads the shared collector's snapshot and drives the module
  # in-process; it writes nothing the rest reads.
  # shellcheck source=floor/boxentry.sh
  source "$HERE/floor/boxentry.sh"
  # The two scripts that normally only run inside a box, executed for real —
  # without this the collector assertions above are circular (they validate the
  # parser against stub-box's imitation of probe.sh, not against probe.sh).
  # shellcheck source=boxside.sh
  source "$HERE/boxside.sh"
fi

# ---- part: cli -------------------------------------------------------------
# `crew floor` itself: the only part an operator types, and where the auth
# decision is made. Its own part, because cli.sh re-exports FLOOR_STATE,
# FLOOR_FIXTURE and CREW_FLOOR_ROSTER to a scratch dir it removes at its end:
# a reader after it in the same shell named a directory that was gone.
if [ "$PART" = cli ]; then
  # shellcheck source=cli.sh
  source "$HERE/cli.sh"
fi

# ---- browser -------------------------------------------------------------
# walk_count_verdict LOG RECORDED — the browser walk's assertion count against
# the EXACT green count recorded at its call site below. One of:
#   missing        the log carries no '-- browser: N ok' line
#   below N        a block returned early: N checks ran, fewer than recorded
#   above N        the walk gained checks and the literal was not moved
#   exact N
# Both directions red (#655). Below is the drain this number exists to catch;
# above is not a defect in the change that grew the walk, it is the
# maintenance the number requires, and staying green on it is how the literal
# sat at 96 while the walk asserted 153. Kept outside the browser branch so the
# rows under it run in --no-browser too, on fake logs, never a real walk.
walk_count_verdict() {
  local n
  n="$(sed -n 's/.*-- browser: \([0-9]*\) ok.*/\1/p' "$1" | tail -1)"
  if [ -z "$n" ]; then echo missing
  elif [ "$n" -lt "$2" ]; then echo "below $n"
  elif [ "$n" -gt "$2" ]; then echo "above $n"
  else echo "exact $n"
  fi
}
# walk_count_report LABEL VERDICT RECORDED — the row walk() prints for a verdict.
walk_count_report() {
  local label="$1" verdict="$2" recorded="$3"
  case "$verdict" in
    missing) fail "$label: reported its assertion count" "no '-- browser: N ok' line; the walk exited 0 without a summary" ;;
    below\ *) fail "$label: asserted enough to be meaningful" "only ${verdict#below } checks ran, expected >= $recorded — a block returned early" ;;
    above\ *) fail "$label: asserted exactly the recorded count" "the walk asserted ${verdict#above } checks and run.sh records $recorded: set the literal at this walk's call site to ${verdict#above } and add its ledger line. This is the upkeep the exact count asks for, not a defect in your change" ;;
    *) ok "$label: asserted ${verdict#exact } checks (exactly the recorded $recorded)" ;;
  esac
}
# ---- part: page (the ledger rows, with or without a browser) ---------------
if [ "$PART" = page ]; then
  echo
  echo "== browser walk count (#655)"
  WC_LOG="$TMP/walk-count.log"
  printf '  -- browser: 153 ok, 0 skipped, 0 failed\n' >"$WC_LOG"
  t "walk count: the recorded count passes" "exact 153" "$(walk_count_verdict "$WC_LOG" 153)"
  t "walk count: one above the recorded count reds" "above 153" "$(walk_count_verdict "$WC_LOG" 152)"
  t "walk count: one below the recorded count reds" "below 153" "$(walk_count_verdict "$WC_LOG" 154)"
  printf 'ok  something\n' >"$WC_LOG"
  t "walk count: a log with no summary line reds" "missing" "$(walk_count_verdict "$WC_LOG" 153)"
  printf '  -- browser: 9 ok\n  -- browser: 153 ok, 0 skipped, 0 failed\n' >"$WC_LOG"
  t "walk count: the last summary line is the one read" "exact 153" "$(walk_count_verdict "$WC_LOG" 153)"
  # The rows walk() prints, captured with ok/fail that only print, so they do
  # not count here: the above arm names the observed count and the edit it asks for, and
  # the below arm keeps the message it always had.
  wc_row() (
    ok()   { echo "ok   $1"; }
    fail() { echo "FAIL $1${2:+  — $2}"; }
    walk_count_report "w" "$1" "$2"
  )
  case "$(wc_row "above 154" 153)" in
    FAIL*"asserted 154 checks and run.sh records 153"*"set the literal"*"ledger line"*) ok "walk count: the above-count row names the count, the literal and the ledger line" ;;
    *) fail "walk count: the above-count row names the count, the literal and the ledger line" "$(wc_row "above 154" 153)" ;;
  esac
  case "$(wc_row "below 150" 153)" in
    "FAIL w: asserted enough to be meaningful  — only 150 checks ran, expected >= 153 — a block returned early") ok "walk count: the below-count row keeps its message" ;;
    *) fail "walk count: the below-count row keeps its message" "$(wc_row "below 150" 153)" ;;
  esac
  case "$(wc_row "exact 153" 153)" in
    ok*) ok "walk count: the exact row is an ok" ;;
    *) fail "walk count: the exact row is an ok" "$(wc_row "exact 153" 153)" ;;
  esac
fi

# ---- part: page-live (workspaces.sh, with or without a browser) -----------
# workspaces.sh boots its own collector over its own host (two fleets, a stub
# CLI) and reads nothing another collector writes. It drives the workspaces
# and lobby walks when a browser is here, and posts what they would without.
if [ "$PART" = page-live ]; then
  # shellcheck source=floor/workspaces.sh
  source "$HERE/floor/workspaces.sh"
fi

if [ "$BROWSER" -eq 1 ] && { [ "$PART" = page ] || [ "$PART" = page-live ]; }; then
  echo
  echo "== page${PART#page}"
  # Both halves must be present: the driver, and a browser for it to drive.
  # PW_CHROME lets CI point at the runner's preinstalled Chrome instead of
  # downloading one.
  CHROME_BIN="${PW_CHROME:-$HOME/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome}"
  # On a developer machine a missing browser is a skip; in CI it is a failure.
  # Same words, different verdict: locally not everyone has Chrome, but a
  # skipped UI test on the merge gate reads exactly like a passing one.
  # CI sets FLOOR_TEST_REQUIRE_BROWSER=1.
  if [ "${FLOOR_TEST_REQUIRE_BROWSER:-0}" = "1" ]; then
    absent() { fail "browser walk" "$1 (FLOOR_TEST_REQUIRE_BROWSER=1: this is a failure, not a skip)"; }
  else
    absent() { skip "browser walk" "$1"; }
  fi
  if ! command -v node >/dev/null; then
    absent "node not installed"
  elif ! (cd "$HERE" && node -e "require('playwright-core')") >/dev/null 2>&1; then
    absent "playwright-core not installed (npm i playwright-core)"
  elif [ ! -x "$CHROME_BIN" ]; then
    absent "no browser at $CHROME_BIN (set PW_CHROME)"
  else
    export PW_CHROME="$CHROME_BIN"
    # ---- part: page ----------------------------------------------------------
    if [ "$PART" = page ]; then
      # Run the walk, then check it actually ASSERTED something.
      #
      # "0 failed" is not the same as "it ran". A walk that finds no hostile box,
      # or returns early from a block, exits 0 having asserted a fraction of what
      # it claims to cover — which is how a suite goes green while the coverage
      # quietly drains out of it. The walk's own tail line reports its count, so
      # hold it to the count recorded here, EXACTLY (walk_count_verdict above):
      # a walk that gains or loses a permanent check moves the literal in the
      # same change, with its ledger line.
      walk() { # walk <label> <recorded-count> <args...>
        local label="$1" recorded="$2"; shift 2
        local log rc
        log="$TMP/walk-$(printf '%s' "$label" | tr -cd '[:alnum:]').log"
        node "$HERE/browser.js" "$@" 2>&1 | tee "$log"; rc="${PIPESTATUS[0]}"
        if [ "$rc" -ne 0 ]; then
          fail "$label" "see output above"
          return
        fi
        ok "$label"
        walk_count_report "$label" "$(walk_count_verdict "$log" "$recorded")" "$recorded"
      }
      # 30 -> 40 with the heartbeat/stuck/renew assertions, then -> 38 when the
      # renewal countdown was dropped and its four checks went with it, then -> 39
      # when the engine assertion split in two: a shape check that holds on any
      # fleet, and the exact-fixture check that only this run can make (#202).
      # Moved deliberately each time: the floor exists so a walk that silently
      # stops asserting cannot still exit 0, and it caught that removal. 39 -> 53
      # with #203's fourteen: the disarmed box and the genuinely silent one across
      # four readouts each plus a reachability check, and the paused box's four,
      # captured where the walk pauses one itself. 53 -> 61 with #190's seven: the
      # engine tile's integrity verdict on any fleet, the three fixture verdicts
      # rendering distinctly with a reachability check for each of the two new
      # boxes, and the guard that keeps the rescoped gh check from retiring
      # itself — the gh check is rescoped, not added, so it counts zero.
      #
      # Seven added to 53 is 60, and this said 61: the number was meant as the
      # walk's EXACT green count, measured, with the old floor's one check of
      # slack spent on purpose. A tripwire a check can be deleted under is not
      # one — with slack, removing an assertion still clears the floor, which is
      # precisely the silent drain this number exists to catch (#190's test plan
      # asks for that case by name). Until #655 the comparison was `-lt`, so the
      # "exact" was advisory and drifted (below); it is enforced now, both ways.
      # The count is deterministic in a green run: every conditional block here
      # is guarded by a check that fails when its box is unreachable, so a run
      # that asserts fewer than the recorded count is already red.
      # 61 -> 65 with #347's API-to-canvas exact-version pair, its two-width
      # cross-layer collision guard, and the room-HUD exact-version assertion.
      # 65 -> 74 with #204's nine: the hired tile's count and its command, the two
      # shape checks that hold on any fleet (nothing unhired is drawn, nothing
      # unmeasurable is dropped), the four fixture boxes that make the decision
      # table's rows bite by name, and the payload guard that keeps the filter
      # page-side. Three assertions were RENAMED rather than added — the roster
      # count, the unit tile and the reachability sweep now say "deployed" where
      # they said "declared" — so they count zero, and the floor moves by the nine
      # that are new. The DEMO floor is untouched: every one of the nine is inside
      # `if (LIVE)`, because DEMO has no collector and so no hired verdict.
      # 74 -> 80 with #312's chip vocabulary, the three named-fixture selections,
      # and both chip-to-tile count agreements. The shared vocabulary check also
      # runs in DEMO; its three mode-specific selections move that floor 10 -> 14.
      # 80 -> 81 with #489's one assertion per browser-walk width replacing the
      # old aggregate verdict. A missing width can no longer hide behind the other.
      # 81 -> 87 with #486's cross-layer six. Three on the sentence BEFORE the
      # click: the collector's wedge verdict reaching the page, the restart
      # confirmation naming the force path from it, and the reachable box that
      # must not be told it will be killed. Three on the sentence AFTER it: a
      # restart that escalated saying so, a graceful one claiming nothing of the
      # kind, and the force-stop verb not narrating itself twice. All six are
      # inside `if (LIVE)` — the first three read the payload this collector
      # serves at CREW_FLOOR_PING_FAILS=2, which DEMO has no collector for — so
      # the DEMO floor below is unmoved.
      #
      # 87 -> 96 with #486's round 2, which closes the gap between the sentence
      # and the request. Six on the mode: the wedged box authorising the force
      # path it was shown and the reachable one authorising only the gentle path
      # (a pair, because a plan whose words and mode disagree is the bug itself),
      # the console re-opened to drive the SHIPPED click rather than the hook,
      # that click putting a mode on the wire at all, and a refusal arriving as
      # the collector's words rather than as "HTTP 409" or as a failure. Three
      # more on the status line's failure path: a restart that killed the guest
      # and then could not start it saying so, a gentle failure claiming no kill,
      # and a force stop that itself failed not being reported as one. All nine
      # are inside `if (LIVE)`, so the DEMO floor below is again unmoved.
      #
      # 96 -> 153 with #655, and no coverage is added by it: the walk had been
      # asserting 153 while the `-lt` floor sat at 96, fifty-seven checks
      # accumulated across the landings since #486's round 2 that never moved
      # the literal. #655 makes the comparison exact, so the next one must.
      # Measured on main at abf6d68 (ci-floor run 41882224938) and again on the
      # PR head; browser.js is unchanged by #655.
      #
      # 153 -> 158 with #870/#874. The registries are pages now: the fleet's
      # page gains its own-address row (the Esc row became the Floor tab's, a
      # rename), and a refused Add on #/repositories gains four — said beside
      # it in red, with the collector's reason, the typed value kept, and the
      # list unchanged. All inside `if (LIVE)`; the DEMO floor is unmoved.
      walk "browser walk" 158 "http://127.0.0.1:$PORT/" "$TMP/shots" "$USER" "$PASSWD"
      # DEMO is a shipped mode, not a fallback: `open index.html` must still work
      # with no collector, no network and every control visibly disabled.
      # 14 -> 21 with #655, the same accumulated drift as the live walk's.
      walk "browser walk (DEMO mode)" 21 "file://$FLOOR/index.html" "$TMP/shots-demo"

      # The #226 acceptance criteria: deterministic stills (zero steady-state
      # builds), bounded portrait motion, reproducible dev renders, reduced
      # motion. Runs on DEMO because its roster is static — the "stable roster"
      # the claims are about.
      echo
      echo "== portrait motion (#226)"
      if node "$HERE/motion.js" "file://$FLOOR/index.html"; then
        ok "portrait motion: #226 acceptance criteria"
      else
        fail "portrait motion: #226 acceptance criteria" "see output above"
      fi
    fi

    # ---- part: page-live: each walk on a collector of its own ----------------
    if [ "$PART" = page-live ]; then
      # Killed collector, on its own throwaway instance (the page part's walk
      # keeps its own collector; this part has no other).
      echo
      echo "== collector death"
      SPORT=$((PORT + 1))
      CREW_FLOOR_PASS="$PASSWD" CREW_FLOOR_USER="$USER" CREW_FLOOR_PORT="$SPORT" \
      CREW_FLOOR_BIND=127.0.0.1 CREW_FLOOR_INTERVAL=3600 \
      CREW_FLOOR_PROBE_TIMEOUT="${FLOOR_TEST_PROBE_TIMEOUT:-6}" \
      CREW_FLOOR_ACTION_TIMEOUT="${FLOOR_TEST_ACTION_TIMEOUT:-8}" \
        python3 "$FLOOR/server/floor.py" >"$TMP/server2.log" 2>&1 &
      SRV2=$!
      # Wait for its FIRST POLL, not just the socket: a page that loads against a
      # collector with no snapshot yet sees an empty fleet, and the stale test
      # would then be asserting against a page that never went live.
      for _ in $(seq 1 120); do
        floor_snapshot="$(curl -fsS -u "$USER:$PASSWD" "http://127.0.0.1:$SPORT/api/fleet" 2>/dev/null)"
        grep -q '"box"' <<<"$floor_snapshot" && break
        sleep 0.5
      done
      if node "$HERE/stale.js" "http://127.0.0.1:$SPORT/" "$SRV2" "$USER" "$PASSWD"; then
        ok "page reports a dead collector"
      else
        fail "page reports a dead collector" "see output above"
      fi
      kill "$SRV2" 2>/dev/null

      # The roster changing under an open console. Its own collector, over its
      # own stub state: this one polls fast and owns a scratch roster the test is
      # allowed to edit.
      echo
      echo "== roster churn"
      CPORT=$((PORT + 2))
      cp "$HERE/fixtures/roster.txt" "$TMP/churn-roster.txt"
      mkdir -p "$TMP/state-churn"
      FLOOR_STATE="$TMP/state-churn" \
      CREW_FLOOR_ROSTER="$TMP/churn-roster.txt" \
      CREW_FLOOR_PASS="$PASSWD" CREW_FLOOR_USER="$USER" CREW_FLOOR_PORT="$CPORT" \
      CREW_FLOOR_BIND=127.0.0.1 CREW_FLOOR_INTERVAL=6 \
      CREW_FLOOR_PROBE_TIMEOUT="${FLOOR_TEST_PROBE_TIMEOUT:-6}" \
      CREW_FLOOR_ACTION_TIMEOUT="${FLOOR_TEST_ACTION_TIMEOUT:-8}" \
        python3 "$FLOOR/server/floor.py" >"$TMP/server3.log" 2>&1 &
      SRV3=$!
      for _ in $(seq 1 120); do
        floor_snapshot="$(curl -fsS -u "$USER:$PASSWD" "http://127.0.0.1:$CPORT/api/fleet" 2>/dev/null)"
        grep -q '"box"' <<<"$floor_snapshot" && break
        sleep 0.5
      done
      if SHOT_DIR="$TMP" node "$HERE/churn.js" "http://127.0.0.1:$CPORT/" \
           "$TMP/churn-roster.txt" "$USER" "$PASSWD"; then
        ok "roster churn"
      else
        fail "roster churn" "see output above"
      fi
      kill "$SRV3" 2>/dev/null

      # The read-only walk is NOT here. It used to be: a second full walk with
      # FLOOR_TEST_READONLY=1, watching the stub's call log to prove no control
      # command was issued. It cost ~3 minutes of a 10-minute CI to assert a
      # property about a fleet CI does not have, re-checking navigation, identity
      # and XSS that the walk above checked two minutes earlier.
      #
      # It moved to drill/rehearsal-app.sh, which has real boxes and wraps the
      # real `box` CLI to read the calls. CI tests the plumbing; the drill is what
      # gets to the metal. cli.sh asserts the drill still carries it, so this is a
      # move and not a deletion — a check that leaves CI and lands nowhere is the
      # same as a check that was deleted, and reads better in a commit message.

      # A box changing STATE under an open console: every other page test enters
      # a console and leaves within one poll, so the live-update path is
      # otherwise untested. A fast-polling collector of its own (#902), over its
      # own stub state and the fixture roster as written. It used to share
      # churn's, and so stood on churn's restored roster: churn.js removes the
      # roster's first box and restores the file in its teardown, and
      # transition.js walks the floor BY ROSTER INDEX, so a mid-restore snapshot
      # had it click one cell left of its target. The wait below is the same
      # wait: a snapshot with the working box in it before standing on it.
      TPORT=$((PORT + 6))
      mkdir -p "$TMP/state-transition"
      FLOOR_STATE="$TMP/state-transition" \
      CREW_FLOOR_PASS="$PASSWD" CREW_FLOOR_USER="$USER" CREW_FLOOR_PORT="$TPORT" \
      CREW_FLOOR_BIND=127.0.0.1 CREW_FLOOR_INTERVAL=6 \
      CREW_FLOOR_PROBE_TIMEOUT="${FLOOR_TEST_PROBE_TIMEOUT:-6}" \
      CREW_FLOOR_ACTION_TIMEOUT="${FLOOR_TEST_ACTION_TIMEOUT:-8}" \
        python3 "$FLOOR/server/floor.py" >"$TMP/server-transition.log" 2>&1 &
      SRV9=$!
      for _ in $(seq 1 120); do
        floor_snapshot="$(curl -fsS -u "$USER:$PASSWD" "http://127.0.0.1:$TPORT/api/fleet" 2>/dev/null)"
        grep -q '"ff-working"' <<<"$floor_snapshot" && break
        sleep 0.5
      done
      echo
      echo "== state transition"
      if SHOT_DIR="$TMP" node "$HERE/transition.js" "http://127.0.0.1:$TPORT/" "$USER" "$PASSWD"; then
        ok "state transition under an open console"
      else
        fail "state transition under an open console" "see output above"
      fi
      kill "$SRV9" 2>/dev/null

      # A fleet of only deliberately-stopped boxes (#203). It has to be its own
      # roster: the assertion is "the alarm counter reads zero", and the fixture
      # fleet is seventeen boxes broken in seventeen ways on purpose. Its own
      # collector over its own stub state (#902): it used to reuse churn's and
      # rewrite churn's roster, which made it the one walk that had to run last.
      #
      # ff-paused is paused by hand here, as it always was. It used to be needed:
      # `wake-silent` in the collector cases resumed it (test/floor/actions.sh)
      # in the state dir every collector shared. This part's stub state is its
      # own, so the line now restates what the fixture already says.
      echo
      echo "== a disarmed fleet raises no alarm (#203)"
      SPPORT=$((PORT + 9))
      mkdir -p "$TMP/state-stopped"
      echo paused > "$TMP/state-stopped/ff-paused.cron"
      printf 'ff-disarmed   grok    builder\nff-paused     codex   reviewer\n' \
        > "$TMP/stopped-roster.txt"
      FLOOR_STATE="$TMP/state-stopped" \
      CREW_FLOOR_ROSTER="$TMP/stopped-roster.txt" \
      CREW_FLOOR_PASS="$PASSWD" CREW_FLOOR_USER="$USER" CREW_FLOOR_PORT="$SPPORT" \
      CREW_FLOOR_BIND=127.0.0.1 CREW_FLOOR_INTERVAL=6 \
      CREW_FLOOR_PROBE_TIMEOUT="${FLOOR_TEST_PROBE_TIMEOUT:-6}" \
      CREW_FLOOR_ACTION_TIMEOUT="${FLOOR_TEST_ACTION_TIMEOUT:-8}" \
        python3 "$FLOOR/server/floor.py" >"$TMP/server-stopped.log" 2>&1 &
      SRV10=$!
      # Both halves, not just the count: the roster shrinking to two is one poll,
      # the re-pause landing in the snapshot can be the next one, and standing on
      # the first alone asserts against a box the collector still thinks is armed.
      for _ in $(seq 1 120); do
        if curl -fsS -u "$USER:$PASSWD" "http://127.0.0.1:$SPPORT/api/fleet" 2>/dev/null \
             | python3 -c "
import json,sys
u=json.load(sys.stdin)['units']
sys.exit(0 if len(u)==2 and all(x['disarmed'] for x in u) and any(x['paused'] for x in u) else 1)"; then
          break
        fi
        sleep 0.5
      done
      if node "$HERE/stopped.js" "http://127.0.0.1:$SPPORT/" "$USER" "$PASSWD"; then
        ok "a disarmed fleet raises no alarm"
      else
        fail "a disarmed fleet raises no alarm" "see output above"
      fi
      kill "$SRV10" 2>/dev/null

      # An all-unhired fleet, and the first box hired into it (#204). Its own
      # collector, because it is the one test here that owns BOTH halves of the
      # stub's input: a roster of two, and a private copy of the fleet fixture it
      # rewrites mid-run to hire a box. Reusing another collector would have
      # meant editing the fixture every other test in this suite reads.
      #
      # Fast interval: the acceptance criterion is that a console appears on the
      # NEXT POLL with no restart, so the poll is the thing being waited on.
      echo
      echo "== the empty floor, and the first box hired into it (#204)"
      HPORT=$((PORT + 3))
      printf 'hf-nothired   kimi    builder\nhf-absent     kimi    triage\n' \
        > "$TMP/hired-roster.txt"
      printf 'hf-nothired    running  nothired\nhf-absent      absent   working\n' \
        > "$TMP/hired-fixture.txt"
      mkdir -p "$TMP/state-hired"
      FLOOR_STATE="$TMP/state-hired" \
      FLOOR_FIXTURE="$TMP/hired-fixture.txt" \
      CREW_FLOOR_ROSTER="$TMP/hired-roster.txt" \
      CREW_FLOOR_PASS="$PASSWD" CREW_FLOOR_USER="$USER" CREW_FLOOR_PORT="$HPORT" \
      CREW_FLOOR_BIND=127.0.0.1 CREW_FLOOR_INTERVAL=4 \
      CREW_FLOOR_PROBE_TIMEOUT="${FLOOR_TEST_PROBE_TIMEOUT:-6}" \
      CREW_FLOOR_ACTION_TIMEOUT="${FLOOR_TEST_ACTION_TIMEOUT:-8}" \
        python3 "$FLOOR/server/floor.py" >"$TMP/server4.log" 2>&1 &
      SRV4=$!
      for _ in $(seq 1 120); do
        floor_snapshot="$(curl -fsS -u "$USER:$PASSWD" "http://127.0.0.1:$HPORT/api/fleet" 2>/dev/null)"
        grep -q '"hf-nothired"' <<<"$floor_snapshot" && break
        sleep 0.5
      done
      if SHOT_DIR="$TMP" node "$HERE/hired.js" "http://127.0.0.1:$HPORT/" \
           "$TMP/hired-fixture.txt" "$USER" "$PASSWD"; then
        ok "the empty floor, and the first box hired into it"
      else
        fail "the empty floor, and the first box hired into it" "see output above"
      fi
      kill "$SRV4" 2>/dev/null
    fi
  fi
fi

echo
echo "== part $PART: wall $(fmt_wall $((SECONDS - PART_START)))"
echo "== summary: $PASS ok, $SKIP skipped, ${#FAILS[@]} failed"
if [ "${#FAILS[@]}" -gt 0 ]; then
  printf '  failed: %s\n' "${FAILS[@]}"
  exit 1
fi
exit 0
