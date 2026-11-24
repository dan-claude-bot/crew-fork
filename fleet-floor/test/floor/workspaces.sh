# shellcheck shell=bash  # sourced by ../run.sh, so it has no shebang of its own
# fleet-floor/test/floor/workspaces.sh — the suite for floor/fleets.py,
# floor/front.py (#814) and floor/jobs.py (#815): one floor in front of several
# fleets, and the CLI's verbs run from it as one job at a time.
#
# It boots its OWN collector, not the shared one: the shared collector serves
# one fixture fleet behind an empty XDG on purpose, and this one needs a host
# with two fleet definitions — the operator's own (`default`, the fixture
# roster) and one in the index (`second`). The CLI the jobs run is a stub that
# records its argv and environment, prints on a schedule, and exits as told;
# `init` alone is handed to the real CLI, so New fleet makes a real fleet.
echo
echo "== workspaces and jobs (#814, #815)"
WS="$TMP/ws"; WS_XDG="$WS/xdg"; WS_STATE="$WS/hoststate"
# The service's index (#822), a fixture: `default` (the fixture roster) and
# `second`. The floor serves the first, alphabetically, at /.
WS_IDX="$WS/fleets"; WS_DEF="$WS_IDX/default"; WS_SECOND="$WS_IDX/second"
mkdir -p "$WS_XDG" "$WS_DEF" "$WS_SECOND" "$WS_STATE"
cp "$CREW_CONFIG_DIR/fleet.conf" "$CREW_CONFIG_DIR/repos.txt" "$WS_DEF/"
cp "$HERE/fixtures/roster.txt" "$WS_DEF/fleet.roster"
cp "$CREW_CONFIG_DIR/fleet.conf" "$CREW_CONFIG_DIR/repos.txt" "$WS_SECOND/"
printf '# the second fleet\nws-two claude triage\n' >"$WS_SECOND/fleet.roster"
WS_CLI="$WS/crew-stub"
WS_LOG="$WS/crew-stub.log"
: >"$WS_LOG"
cat >"$WS_CLI" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = init ]; then exec bash "$FLOOR/../cli/crew" "\$@"; fi
printf '%s|%s|%s\n' "\$*" "\${CREW_CONFIG_DIR:-}" "\${CREW_FLEET_WALK:-}" >>"$WS_LOG"
echo "stub: crew \$*"
for i in \$(seq 1 "\$(cat "$WS/sleep" 2>/dev/null || echo 0)"); do echo "stub: step \$i"; sleep 1; done
case "\$*" in *--dry-run*) echo "ws-two: WOULD create (claude/triage)" ;; esac
exit "\$(cat "$WS/rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$WS_CLI"
WS_PORT=$((PORT + 7))
env -u CREW_CONFIG_DIR -u CREW_FLOOR_ROSTER XDG_CONFIG_HOME="$WS_XDG" CREW_FLEETS_DIR="$WS_IDX" \
  CREW_HOST_STATE_DIR="$WS_STATE" CREW_FLOOR_CREW_CLI="$WS_CLI" \
  CREW_FLOOR_PASS="$PASSWD" CREW_FLOOR_USER="$USER" CREW_FLOOR_PORT="$WS_PORT" \
  CREW_FLOOR_BIND=127.0.0.1 CREW_FLOOR_INTERVAL=3600 CREW_FLOOR_PING_INTERVAL=0 \
  python3 "$FLOOR/server/floor.py" >"$TMP/server-ws.log" 2>&1 &
SRV7=$!
wsapi() {  # wsapi METHOD PATH [BODY] -> "<body>\n<status>"
  if [ -n "${3:-}" ]; then
    curl -s -u "$USER:$PASSWD" -X "$1" -H 'Content-Type: application/json' -d "$3" -w '\n%{http_code}' "http://127.0.0.1:$WS_PORT$2"
  else
    curl -s -u "$USER:$PASSWD" -X "$1" -w '\n%{http_code}' "http://127.0.0.1:$WS_PORT$2"
  fi
}
wsbody() { wsapi "$@" | sed '$d'; }
wsstatus() { wsapi "$@" | tail -1; }
for _ in $(seq 1 60); do
  curl -fsS -u "$USER:$PASSWD" "http://127.0.0.1:$WS_PORT/healthz" >/dev/null 2>&1 && break
  sleep 0.5
