#!/usr/bin/env bash
# drill/rehearsal-service.sh — the `service` leg (#822), on a real box host.
#
# crew is one service per machine. This leg stands one up under SCRATCH names —
# account and group crew-drill-svc, /etc/crew-drill-svc, /var/lib/crew-drill-svc,
# units crew-drill-svc-*, the tree installed under /opt/crew-drill-svc — so it
# never touches a real crew service on the host, then reads it end to end and
# tears it down with --purge:
#
#   setup converges, with no fleet (#831); check is clean; a caller outside the
#   group is refused naming it; the floor unit answers with no fleet and its
#   lobby, and New fleet makes the first; the service's own runs write only
#   under its data dir and read its fleets; a box Created from that floor lands
#   in the service's box project and not the operator's; the tick timer's unit
#   runs the tick as the service; teardown --purge leaves no unit, rule, account
#   or data behind.
#
# Needs: passwordless sudo (`sudo -n`), box 0.11.0 or later (service grants),
# systemd. Without one of them every reading is a `skip` naming it, and the
# round reads INCOMPLETE. Verdicts go to REHEARSAL_SERVICE_STATUS.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT="${1:-claude}"
U=crew-drill-svc; G=crew-drill-svc; PREFIX=crew-drill-svc
ETC=/etc/crew-drill-svc; DATA=/var/lib/crew-drill-svc; OPT=/opt/crew-drill-svc
CLI="$OPT/bin/crew"; SVC_BOX=crew-drill-svcbox
VERDICTS=""
ok()   { echo "ok   $1"; VERDICTS="$VERDICTS"$'\n'"ok $1"; }
fail() { echo "FAIL $1${2:+  — $2}"; VERDICTS="$VERDICTS"$'\n'"FAIL $1${2:+ — $2}"; }
skip() { echo "skip $1${2:+  — $2}"; VERDICTS="$VERDICTS"$'\n'"skip $1${2:+ — $2}"; }
t() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected [$2] got [$3]"; fi; }
TMP="$(mktemp -d)"
STOOD=0
asvc() { sudo -n -u "$U" -H env CREW_ETC_DIR="$ETC" "$@"; }
aroot() { sudo -n env CREW_ETC_DIR="$ETC" CREW_DATA_DIR="$DATA" "$@"; }
# shellcheck disable=SC2317  # invoked by the EXIT trap
cleanup() {
  local rc=$?
  if [ "$STOOD" -eq 1 ]; then
    asvc box rm --force "$SVC_BOX" </dev/null >/dev/null 2>&1 || true
    aroot "$CLI" service teardown --purge </dev/null >/dev/null 2>&1 || true
    sudo -n rm -rf -- "$OPT" 2>/dev/null || true
    echo "teardown: the scratch service ($U, $ETC, $DATA, $PREFIX-*, $OPT) removed"
  fi
  rm -rf -- "$TMP"
  [ -z "${REHEARSAL_SERVICE_STATUS:-}" ] || printf '%s\n' "$VERDICTS" >>"$REHEARSAL_SERVICE_STATUS"
  trap - EXIT
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "== service — crew as one service per machine (#822)"
# --- what the leg needs --------------------------------------------------------------
if ! sudo -n true 2>/dev/null; then skip "service: the leg ran" "needs passwordless sudo on the drill host (sudo -n)"; exit 0; fi
command -v systemctl >/dev/null 2>&1 || { skip "service: the leg ran" "needs systemd (systemctl)"; exit 0; }
# shellcheck source=shared/lib/box-entry.sh
. "$ROOT/shared/lib/box-entry.sh"
box_entry_resolve_mode 2>/dev/null || { skip "service: the leg ran" "box --version is unreadable"; exit 0; }
[ "$BOX_ENTRY_MODE_CACHED" = user ] || { skip "service: the leg ran" "needs box 0.11.0 or later (service grants, box#281)"; exit 0; }

# --- a clean slate under the scratch names, then the tree installed for the account -----
if sudo -n test -e "$ETC/service.conf"; then
  aroot "$ROOT/cli/crew" service teardown --purge </dev/null >/dev/null 2>&1 || true
  echo "  an earlier round's scratch service was torn down first"
fi
sudo -n rm -rf -- "$OPT"
# The redirect is this shell's on purpose: the log is the operator's scratch file.
# shellcheck disable=SC2024
if ! sudo -n env CREW_HOME="$OPT" CREW_BIN="$OPT/bin" CREW_INSTALL_SOURCE="$ROOT" CREW_YES=1 \
     bash "$ROOT/install.sh" >"$TMP/install.out" 2>&1; then
  fail "service: the tree installs for the account" "$(tail -3 "$TMP/install.out")"; exit 0
fi
STOOD=1
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"

# --- setup and check -------------------------------------------------------------------------
aroot "$CLI" service setup --user "$U" --group "$G" --unit-prefix "$PREFIX" --cli "$CLI" \
  --port "$PORT" --bind 127.0.0.1 --instances 2 </dev/null >"$TMP/setup.out" 2>&1
SETUP_RC=$?
t "service: setup converges the scratch service" 0 "$SETUP_RC"
if [ "$SETUP_RC" -ne 0 ]; then
  # Every reading below stands on the setup: print what it said, and stop (#837).
  sed 's/^/  setup: /' "$TMP/setup.out"
  exit 0
fi
t "service: ...with no fleet (#831)" 0 "$(sudo -n find "$DATA/fleets" -mindepth 1 2>/dev/null | grep -c . || true)"
aroot "$CLI" service setup --user "$U" --group "$G" --unit-prefix "$PREFIX" --cli "$CLI" \
  --port "$PORT" --bind 127.0.0.1 --instances 2 </dev/null >"$TMP/setup2.out" 2>&1
t "service: setup again changes no unit" 7 "$(grep -c "  unit $PREFIX-.*: same$" "$TMP/setup2.out")"
aroot "$CLI" service check </dev/null >"$TMP/check.out" 2>&1
t "service: check reads it back clean" 0 "$?"
[ "$(tail -1 "$TMP/check.out")" = "service: clean" ] || sed 's/^/  check: /' "$TMP/check.out"

# --- who may act, and as whom -----------------------------------------------------------------
OUT="$(CREW_ETC_DIR="$ETC" "$CLI" status 2>&1)"; RC=$?
t "service: a caller outside the group is refused" 1 "$RC"
t "service: ...and told which group to join" 1 "$(grep -c "not in its group '$G'" <<<"$OUT")"
asvc "$CLI" tick </dev/null >"$TMP/tick0.out" 2>&1
t "service: with no fleet the tick has nothing to do" 4 "$?"

# --- the floor unit: empty, then New fleet ---------------------------------------------------
FPASS="$(sudo -n sed -n 's/^CREW_FLOOR_PASS=//p' "$ETC/floor.env")"
fapi() { curl -s -u "operator:$FPASS" "$@"; }
for _ in $(seq 1 90); do fapi -o /dev/null "http://127.0.0.1:$PORT/healthz" && break; sleep 1; done
t "service: the floor runs as the account" "$U" "$(ps -o user= -p "$(systemctl show -p MainPID --value "$PREFIX-floor.service")" 2>/dev/null | tr -d ' ')"
t "service: the floor unit answers with no fleet" "" \
  "$(fapi "http://127.0.0.1:$PORT/api/fleets" | python3 -c 'import json,sys;print(" ".join(f["id"] for f in json.load(sys.stdin)["fleets"]))' 2>/dev/null)"
t "service: ...and its page is the lobby, New fleet" 1 "$(fapi "http://127.0.0.1:$PORT/" | grep -c '>New fleet</button>')"
t "service: New fleet makes the first" "/f/drill/" \
  "$(fapi -H 'Content-Type: application/json' -d '{"id":"drill"}' "http://127.0.0.1:$PORT/api/fleets" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("url",""))' 2>/dev/null)"
t "service: ...owned by the account" "$U:$G" "$(sudo -n stat -c '%U:%G' "$DATA/fleets/drill/fleet.roster" 2>/dev/null)"
asvc "$CLI" init --fleet two </dev/null >/dev/null 2>&1
asvc "$CLI" --fleet drill up --dry-run </dev/null >"$TMP/dry.out" 2>&1
t "service: the account's runs read the service's fleets" 1 "$(grep -c '^up --dry-run: 0 would be created' "$TMP/dry.out")"
t "service: the floor lists them" "drill two" \
  "$(fapi "http://127.0.0.1:$PORT/api/fleets" | python3 -c 'import json,sys;print(" ".join(f["id"] for f in json.load(sys.stdin)["fleets"]))' 2>/dev/null)"
for _ in $(seq 1 60); do [ "$(fapi -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/f/drill/api/roster")" = 200 ] && break; sleep 1; done

# --- a box Created from that floor is the service's -------------------------------------------
ETAG="$(fapi "http://127.0.0.1:$PORT/f/drill/api/roster" | python3 -c 'import json,sys;print(json.load(sys.stdin)["etag"])' 2>/dev/null)"
printf '{"action":"roster-set","etag":"%s","members":[{"box":"%s","agent":"%s","roles":["triage"]}]}' "$ETAG" "$SVC_BOX" "$AGENT" >"$TMP/b.json"
fapi -o /dev/null -H 'Content-Type: application/json' --data-binary "@$TMP/b.json" "http://127.0.0.1:$PORT/f/drill/api/command"
jpost() { printf '%s' "$1" >"$TMP/j.json"; fapi -H 'Content-Type: application/json' --data-binary "@$TMP/j.json" "http://127.0.0.1:$PORT/f/drill/api/jobs"; }
jwait() { for _ in $(seq 1 "$2"); do st="$(fapi "http://127.0.0.1:$PORT/f/drill/api/jobs?id=$1" | python3 -c 'import json,sys;print(json.load(sys.stdin)["state"])' 2>/dev/null)"; [ "$st" != running ] && { echo "$st"; return; }; sleep 2; done; echo timeout; }
PLAN="$(jpost "{\"verb\":\"create\",\"box\":\"$SVC_BOX\",\"plan\":true}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["job"]["id"])' 2>/dev/null)"
jwait "$PLAN" 60 >/dev/null
RUN="$(jpost "{\"verb\":\"create\",\"box\":\"$SVC_BOX\",\"confirm\":\"$PLAN\"}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["job"]["id"])' 2>/dev/null)"
t "service: Create from the service's floor finishes" "done" "$(jwait "$RUN" 900)"
t "service: ...and the box is in the service's project" 1 "$(asvc box list --json 2>/dev/null | grep -c "\"$SVC_BOX\"")"
t "service: ...not in the operator's" 0 "$(box list --json 2>/dev/null | grep -c "\"$SVC_BOX\"" || true)"

# --- the schedule ---------------------------------------------------------------------------
sudo -n systemctl start "$PREFIX-tick.service" >/dev/null 2>&1
t "service: the tick unit runs" 0 "$?"
t "service: ...as the account, logging under its data dir" "$U" "$(sudo -n stat -c '%U' "$DATA/state/host-maintenance.log" 2>/dev/null)"
t "service: ...and the log holds the tick" 1 "$(sudo -n grep -c 'tick run start' "$DATA/state/host-maintenance.log" 2>/dev/null | awk '{print ($1 > 0)}')"

# --- teardown --purge leaves nothing ---------------------------------------------------------
asvc box rm --force "$SVC_BOX" </dev/null >/dev/null 2>&1
aroot "$CLI" service teardown --purge </dev/null >"$TMP/down.out" 2>&1
t "service: teardown --purge succeeds" 0 "$?"
t "service: ...no unit is left" 0 "$(systemctl list-unit-files "$PREFIX-*" --no-legend 2>/dev/null | grep -c . || true)"
t "service: ...no sudoers rule is left" 1 "$(sudo -n test -e "/etc/sudoers.d/$PREFIX" && echo 0 || echo 1)"
t "service: ...no account is left" 1 "$(id -u "$U" >/dev/null 2>&1 && echo 0 || echo 1)"
t "service: ...no data is left" 1 "$(sudo -n test -e "$DATA" && echo 0 || echo 1)"
sudo -n rm -rf -- "$OPT"
STOOD=0
exit 0
