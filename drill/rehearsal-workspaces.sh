#!/usr/bin/env bash
# drill/rehearsal-workspaces.sh — the `workspaces` (#814) and `floor-provision`
# (#815) legs, on a real box host.
#
#   workspaces       one floor in front of two fleets: each fleet's page and API
#                    hold only its own members; an action or a roster save on one
#                    fleet cannot reach a box of the other; the host tick counts
#                    the boxes every fleet runs; an unknown fleet is a 404; the
#                    unscoped API is the home fleet's.
#   floor-provision  a fleet made from the floor, empty; one triage member added
#                    with a roster save; Up's plan names exactly that box; the
#                    confirmed Create mints, starts and hires it as a streamed
#                    job; Hire again is a no-op at the same version; a second job
#                    is refused while one runs; Credentials logs it in from the
#                    round's own pool entry; one host tick on the empty registry
#                    starts nothing; the journal holds a line per job; a removed
#                    row leaves the box standing.
#
# Everything this leg makes lives under its own XDG_CONFIG_HOME and host state
# directory: the operator's fleets, index and host maintenance lock are never
# read or written. The round's fleet here is a definition over the round's own
# drill boxes; the leg's one box is crew-drill-floor, which it removes at the
# end unless the round keeps its boxes (REHEARSAL_KEEP=1).
#
# Verdicts go to REHEARSAL_WORKSPACES_STATUS and REHEARSAL_PROVISION_STATUS,
# one `ok|FAIL|skip <why>` line per case, folded by rehearsal-all.sh.
set -uo pipefail

BOXES=""
AGENT="claude"
LEGS_RUN="workspaces floor-provision"
usage() { echo "usage: drill/rehearsal-workspaces.sh --boxes \"<crew-drill-…> ...\" [--agent <name>] [--legs \"workspaces floor-provision\"]"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --boxes) BOXES="$2"; shift 2 ;;
    --agent) AGENT="$2"; shift 2 ;;
    --legs) LEGS_RUN="$2"; shift 2 ;;
    *) usage; exit 1 ;;
  esac