done
# The second fleet's child answers once the front has started it.
for _ in $(seq 1 60); do
  [ "$(wsstatus GET /f/second/api/roster)" = 200 ] && break
  sleep 0.5
done

# --- the fleets list and the routes -------------------------------------------
WS_F="$(wsbody GET /api/fleets)"
t "fleets: the host's fleets, home first" "default second" "$(jqf "' '.join(f['id'] for f in d['fleets'])" <<<"$WS_F")"
t "fleets: the home fleet is the one served at /" "default" "$(jqf "d['home']" <<<"$WS_F")"
t "fleets: each fleet's page is /f/<id>/" "/f/default/ /f/second/" "$(jqf "' '.join(f['url'] for f in d['fleets'])" <<<"$WS_F")"
t "fleets: member counts come from each roster" "$(grep -cvE '^[[:space:]]*(#|$)' "$WS_DEF/fleet.roster") 1" "$(jqf "' '.join(str(f['members']) for f in d['fleets'])" <<<"$WS_F")"
t "fleets: /f/<id> redirects to /f/<id>/" "301 /f/second/" \
  "$(curl -s -o /dev/null -u "$USER:$PASSWD" -w '%{http_code} %header{location}' "http://127.0.0.1:$WS_PORT/f/second")"
t "fleets: /f/<id>/ serves the page" 200 "$(wsstatus GET /f/second/)"
t "fleets: the second fleet's roster is its own" "$WS_SECOND ws-two" \
  "$(wsbody GET /f/second/api/roster | jqf "d['config_dir']+' '+' '.join(m['box'] for m in d['members'])")"
t "fleets: the unscoped API answers the home fleet" "$WS_DEF" "$(wsbody GET /api/roster | jqf "d['config_dir']")"
t "fleets: /f/<home>/ is the unscoped API" "$(wsbody GET /api/roster | jqf "d['etag']")" "$(wsbody GET /f/default/api/roster | jqf "d['etag']")"
# A child floor answers before its first poll lands (an empty snapshot, the
# page's "reading the fleet…"), so read it once it has polled, not at once.
WS_UNITS=""
for _ in $(seq 1 60); do
  WS_UNITS="$(wsbody GET /f/second/api/fleet | jqf "' '.join(u['box'] for u in d['units'])")"
  [ -z "$WS_UNITS" ] || break
  sleep 0.5
done
t "fleets: the second fleet's snapshot holds only its members" "ws-two" "$WS_UNITS"
t "fleets: the home snapshot holds none of the second's" 0 \
  "$(wsbody GET /api/fleet | jqf "len([u for u in d['units'] if u['box']=='ws-two'])")"
t "fleets: an unknown fleet is 404 on the API" 404 "$(wsstatus GET /f/nope/api/fleet)"
t "fleets: an unknown fleet is 404 on the page" 404 "$(wsstatus GET /f/nope/)"
t "fleets: a malformed id is 404" 404 "$(wsstatus GET /f/NOPE/api/fleet)"
t "fleets: the list is the front's, not a fleet's" 404 \
  "$(curl -s -o /dev/null -w '%{http_code}' -u "$USER:$PASSWD" "http://127.0.0.1:$WS_PORT/f/second/api/fleets")"

# --- a fleet acts on its own boxes only ------------------------------------------
WS_M=$(fs_mark)
WS_R="$(wsapi POST /f/second/api/command '{"action":"pause","box":"ff-idle"}')"
t "fleets: an action naming another fleet's box is refused" 1 "$(printf '%s' "$WS_R" | tail -1 | grep -c '^4')"
t "fleets: ...and nothing reached that box" 0 "$(fs_calls_since "$WS_M" | grep -c 'ff-idle')"
WS_ETAG="$(wsbody GET /f/second/api/roster | jqf "d['etag']")"
WS_R="$(wsapi POST /f/second/api/command "{\"action\":\"roster-set\",\"etag\":\"$WS_ETAG\",\"members\":[{\"box\":\"ws-two\",\"agent\":\"claude\",\"roles\":[\"triage\"]},{\"box\":\"ff-idle\",\"agent\":\"claude\",\"roles\":[\"reviewer\"]}]}")"
t "fleets: a roster save listing another fleet's box is refused" 400 "$(printf '%s' "$WS_R" | tail -1)"
t "fleets: ...naming the fleet that has it" 1 "$(printf '%s' "$WS_R" | sed '$d' | jqf "d['error']" | grep -c "ff-idle is already on fleet 'default''s roster")"
t "fleets: ...and the roster is unchanged" "ws-two" "$(grep -vE '^[[:space:]]*(#|$)' "$WS_SECOND/fleet.roster" | awk '{print $1}' | paste -sd' ' -)"

# --- New fleet --------------------------------------------------------------------
WS_R="$(wsapi POST /api/fleets '{"id":"third"}')"
t "new fleet: created through the CLI" 200 "$(printf '%s' "$WS_R" | tail -1)"
t "new fleet: the reply is its page" "/f/third/" "$(printf '%s' "$WS_R" | sed '$d' | jqf "d['url']")"
t "new fleet: it is listed" "default second third" "$(wsbody GET /api/fleets | jqf "' '.join(f['id'] for f in d['fleets'])")"
t "new fleet: it has no member" 0 "$(grep -cvE '^[[:space:]]*(#|$)' "$WS_IDX/third/fleet.roster")"
t "new fleet: its floor answers" 200 "$(wsstatus GET /f/third/api/roster)"
t "new fleet: an existing id is refused" 409 "$(wsstatus POST /api/fleets '{"id":"third"}')"
t "new fleet: a bad id is refused" 400 "$(wsstatus POST /api/fleets '{"id":"Third Fleet"}')"
t "new fleet: 'default' is refused" 400 "$(wsstatus POST /api/fleets '{"id":"default"}')"

# --- jobs: the plan first ------------------------------------------------------------
wsjob() { wsbody GET "/f/second/api/jobs?id=$1"; }
wswait() {  # wswait PREFIX ID — until the job is no longer running
  for _ in $(seq 1 80); do
    [ "$(wsbody GET "$1/api/jobs?id=$2" | jqf "d['state']")" != running ] && return 0
    sleep 0.25
  done
}
WS_R="$(wsapi POST /f/second/api/jobs '{"verb":"create","box":"ws-two"}')"
t "jobs: create without a plan is refused" 409 "$(printf '%s' "$WS_R" | tail -1)"
t "jobs: ...saying the plan comes first" 1 "$(printf '%s' "$WS_R" | sed '$d' | jqf "d['error']" | grep -c 'runs only after its plan has been shown')"
t "jobs: an unknown verb is 400" 400 "$(wsstatus POST /f/second/api/jobs '{"verb":"reset"}')"
t "jobs: a box outside the fleet is 400" 400 "$(wsstatus POST /f/second/api/jobs '{"verb":"hire","box":"ff-idle"}')"
t "jobs: hire has no plan" 400 "$(wsstatus POST /f/second/api/jobs '{"verb":"hire","box":"ws-two","plan":true}')"
echo 2 >"$WS/sleep"
WS_R="$(wsapi POST /f/second/api/jobs '{"verb":"create","box":"ws-two","plan":true}')"
t "jobs: the plan starts" 202 "$(printf '%s' "$WS_R" | tail -1)"
WS_PLAN="$(printf '%s' "$WS_R" | sed '$d' | jqf "d['job']['id']")"
WS_R="$(wsapi POST /api/jobs '{"verb":"hire","box":"ff-idle"}')"
t "jobs: one at a time — another fleet's job is refused" 409 "$(printf '%s' "$WS_R" | tail -1)"
t "jobs: ...naming the running one and its fleet" 1 \
  "$(printf '%s' "$WS_R" | sed '$d' | jqf "d['error']" | grep -c 'crew up ws-two --dry-run on fleet second')"