done
[ -n "${BOXES// /}" ] || { usage; exit 1; }
for b in $BOXES; do
  case "$b" in crew-drill-*) ;; *) echo "refusing non-drill box '$b'" >&2; exit 1 ;; esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The one door into a box (#792): box_in enters as the agent on box 0.11.0 and
# later. A copy of this script with no shared/lib beside it (a test harness)
# keeps today's door.
if [ -r "$ROOT/shared/lib/box-entry.sh" ]; then
  # shellcheck disable=SC1091
  . "$ROOT/shared/lib/box-entry.sh"
else
  # shellcheck disable=SC2317  # reached only without shared/lib
  box_in() { local b="$1"; shift; box exec "$b" "$@"; }
fi
CREW="$ROOT/cli/crew"
PROV_BOX="crew-drill-floor"
command -v box >/dev/null || { echo "drill/rehearsal-workspaces.sh runs on a box HOST — no 'box' on PATH"; exit 1; }
command -v curl >/dev/null || { echo "drill/rehearsal-workspaces.sh needs curl"; exit 1; }

WS_VERDICTS=""; PV_VERDICTS=""; CUR=ws
verdict() { if [ "$CUR" = ws ]; then WS_VERDICTS="$WS_VERDICTS"$'\n'"$1"; else PV_VERDICTS="$PV_VERDICTS"$'\n'"$1"; fi; }
ok()   { echo "ok   $1"; verdict "ok $1"; }
fail() { echo "FAIL $1${2:+  — $2}"; verdict "FAIL $1${2:+ — $2}"; }
skip() { echo "skip $1${2:+  — $2}"; verdict "skip $1${2:+ — $2}"; }
t() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected [$2] got [$3]"; fi; }
want() { case " $LEGS_RUN " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

TMP="$(mktemp -d)"
export XDG_CONFIG_HOME="$TMP/xdg" CREW_HOST_STATE_DIR="$TMP/hoststate"
unset CREW_CONFIG_DIR CREW_FLEET CREW_FLEETS_DIR CREW_ROSTER CREW_FLOOR_ROSTER CREW_FLEET_WALK
mkdir -p "$XDG_CONFIG_HOME" "$CREW_HOST_STATE_DIR"
# The service's index (#822), here a scratch one: the round's fleet is `default`.
export CREW_FLEETS_DIR="$TMP/fleets"
FLEETS="$CREW_FLEETS_DIR"; DEF="$FLEETS/default"
PASS_W="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-20)"
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
SRV=""
MINTED=0

# shellcheck disable=SC2317  # invoked by the EXIT trap below
cleanup() {
  local rc=$?
  [ -z "$SRV" ] || { kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; }
  if [ "$MINTED" -eq 1 ]; then
    if [ "${REHEARSAL_KEEP:-0}" = 1 ]; then
      echo "teardown: $PROV_BOX KEPT (--keep) — remove it with: drill/teardown.sh --box $PROV_BOX --yes"
    elif box rm --force "$PROV_BOX" >/dev/null 2>&1; then
      echo "teardown: removed $PROV_BOX"
    else
      echo "teardown: WARNING — could not remove $PROV_BOX; remove it with: drill/teardown.sh --box $PROV_BOX --yes" >&2
    fi
  fi
  rm -rf -- "$TMP"
  [ -z "${REHEARSAL_WORKSPACES_STATUS:-}" ] || printf '%s\n' "$WS_VERDICTS" >>"$REHEARSAL_WORKSPACES_STATUS"
  [ -z "${REHEARSAL_PROVISION_STATUS:-}" ] || printf '%s\n' "$PV_VERDICTS" >>"$REHEARSAL_PROVISION_STATUS"
  trap - EXIT
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

api() {  # api METHOD PATH [BODY-FILE] -> "<body>\n<status>"
  if [ -n "${3:-}" ]; then
    curl -s -u "operator:$PASS_W" -X "$1" -H 'Content-Type: application/json' --data-binary "@$3" -w '\n%{http_code}' "http://127.0.0.1:$PORT$2"
  else
    curl -s -u "operator:$PASS_W" -X "$1" -w '\n%{http_code}' "http://127.0.0.1:$PORT$2"
  fi
}
post() { printf '%s' "$3" >"$TMP/body.json"; api "$1" "$2" "$TMP/body.json"; }
bodyof() { sed '$d'; }
codeof() { tail -1; }
jf() { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)" 2>/dev/null; }

# --- the host: the round's fleet (default) and a second, empty one -----------------
echo "== workspaces — one floor, several fleets (#814)"
if ! "$CREW" init --fleet default >"$TMP/init.out" 2>&1; then
  echo "could not build the round's fleet with crew init: $(cat "$TMP/init.out")" >&2; exit 1
fi
: >"$DEF/fleet.roster"
for b in $BOXES; do printf '%s %s %s\n' "$b" "$AGENT" "${b#crew-drill-}" >>"$DEF/fleet.roster"; done
printf 'FLEET_MAX_RUNNING=%s\n' "$(wc -w <<<"$BOXES")" >>"$DEF/fleet.conf"
"$CREW" init --fleet second >"$TMP/init2.out" 2>&1 || { echo "crew init --fleet second failed: $(cat "$TMP/init2.out")" >&2; exit 1; }
ok "two fleets on the host: the round's ($(wc -w <<<"$BOXES") boxes) and an empty one, both made by the CLI"

CREW_FLOOR_PASS="$PASS_W" CREW_FLOOR_USER=operator CREW_FLOOR_PORT="$PORT" CREW_FLOOR_BIND=127.0.0.1 \
CREW_FLOOR_INTERVAL=10 CREW_FLOOR_VERSION="$("$CREW" --version 2>/dev/null | head -1)" \
  python3 "$ROOT/fleet-floor/server/floor.py" >"$TMP/floor.log" 2>&1 &
SRV=$!
for _ in $(seq 1 120); do
  [ "$(api GET /api/fleets | codeof)" = 200 ] && [ "$(api GET /f/second/api/roster | codeof)" = 200 ] && break
  kill -0 "$SRV" 2>/dev/null || break
  sleep 0.5
done
if ! kill -0 "$SRV" 2>/dev/null; then
  fail "the floor came up over both fleets" "$(tail -5 "$TMP/floor.log")"; exit 1
fi
# The first poll of the round's fleet, before any reading of its units.
for _ in $(seq 1 120); do
  [ "$(api GET /api/fleet | bodyof | jf "len(d.get('units',[]))")" -ge 1 ] 2>/dev/null && break
  sleep 1
done

if want workspaces; then
  CUR=ws
  F="$(api GET /api/fleets | bodyof)"
  t "workspaces: the floor lists both fleets, the round's first" "default second" "$(jf "' '.join(f['id'] for f in d['fleets'])" <<<"$F")"
  t "workspaces: the round's fleet page holds only its boxes" "$(tr ' ' '\n' <<<"$BOXES" | sort | paste -sd' ' -)" \
    "$(api GET /f/default/api/fleet | bodyof | jf "' '.join(sorted(u['box'] for u in d['units']))")"
  t "workspaces: the second fleet's page holds none of them" "0" \
    "$(api GET /f/second/api/fleet | bodyof | jf "len(d['units'])")"
  t "workspaces: the unscoped API is the home fleet's" \
    "$(api GET /f/default/api/fleet | bodyof | jf "' '.join(sorted(u['box'] for u in d['units']))")" \
    "$(api GET /api/fleet | bodyof | jf "' '.join(sorted(u['box'] for u in d['units']))")"
  t "workspaces: an unknown fleet is 404 on the API" 404 "$(api GET /f/nope/api/fleet | codeof)"
  t "workspaces: an unknown fleet is 404 on the page" 404 "$(api GET /f/nope/ | codeof)"
  first_box="${BOXES%% *}"
  before_cron="$(box_in "$first_box" -- bash -lc 'crontab -l 2>/dev/null | md5sum' </dev/null 2>/dev/null)"
  R="$(post POST /f/second/api/command "{\"action\":\"pause\",\"box\":\"$first_box\"}")"
  case "$(codeof <<<"$R")" in 4*) ok "workspaces: a pause posted to the second fleet naming a round box is refused" ;;
    *) fail "workspaces: a pause posted to the second fleet naming a round box is refused" "HTTP $(codeof <<<"$R")" ;; esac
  t "workspaces: ...and the box's crontab is untouched" "$before_cron" \
    "$(box_in "$first_box" -- bash -lc 'crontab -l 2>/dev/null | md5sum' </dev/null 2>/dev/null)"
  t "workspaces: ...and no pause marker was written for it" 0 "$(find "$DEF/store/paused" "$FLEETS/second/store/paused" -name "$first_box" 2>/dev/null | grep -c .)"
  etag="$(api GET /f/second/api/roster | bodyof | jf "d['etag']")"
  R="$(post POST /f/second/api/command "{\"action\":\"roster-set\",\"etag\":\"$etag\",\"members\":[{\"box\":\"$first_box\",\"agent\":\"$AGENT\",\"roles\":[\"triage\"]}]}")"
  t "workspaces: a roster save in the second fleet listing a round box is refused" 400 "$(codeof <<<"$R")"
  t "workspaces: ...naming the round's fleet" 1 "$(bodyof <<<"$R" | jf "d['error']" | grep -c "already on fleet 'default''s roster")"
  printf '%s %s triage\n' "$first_box" "$AGENT" >>"$FLEETS/second/fleet.roster"
  OUT="$("$CREW" --fleet second up --dry-run 2>&1)"
  t "workspaces: crew up in the second fleet would refuse the round box" 1 "$(grep -c "^$first_box: WOULD REFUSE — fleet 'default'" <<<"$OUT")"
  t "workspaces: ...and plans nothing for it" 0 "$(grep -c "^$first_box: WOULD \(create\|start\|hire\)" <<<"$OUT")"
  sed -i "/^$first_box /d" "$FLEETS/second/fleet.roster"
  OUT="$("$CREW" --fleet second tick --dry-run 2>&1)"
  running="$(for b in $BOXES; do box info "$b" --json 2>/dev/null | grep -c '"running"\|"Running"'; done | awk '$1>0{c++} END{print c+0}')"
  t "workspaces: the second fleet's tick counts the round's running boxes" 1 \
    "$(grep -c "^  host: 0 running in this fleet, $running in the host's other fleets" <<<"$OUT")"
fi

if want floor-provision; then
  CUR=pv
  echo
  echo "== floor-provision — a fleet built from the floor (#815)"
  case "$(box list --json 2>/dev/null)" in *"\"$PROV_BOX\""*)
    fail "floor-provision: $PROV_BOX does not exist yet" "an earlier round left it; drill/teardown.sh --box $PROV_BOX --yes"
    exit 0 ;;
  esac
  R="$(post POST /api/fleets '{"id":"prov"}')"
  t "floor-provision: New fleet creates it" 200 "$(codeof <<<"$R")"
  t "floor-provision: ...empty" 0 "$(grep -cvE '^[[:space:]]*(#|$)' "$FLEETS/prov/fleet.roster" 2>/dev/null)"
  t "floor-provision: ...with an empty registry" 0 "$(grep -cvE '^[[:space:]]*(#|$)' "$FLEETS/prov/repos.txt" 2>/dev/null)"
  for _ in $(seq 1 60); do [ "$(api GET /f/prov/api/roster | codeof)" = 200 ] && break; sleep 0.5; done
  # A hired member on duty is not removed from the roster (#898): it is
  # unhired first, from the floor, which hands its claims back and stops its
  # box. Then its row goes, and the box is left standing (stopped).
  R="$(post POST /f/prov/api/command "{\"action\":\"unhire\",\"box\":\"$PROV_BOX\"}")"
  t "floor-provision: Unhire from the floor answers" 200 "$(codeof <<<"$R")"
  t "floor-provision: ...and the member is off duty" 1 "$(bodyof <<<"$R" | jf "d['results'][0]['out']" | grep -c '^off duty — disarmed and stopped')"
  etag="$(api GET /f/prov/api/roster | bodyof | jf "d['etag']")"
  R="$(post POST /f/prov/api/command "{\"action\":\"roster-set\",\"etag\":\"$etag\",\"members\":[{\"box\":\"$PROV_BOX\",\"agent\":\"$AGENT\",\"roles\":[\"triage\"]}]}")"
  t "floor-provision: a roster save adds the triage member" 200 "$(codeof <<<"$R")"
  waitjob() {  # waitjob ID [SECONDS]
    local end=$((SECONDS + ${2:-60})) st
    while :; do
      st="$(api GET "/f/prov/api/jobs?id=$1" | bodyof | jf "d['state']")"
      [ "$st" != running ] && { echo "$st"; return 0; }
      [ "$SECONDS" -lt "$end" ] || { echo timeout; return 1; }
      sleep 2
    done
  }
  R="$(post POST /f/prov/api/jobs "{\"verb\":\"up\",\"plan\":true}")"
  plan="$(bodyof <<<"$R" | jf "d['job']['id']")"
  waitjob "$plan" 120 >/dev/null
  PLAN_OUT="$(api GET "/f/prov/api/jobs?id=$plan" | bodyof | jf "'\n'.join(d['output'])")"
  t "floor-provision: Up's plan names that box" "1 1" "$(grep -c "^$PROV_BOX: WOULD create" <<<"$PLAN_OUT") $(grep -c "^$PROV_BOX: WOULD hire" <<<"$PLAN_OUT")"
  t "floor-provision: ...and no box of the round's fleet" 0 "$(grep -c '^crew-drill-\(triage\|builder\|reviewer\):' <<<"$PLAN_OUT")"
  t "floor-provision: Create without its own plan is refused" 409 "$(post POST /f/prov/api/jobs "{\"verb\":\"create\",\"box\":\"$PROV_BOX\"}" | codeof)"
  R="$(post POST /f/prov/api/jobs "{\"verb\":\"create\",\"box\":\"$PROV_BOX\",\"plan\":true}")"
  cplan="$(bodyof <<<"$R" | jf "d['job']['id']")"
  waitjob "$cplan" 120 >/dev/null
  R="$(post POST /f/prov/api/jobs "{\"verb\":\"create\",\"box\":\"$PROV_BOX\",\"confirm\":\"$cplan\"}")"
  t "floor-provision: the confirmed Create starts" 202 "$(codeof <<<"$R")"
  run="$(bodyof <<<"$R" | jf "d['job']['id']")"
  MINTED=1
  sleep 3
  R="$(post POST /f/prov/api/jobs "{\"verb\":\"hire\",\"box\":\"$PROV_BOX\"}")"
  t "floor-provision: a second job is refused while Create runs" 409 "$(codeof <<<"$R")"
  t "floor-provision: ...naming the running job" 1 "$(bodyof <<<"$R" | jf "d['error']" | grep -c "crew up $PROV_BOX on fleet prov")"
  t "floor-provision: the running job reports a step" 1 "$(api GET "/f/prov/api/jobs?id=$run" | bodyof | jf "1 if d['step'] else 0")"
  st="$(waitjob "$run" 1800)"
  RUN_OUT="$(api GET "/f/prov/api/jobs?id=$run" | bodyof | jf "'\n'.join(d['output'])")"
  t "floor-provision: Create finished" "done 0" "$st $(api GET "/f/prov/api/jobs?id=$run" | bodyof | jf "d['rc']")"
  [ "$st" = "done" ] || printf '%s\n' "$RUN_OUT" | tail -20 | sed 's/^/  create: /'
  t "floor-provision: ...streaming its output" 1 "$([ "$(wc -l <<<"$RUN_OUT")" -ge 3 ] && echo 1 || echo 0)"
  want_ver="$("$CREW" --version 2>/dev/null | awk '{print $2}' | head -1)"
  hired=""
  for _ in $(seq 1 30); do
    hired="$(api GET /f/prov/api/fleet | bodyof | jf "[(u.get('hired'),u.get('engine','')) for u in d['units'] if u['box']=='$PROV_BOX'][0]")"
    case "$hired" in *"'yes'"*) break ;; esac
    sleep 5
  done
  t "floor-provision: the member reads hired on the next poll" 1 "$(grep -c "'yes'" <<<"$hired")"
  t "floor-provision: ...on the round's engine" 1 "$(grep -cF "$want_ver" <<<"$hired")"
  R="$(post POST /f/prov/api/jobs "{\"verb\":\"hire\",\"box\":\"$PROV_BOX\"}")"
  hire="$(bodyof <<<"$R" | jf "d['job']['id']")"
  st="$(waitjob "$hire" 600)"
  HIRE_OUT="$(api GET "/f/prov/api/jobs?id=$hire" | bodyof | jf "'\n'.join(d['output'])")"
  t "floor-provision: Hire again finishes" "done" "$st"
  t "floor-provision: ...as a no-op at the same version" 1 "$(grep -c "^$PROV_BOX: already hired at .* matches, skipping" <<<"$HIRE_OUT")"
  # Credentials, from the round's own pool entry: the secret goes from the
  # pool file into a 0600 request body, never into an argv.
  gh_entry="$(sed -n 's/.*\bgh:\([A-Za-z0-9._-]*\).*/\1/p' <<<"${REHEARSAL_CREDS:-}")"
  if [ -n "$gh_entry" ] && [ -r "${CREW_CREDENTIALS_DIR:-}/entries/gh--$gh_entry/secret" ]; then
    ( umask 077; python3 - "$CREW_CREDENTIALS_DIR/entries/gh--$gh_entry/secret" "$PROV_BOX" >"$TMP/cred.json" <<'PY'
import json, sys
print(json.dumps({"action": "credentials-set", "box": sys.argv[2], "service": "gh", "kind": "token",
                  "secret": open(sys.argv[1]).read().strip()}))
PY
    )
    R="$(api POST /f/prov/api/command "$TMP/cred.json")"; rm -f "$TMP/cred.json"
    t "floor-provision: Credentials sets the gh token from the floor" 200 "$(codeof <<<"$R")"
    t "floor-provision: ...and the box says it is logged in" 1 "$(bodyof <<<"$R" | jf "d.get('verdict','')" | grep -c '^gh: set — logged in as ')"
  else
    skip "floor-provision: Credentials sets the gh token from the floor" "no --creds gh:<name> pool entry handed to this round"
  fi
  OUT="$("$CREW" --fleet prov tick 2>&1)"
  t "floor-provision: one host tick on the empty registry starts nothing" 1 "$(grep -c '^tick: started 0, woke 0,' <<<"$OUT")"
  JOURNAL="$FLEETS/prov/.jobs-journal.log"
  t "floor-provision: the journal holds one line per job (two plans, Create, Hire)" 4 "$(grep -c ' fleet=prov verb=' "$JOURNAL" 2>/dev/null)"
  etag="$(api GET /f/prov/api/roster | bodyof | jf "d['etag']")"
  R="$(post POST /f/prov/api/command "{\"action\":\"roster-set\",\"etag\":\"$etag\",\"members\":[{\"box\":\"crew-drill-ghost\",\"agent\":\"$AGENT\",\"roles\":[\"triage\"]}]}")"
  t "floor-provision: the member's row is removed" 200 "$(codeof <<<"$R")"
  t "floor-provision: ...and its box is left standing" 1 "$(box list --json 2>/dev/null | grep -c "\"$PROV_BOX\"")"
fi
exit 0