t "jobs: every fleet's tab sees the host's running job" "second create" \
  "$(wsbody GET /api/jobs | jqf "d['current']['fleet']+' '+d['current']['verb']")"
wswait /f/second "$WS_PLAN"
t "jobs: the plan ran the dry run, for that fleet, never as a walk" "up ws-two --dry-run|$WS_SECOND|1" "$(tail -1 "$WS_LOG")"
t "jobs: the plan finished" "done 0" "$(wsjob "$WS_PLAN" | jqf "d['state']+' '+str(d['rc'])")"
t "jobs: its output is kept, line by line" 1 "$(wsjob "$WS_PLAN" | jqf "'\n'.join(d['output'])" | grep -c '^ws-two: WOULD create')"
t "jobs: the step is the last line printed" "finished: exit 0" "$(wsjob "$WS_PLAN" | jqf "d['step']")"
t "jobs: a plan for another verb confirms nothing" 409 "$(wsstatus POST /f/second/api/jobs "{\"verb\":\"up\",\"confirm\":\"$WS_PLAN\"}")"
t "jobs: an unknown plan confirms nothing" 409 "$(wsstatus POST /f/second/api/jobs '{"verb":"create","box":"ws-two","confirm":"nope"}')"
printf '# edited\n' >>"$WS_SECOND/fleet.roster"
WS_R="$(wsapi POST /f/second/api/jobs "{\"verb\":\"create\",\"box\":\"ws-two\",\"confirm\":\"$WS_PLAN\"}")"
t "jobs: a roster changed since the plan confirms nothing" 409 "$(printf '%s' "$WS_R" | tail -1)"
t "jobs: ...and says to plan again" 1 "$(printf '%s' "$WS_R" | sed '$d' | jqf "d['error']" | grep -c 'the roster changed since plan')"
echo 0 >"$WS/sleep"
WS_PLAN="$(wsbody POST /f/second/api/jobs '{"verb":"create","box":"ws-two","plan":true}' | jqf "d['job']['id']")"
wswait /f/second "$WS_PLAN"
echo 2 >"$WS/sleep"
WS_R="$(wsapi POST /f/second/api/jobs "{\"verb\":\"create\",\"box\":\"ws-two\",\"confirm\":\"$WS_PLAN\"}")"
t "jobs: the confirmed plan runs" 202 "$(printf '%s' "$WS_R" | tail -1)"
WS_RUN="$(printf '%s' "$WS_R" | sed '$d' | jqf "d['job']['id']")"
sleep 0.5
t "jobs: a run holds the host maintenance lock" 1 \
  "$(flock -n "$WS_STATE/.host-maintenance.lock" true 2>/dev/null && echo 0 || echo 1)"
t "jobs: ...and names itself as its holder" "floor:create" "$(awk '{print $2}' "$WS_STATE/.host-maintenance.lock.holder")"
t "jobs: the running job reports a step" 1 "$(wsjob "$WS_RUN" | jqf "d['step']" | grep -c '^stub: ')"
wswait /f/second "$WS_RUN"
t "jobs: the run was crew up <box>" "up ws-two|$WS_SECOND|1" "$(tail -1 "$WS_LOG")"
t "jobs: the run released the maintenance lock" 0 \
  "$(flock -n "$WS_STATE/.host-maintenance.lock" true 2>/dev/null && echo 0 || echo 1)"
t "jobs: ...and its holder record" "" "$(cat "$WS_STATE/.host-maintenance.lock.holder")"
t "jobs: the journal says who, what and how it ended" 1 \
  "$(grep -c "^[0-9TZ:-]* $USER fleet=second verb=create box=ws-two confirms=$WS_PLAN argv=\"up ws-two\" rc=0 " "$WS_SECOND/.jobs-journal.log")"
t "jobs: the plan is journalled too" 2 "$(grep -c ' plan=yes ' "$WS_SECOND/.jobs-journal.log")"
t "jobs: each job's output is a log file" 1 "$(grep -c '^stub: crew up ws-two$' "$WS_SECOND"/store/jobs/*-"$WS_RUN".log)"

# A scheduled verb finds the lock held while a floor job runs, and a floor job
# finds it held while a scheduled verb runs.
echo 2 >"$WS/sleep"
WS_RUN="$(wsbody POST /f/second/api/jobs '{"verb":"hire","box":"ws-two"}' | jqf "d['job']['id']")"
sleep 0.5
WS_TICK="$(env -u CREW_FLOOR_ROSTER XDG_CONFIG_HOME="$WS_XDG" CREW_FLEETS_DIR="$WS_IDX" CREW_HOST_STATE_DIR="$WS_STATE" CREW_CONFIG_DIR="$WS_DEF" \
  bash "$FLOOR/../cli/crew" tick --dry-run 2>&1)"
t "jobs: the scheduled tick is skipped while a floor job runs" 1 \
  "$(grep -c "SKIPPED — the host maintenance lock is held by 'crew floor:hire'" <<<"$WS_TICK")"
wswait /f/second "$WS_RUN"
echo 0 >"$WS/sleep"
exec {WS_FD}>>"$WS_STATE/.host-maintenance.lock"
flock -n "$WS_FD"
printf '%s restart 4242\n' "$(date +%s)" >"$WS_STATE/.host-maintenance.lock.holder"
WS_R="$(wsapi POST /f/second/api/jobs '{"verb":"hire","box":"ws-two"}')"
t "jobs: a floor job is refused while a scheduled verb holds the lock" 409 "$(printf '%s' "$WS_R" | tail -1)"
t "jobs: ...naming that verb" 1 "$(printf '%s' "$WS_R" | sed '$d' | jqf "d['error']" | grep -c "held by 'crew restart'")"
t "jobs: ...and the slot is free again after the refusal" 200 "$(wsstatus GET /f/second/api/jobs)"
exec {WS_FD}>&-
: >"$WS_STATE/.host-maintenance.lock.holder"

# A failing verb is a failed job with its exit status.
echo 3 >"$WS/rc"
WS_RUN="$(wsbody POST /f/second/api/jobs '{"verb":"upgrade","box":"ws-two"}' | jqf "d['job']['id']")"
wswait /f/second "$WS_RUN"
t "jobs: a verb that fails is a failed job" "failed 3" "$(wsjob "$WS_RUN" | jqf "d['state']+' '+str(d['rc'])")"
rm -f "$WS/rc"
WS_PLAN="$(wsbody POST /f/second/api/jobs '{"verb":"up","plan":true}' | jqf "d['job']['id']")"
wswait /f/second "$WS_PLAN"
echo 5 >"$WS/rc"
WS_BAD="$(wsbody POST /f/second/api/jobs '{"verb":"up","plan":true}' | jqf "d['job']['id']")"
wswait /f/second "$WS_BAD"
rm -f "$WS/rc"
t "jobs: a failed plan confirms nothing" 409 "$(wsstatus POST /f/second/api/jobs "{\"verb\":\"up\",\"confirm\":\"$WS_BAD\"}")"
t "jobs: recent jobs are this fleet's, newest first" "up up upgrade" \
  "$(wsbody GET /f/second/api/jobs | jqf "' '.join(j['verb'] for j in d['recent'][:3])")"
t "jobs: the home fleet's recent jobs hold none of them" 0 "$(wsbody GET /api/jobs | jqf "len(d['recent'])")"
# A record left by a floor that died mid-job is not a running job.
python3 - "$WS_STATE/floor-job.json" <<'PY'
import json, sys
json.dump({"id": "dead", "fleet": "second", "verb": "up", "argv": ["up"], "state": "running",
           "started": 1, "floor_pid": 999999999}, open(sys.argv[1], "w"))
PY
t "jobs: a dead floor's record is not a running job" None "$(wsbody GET /api/jobs | jqf "d['current']")"

# The page over these fleets (#814/#815), when the suite drives a browser:
# the switcher, the URL, two tabs, the plan, the job bar. Its own walk with its
# own exact count, for the reason the main walk has one (walk_count_verdict).
WS_WALK_COUNT=24
if [ "${BROWSER:-0}" -eq 1 ]; then
  WS_CHROME="${PW_CHROME:-$HOME/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome}"
  if command -v node >/dev/null && (cd "$HERE" && node -e "require('playwright-core')") >/dev/null 2>&1 && [ -x "$WS_CHROME" ]; then
    WS_WALK_LOG="$TMP/walk-workspaces.log"
    (cd "$HERE" && PW_CHROME="$WS_CHROME" node "$HERE/workspaces.js" "http://127.0.0.1:$WS_PORT" "$USER" "$PASSWD" "$WS_LOG" "$WS/sleep") 2>&1 | tee "$WS_WALK_LOG"
    t "workspaces walk: green" 0 "${PIPESTATUS[0]}"
    t "workspaces walk: asserted its recorded count" "walk: $WS_WALK_COUNT ok, 0 failed" "$(tail -1 "$WS_WALK_LOG")"
  fi
fi

WS_CHILD_PORT="$(sed -n 's/.*fleet second served by a child floor on 127.0.0.1:\([0-9]*\).*/\1/p' "$TMP/server-ws.log" | tail -1)"
t "fleets: the second fleet is a loopback child" 1 "$([ -n "$WS_CHILD_PORT" ] && echo 1 || echo 0)"
t "fleets: the child refuses anyone but the front" 401 \
  "$(curl -s -o /dev/null -w '%{http_code}' -u "$USER:$PASSWD" "http://127.0.0.1:$WS_CHILD_PORT/api/fleet")"
kill "$SRV7" 2>/dev/null
wait "$SRV7" 2>/dev/null
SRV7=""
sleep 1
t "fleets: the children go with the front" 000 \
  "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$WS_CHILD_PORT/healthz" || true)"

# --- #831: a host with no fleets — the lobby, then the first fleet -------------
echo
echo "== the floor with no fleet (#831)"
WE="$TMP/ws-empty"; WE_IDX="$WE/fleets"; mkdir -p "$WE_IDX" "$WE/etc" "$WE/xdg" "$WE/state"
WE_PORT=$((PORT + 8))
env -u CREW_CONFIG_DIR -u CREW_FLOOR_ROSTER XDG_CONFIG_HOME="$WE/xdg" CREW_FLEETS_DIR="$WE_IDX" \
  CREW_ETC_DIR="$WE/etc" CREW_HOST_STATE_DIR="$WE/state" CREW_FLOOR_PING_INTERVAL=0 \
  bash "$FLOOR/../cli/crew" floor --port "$WE_PORT" --bind 127.0.0.1 --user "$USER" --pass "$PASSWD" \
  >"$TMP/server-empty.log" 2>&1 &
SRV8=$!
weapi() {  # weapi METHOD PATH [BODY] -> "<body>\n<status>"
  if [ -n "${3:-}" ]; then
    curl -s -u "$USER:$PASSWD" -X "$1" -H 'Content-Type: application/json' -d "$3" -w '\n%{http_code}' "http://127.0.0.1:$WE_PORT$2"
  else
    curl -s -u "$USER:$PASSWD" -X "$1" -w '\n%{http_code}' "http://127.0.0.1:$WE_PORT$2"
  fi
}
for _ in $(seq 1 60); do
  curl -fsS -u "$USER:$PASSWD" "http://127.0.0.1:$WE_PORT/healthz" >/dev/null 2>&1 && break
  sleep 0.5
done
t "no fleet: crew floor says there is none yet" 1 \
  "$(grep -c "^  fleets    none yet — the page's one action is New fleet" "$TMP/server-empty.log")"
t "no fleet: crew floor watches no roster" 0 "$(grep -c '^  roster ' "$TMP/server-empty.log" || true)"
WE_OUT="$(weapi GET /)"
t "no fleet: / is the lobby" 200 "$(tail -1 <<<"$WE_OUT")"
t "no fleet: the lobby says so" 1 "$(grep -c 'No fleets on this host yet.' <<<"$WE_OUT")"
t "no fleet: the lobby's one action is New fleet" 1 "$(grep -c '>New fleet</button>' <<<"$WE_OUT")"
t "no fleet: the fleets list is empty" "[]" "$(weapi GET /api/fleets | sed '$d' | jqf "json.dumps(d['fleets'])")"
WE_OUT="$(weapi GET /api/fleet)"
t "no fleet: the snapshot is a 404" 404 "$(tail -1 <<<"$WE_OUT")"
t "no fleet: ...that names New fleet" 1 "$(sed '$d' <<<"$WE_OUT" | jqf "int(d['error'].startswith('no fleet on this host yet') and 'New fleet' in d['error'])")"
t "no fleet: the roster is a 404" 404 "$(weapi GET /api/roster | tail -1)"
t "no fleet: a command is a 404" 404 "$(weapi POST /api/command '{"action":"pause","box":"x"}' | tail -1)"
t "no fleet: a job is a 404" 404 "$(weapi POST /api/jobs '{"verb":"up","plan":true}' | tail -1)"
t "no fleet: the examples are never served" 0 "$(grep -c 'examples' "$TMP/server-empty.log" || true)"
# New fleet from the lobby: driven in a browser when the suite has one (the
# lobby's own walk, with its own count), else posted as the lobby posts it.
WE_WALK_COUNT=9
WE_WALKED=0
if [ "${BROWSER:-0}" -eq 1 ]; then
  WE_CHROME="${PW_CHROME:-$HOME/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome}"
  if command -v node >/dev/null && (cd "$HERE" && node -e "require('playwright-core')") >/dev/null 2>&1 && [ -x "$WE_CHROME" ]; then
    WE_WALK_LOG="$TMP/walk-lobby.log"
    (cd "$HERE" && PW_CHROME="$WE_CHROME" node "$HERE/lobby.js" "http://127.0.0.1:$WE_PORT" "$USER" "$PASSWD") 2>&1 | tee "$WE_WALK_LOG"
    t "lobby walk: green" 0 "${PIPESTATUS[0]}"
    t "lobby walk: asserted its recorded count" "walk: $WE_WALK_COUNT ok, 0 failed" "$(tail -1 "$WE_WALK_LOG")"
    WE_WALKED=1
  fi
fi
if [ "$WE_WALKED" -eq 0 ]; then
  WE_OUT="$(weapi POST /api/fleets '{"id":"first"}')"
  t "no fleet: New fleet makes the first" 200 "$(tail -1 <<<"$WE_OUT")"
  t "no fleet: ...and opens it" "/f/first/" "$(sed '$d' <<<"$WE_OUT" | jqf "d['url']")"
fi
t "no fleet: ...in the index" 1 "$([ -f "$WE_IDX/first/fleet.roster" ] && echo 1 || echo 0)"
t "first fleet: / now opens it" "302 /f/first/" \
  "$(curl -s -o /dev/null -u "$USER:$PASSWD" -w '%{http_code} %header{location}' "http://127.0.0.1:$WE_PORT/")"
WE_ROSTER=""
for _ in $(seq 1 60); do
  WE_ROSTER="$(weapi GET /f/first/api/roster)"
  [ "$(tail -1 <<<"$WE_ROSTER")" = 200 ] && break
  sleep 0.5
done
t "first fleet: its roster is served, empty" "200 0" \
  "$(tail -1 <<<"$WE_ROSTER") $(sed '$d' <<<"$WE_ROSTER" | jqf "len(d['members'])")"
t "first fleet: the fleets list names it" "first" "$(weapi GET /api/fleets | sed '$d' | jqf "' '.join(f['id'] for f in d['fleets'])")"
kill "$SRV8" 2>/dev/null
wait "$SRV8" 2>/dev/null
SRV8=""
