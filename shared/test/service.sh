#!/usr/bin/env bash
# shellcheck disable=SC2016  # the single-quoted stubs expand in the shells that run them
# shared/test/service.sh — crew as a system service (#822), offline.
#
# `crew service setup | check | teardown` and the re-run of every other verb as
# the service account, against a fixture host: every privileged command
# (groupadd, useradd, systemctl, visudo, box, runuser, sudo, …) is a stub on
# PATH that logs its argv and keeps one marker file per fact, and every path is
# a fixture dir (CREW_ETC_DIR, CREW_DATA_DIR, CREW_SYSTEMD_DIR, CREW_SUDOERS_DIR).
# CREW_SERVICE_ASSUME_ROOT=1 stands in for root.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=shared/test/lib.sh
source "$HERE/lib.sh"
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG
unset CREW_FLEET CREW_FLEETS_DIR CREW_HOST_STATE_DIR CREW_BOX_ENTRY_MODE
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export XDG_CONFIG_HOME="$TMP/xdg-empty"
mkdir -p "$XDG_CONFIG_HOME" "$TMP/bin" "$TMP/marks"
export CREW_ETC_DIR="$TMP/etc" CREW_DATA_DIR="$TMP/data" CREW_SYSTEMD_DIR="$TMP/systemd" CREW_SUDOERS_DIR="$TMP/sudoers.d"
SV_REALID="$(command -v id)"; SV_REALINSTALL="$(command -v install)"
export SV_LOG="$TMP/calls" SV_MARK="$TMP/marks" SV_REALID SV_REALINSTALL
: >"$SV_LOG"
CLI="$ROOT/cli/crew"
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"$TMP/bin/$1"; chmod +x "$TMP/bin/$1"; }
log='printf "%s %s\n" "$(basename "$0")" "$*" >>"$SV_LOG"'
stub box "$log"'
case "$1" in
  --version) echo "box ${SV_BOX:-0.11.0} (x)" ;;
  list) echo "[]" ;;
  grant) [ -z "${SV_GRANT_FAIL:-}" ] || exit 1 ;;
esac'
stub groupadd "$log"'; : >"$SV_MARK/group-${!#}"'
stub groupdel "$log"'; rm -f "$SV_MARK/group-$1"'
stub useradd "$log"'; : >"$SV_MARK/user-${!#}"'
stub userdel "$log"'; rm -f "$SV_MARK/user-$1"'
stub getent "$log"'; [ "$1" = group ] && [ -e "$SV_MARK/group-$2" ]'
stub id '
case "$*" in
  -un) echo "${SV_ME:-operator}" ;;
  -u) if [ -n "${SV_ROOT:-}" ]; then echo 0; else echo 1000; fi ;;
  -nG) echo "${SV_GROUPS:-operator}" ;;
  "-u "*) [ -e "$SV_MARK/user-$2" ] && echo 999 || exit 1 ;;
  *) exec "$SV_REALID" "$@" ;;
esac'
stub systemctl "$log"'
case "$1" in
  enable) shift; [ "$1" = --now ] && shift; for u in "$@"; do : >"$SV_MARK/active-$u"; done ;;
  disable) shift; [ "$1" = --now ] && shift; for u in "$@"; do rm -f "$SV_MARK/active-$u"; done ;;
  is-active) [ -e "$SV_MARK/active-${!#}" ] ;;
esac'
stub visudo "$log"'; [ -z "${SV_VISUDO_FAIL:-}" ]'
stub install '
args=(); skip=0
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in -o|-g) skip=1 ;; *) args+=("$a") ;; esac
done
exec "$SV_REALINSTALL" "${args[@]}"'
stub chgrp ':'
stub stat 'case "$*" in "-c %U:%G "*) echo "${SV_OWNER:-crew:crew}" ;; *) exec /usr/bin/stat "$@" ;; esac'
stub runuser "$log"'
[ "$1" = -u ] && u="$2" && shift 3
export SV_ME="$u"
exec "$@"'
stub sudo "$log"
export PATH="$TMP/bin:$PATH"
export CREW_SERVICE_UNIT_PATH="$TMP/bin:/usr/bin:/bin"
calls() { grep -c -- "$1" "$SV_LOG" || true; }
crew() { bash "$CLI" "$@"; }
capture() { OUT="$(crew "$@" 2>&1)"; RC=$?; }

# --- setup: the refusals -------------------------------------------------------------
capture service setup
t setup-refuses-a-non-root-caller 1 "$RC"
t setup-says-as-root 1 "$(grep -c 'crew service setup runs as root' <<<"$OUT")"
# #837: a box the units cannot find (a per-user install) is named, not met later.
OUT="$(CREW_SERVICE_ASSUME_ROOT=1 CREW_SERVICE_UNIT_PATH=/nonexistent bash "$CLI" service setup 2>&1)"; RC=$?
t setup-refuses-a-box-off-the-units-path 1 "$RC"
t setup-...naming-a-system-wide-install 1 "$(grep -c 'needs box installed system-wide, on the PATH its units run with (/nonexistent)' <<<"$OUT")"
t setup-...before-any-account 0 "$(calls '^useradd\|^groupadd')"
OUT="$(CREW_SERVICE_ASSUME_ROOT=1 SV_BOX=0.10.0 bash "$CLI" service setup 2>&1)"; RC=$?
t setup-refuses-box-below-0.11 1 "$RC"
t setup-names-the-grant-it-needs 1 "$(grep -c 'needs box 0.11.0 or later (its service grants' <<<"$OUT")"
OUT="$(CREW_SERVICE_ASSUME_ROOT=1 SV_VISUDO_FAIL=1 bash "$CLI" service setup --no-start --cli /usr/local/bin/crew 2>&1)"; RC=$?
t setup-refuses-a-rule-visudo-rejects 1 "$RC"
t setup-writes-no-unvalidated-rule 0 "$(find "$CREW_SUDOERS_DIR" -type f 2>/dev/null | grep -c . || true)"
rm -rf "$CREW_ETC_DIR" "$CREW_DATA_DIR" "$TMP/marks"/*; : >"$SV_LOG"

# --- setup: everything, in order ------------------------------------------------------
OUT="$(CREW_SERVICE_ASSUME_ROOT=1 bash "$CLI" service setup --cli "$CLI" 2>&1)"; RC=$?
t setup-exits-0 0 "$RC"
t setup-creates-the-group "groupadd --system crew" "$(grep '^groupadd ' "$SV_LOG")"
t setup-creates-the-account "useradd --system --gid crew --home-dir $CREW_DATA_DIR --no-create-home --shell /usr/sbin/nologin crew" "$(grep '^useradd ' "$SV_LOG")"
t setup-makes-the-data-dirs 3 "$(for d in "$CREW_DATA_DIR" "$CREW_DATA_DIR/fleets" "$CREW_DATA_DIR/state"; do [ -d "$d" ] && echo y; done | grep -c y)"
t setup-grants-with-default-caps 1 "$(grep -cE '^box grant --service crew --share crew --instances 6 --memory [0-9]+MiB --cpu [0-9]+$' "$SV_LOG")"
t setup-grants-before-starting 1 "$(awk '/^box grant/{g=NR} /^systemctl enable/{e=NR} END{print (g && e && g < e) ? 1 : 0}' "$SV_LOG")"
t setup-validates-the-rule 1 "$(grep -c '^visudo -cf ' "$SV_LOG")"
t setup-rule-is-the-cli-and-nothing-else "%crew ALL=(crew) NOPASSWD: $CLI" "$(grep -v '^#' "$CREW_SUDOERS_DIR/crew")"
t setup-writes-service-conf "CREW_SERVICE_USER=crew|CREW_SERVICE_GROUP=crew|CREW_SERVICE_CLI=$CLI|CREW_DATA_DIR=$CREW_DATA_DIR|CREW_UNIT_PREFIX=crew" "$(paste -sd'|' "$CREW_ETC_DIR/service.conf")"
t setup-writes-floor-env-with-a-password 1 "$(grep -cE '^CREW_FLOOR_PASS=[A-Za-z0-9]{12,}$' "$CREW_ETC_DIR/floor.env")"
t setup-floor-env-is-not-world-readable 640 "$(/usr/bin/stat -c %a "$CREW_ETC_DIR/floor.env")"
t setup-writes-seven-units 7 "$(find "$CREW_SYSTEMD_DIR" -name 'crew-*' -type f | grep -c .)"
t unit-tick-every-five-minutes 1 "$(grep -cx 'OnCalendar=\*:0/5' "$CREW_SYSTEMD_DIR/crew-tick.timer")"
t unit-timers-catch-up-missed-runs 3 "$(cat "$CREW_SYSTEMD_DIR"/crew-*.timer | grep -cx 'Persistent=true')"
t unit-restart-daily-04-10 1 "$(grep -cx 'OnCalendar=\*-\*-\* 04:10:00' "$CREW_SYSTEMD_DIR/crew-restart.timer")"
t unit-reset-sunday-05-10 1 "$(grep -cx 'OnCalendar=Sun \*-\*-\* 05:10:00' "$CREW_SYSTEMD_DIR/crew-reset.timer")"
t unit-jobs-run-as-the-account 3 "$(cat "$CREW_SYSTEMD_DIR"/crew-{tick,restart,reset}.service | grep -cx 'User=crew')"
t unit-tick-runs-the-cli "ExecStart=$CLI tick" "$(grep '^ExecStart=' "$CREW_SYSTEMD_DIR/crew-tick.service")"
t unit-restart-is-all "ExecStart=$CLI restart --all" "$(grep '^ExecStart=' "$CREW_SYSTEMD_DIR/crew-restart.service")"
t unit-skips-and-nothing-are-not-failures 3 "$(cat "$CREW_SYSTEMD_DIR"/crew-{tick,restart,reset}.service | grep -cx 'SuccessExitStatus=3 4')"
t unit-floor-reads-floor-env 1 "$(grep -cx "EnvironmentFile=$CREW_ETC_DIR/floor.env" "$CREW_SYSTEMD_DIR/crew-floor.service")"
t unit-floor-runs-as-the-account 1 "$(grep -cx 'User=crew' "$CREW_SYSTEMD_DIR/crew-floor.service")"
t setup-reloads-and-starts "systemctl daemon-reload|systemctl enable --now crew-floor.service crew-tick.timer crew-restart.timer crew-reset.timer" "$(grep '^systemctl' "$SV_LOG" | paste -sd'|' -)"
# #831: a crew server starts with no fleets — the floor's New fleet makes the first.
t setup-makes-no-fleet 0 "$(calls 'init --fleet')"
t setup-leaves-the-index-empty 0 "$(find "$CREW_DATA_DIR/fleets" -mindepth 1 | grep -c . || true)"
t setup-says-there-is-no-fleet-yet 1 "$(grep -c "^  fleets: none yet — the floor's New fleet makes the first$" <<<"$OUT")"
t setup-points-at-new-fleet 1 "$(grep -c 'then, in the floor: New fleet, its members in its Roster' <<<"$OUT")"
t setup-tells-the-next-steps 1 "$(grep -c 'sudo -u crew -H gh auth login' <<<"$OUT")"
PASS1="$(grep '^CREW_FLOOR_PASS=' "$CREW_ETC_DIR/floor.env")"

# --- setup again converges and changes nothing -----------------------------------------
: >"$SV_LOG"
OUT="$(CREW_SERVICE_ASSUME_ROOT=1 bash "$CLI" service setup --cli "$CLI" 2>&1)"; RC=$?
t setup-again-exits-0 0 "$RC"
t setup-again-creates-no-account 0 "$(calls '^useradd\|^groupadd')"
t setup-again-keeps-the-password "$PASS1" "$(grep '^CREW_FLOOR_PASS=' "$CREW_ETC_DIR/floor.env")"
t setup-again-changes-no-unit 7 "$(grep -c '  unit crew-.*: same$' <<<"$OUT")"
t setup-again-makes-no-fleet 0 "$(calls 'init --fleet')"
OUT="$(CREW_SERVICE_ASSUME_ROOT=1 bash "$CLI" service setup --cli "$CLI" --fleet main 2>&1)"; RC=$?
t setup-with-a-fleet-is-refused 1 "$RC"
t setup-with-a-fleet-makes-none 0 "$(find "$CREW_DATA_DIR/fleets" -mindepth 1 | grep -c . || true)"
: >"$SV_LOG"
CREW_SERVICE_ASSUME_ROOT=1 bash "$CLI" service setup --cli "$CLI" --instances 3 --memory 4GiB >/dev/null 2>&1
t setup-caps-are-flags "box grant --service crew --share crew --instances 3 --memory 4GiB" "$(grep '^box grant' "$SV_LOG")"
: >"$SV_LOG"
CREW_SERVICE_ASSUME_ROOT=1 bash "$CLI" service setup --cli "$CLI" --no-caps >/dev/null 2>&1
t setup-no-caps-grants-bare "box grant --service crew --share crew" "$(grep '^box grant' "$SV_LOG")"

# --- check -------------------------------------------------------------------------------
OUT="$(CREW_SERVICE_ASSUME_ROOT=1 bash "$CLI" service check 2>&1)"; RC=$?
t check-a-clean-service-is-0 0 "$RC"
t check-says-clean 1 "$(grep -cx 'service: clean' <<<"$OUT")"
printf '# hand edit\n' >>"$CREW_SYSTEMD_DIR/crew-tick.timer"
OUT="$(CREW_SERVICE_ASSUME_ROOT=1 bash "$CLI" service check 2>&1)"; RC=$?
t check-a-changed-unit-is-1 1 "$RC"
t check-names-the-unit 1 "$(grep -c 'DRIFT  unit crew-tick.timer is missing or changed' <<<"$OUT")"
CREW_SERVICE_ASSUME_ROOT=1 bash "$CLI" service setup --cli "$CLI" --no-caps >/dev/null 2>&1
OUT="$(SV_OWNER=root:root CREW_SERVICE_ASSUME_ROOT=1 bash "$CLI" service check 2>&1)"; RC=$?
t check-names-wrong-ownership 1 "$(grep -c "DRIFT  $CREW_DATA_DIR is not owned by crew:crew (root:root)" <<<"$OUT")"

# --- every other verb runs as the account ---------------------------------------------------
: >"$SV_LOG"
OUT="$(SV_GROUPS='operator crew' bash "$CLI" --fleet main up --dry-run 2>&1)"; RC=$?
t a-member-reruns-through-sudo "sudo -n -H -u crew -- $CLI --fleet main up --dry-run" "$(grep '^sudo ' "$SV_LOG")"
: >"$SV_LOG"
OUT="$(SV_GROUPS='operator crew' CREW_FLEET=main bash "$CLI" status 2>&1)"
t the-fleet-env-travels-as-a-flag "sudo -n -H -u crew -- $CLI --fleet main status" "$(grep '^sudo ' "$SV_LOG")"
: >"$SV_LOG"
OUT="$(bash "$CLI" status 2>&1)"; RC=$?
t a-non-member-is-refused 1 "$RC"
t a-non-member-is-told-the-group 1 "$(grep -c "operator is not in its group 'crew'" <<<"$OUT")"
t a-non-member-runs-nothing 0 "$(calls '^sudo\|^runuser')"
: >"$SV_LOG"
OUT="$(SV_ROOT=1 bash "$CLI" status 2>&1)"
t root-reruns-through-runuser "runuser -u crew -- env HOME=$CREW_DATA_DIR $CLI status" "$(grep '^runuser ' "$SV_LOG" | head -1)"
: >"$SV_LOG"
OUT="$(bash "$CLI" help 2>&1)"
t help-is-not-rerun 0 "$(calls '^sudo')"
t help-teaches-the-service 1 "$(grep -c 'sudo crew service setup' <<<"$OUT")"
: >"$SV_LOG"
OUT="$(SV_ME=crew bash "$CLI" up --dry-run 2>&1)"; RC=$?
t as-the-account-it-runs-here 0 "$(calls '^sudo\|^runuser')"
# #831: no fleet yet — nothing to plan, never the examples' members.
t no-fleet-up-dry-run-is-0 0 "$RC"
t no-fleet-up-dry-run-says-so 1 "$(grep -c "no fleet on this host yet — create one: the floor's New fleet, or crew init --fleet <id>" <<<"$OUT")"
t no-fleet-up-dry-run-plans-nothing 0 "$(grep -c 'would be created' <<<"$OUT" || true)"
OUT="$(SV_ME=crew bash "$CLI" tick 2>&1)"; RC=$?
t no-fleet-the-tick-has-nothing-to-do 4 "$RC"
t no-fleet-the-tick-says-so 1 "$(grep -c '^tick: no fleet on this host yet — nothing to walk' <<<"$OUT")"
OUT="$(SV_ME=crew bash "$CLI" hire x 2>&1)"; RC=$?
t no-fleet-an-acting-verb-refuses 1 "$RC"
t no-fleet-an-acting-verb-names-new-fleet 1 "$(grep -c "no fleet on this host yet — create one" <<<"$OUT")"
t no-fleet-never-the-examples-refusal 0 "$(grep -c 'shipped example' <<<"$OUT" || true)"
OUT="$(SV_ME=crew bash "$CLI" status 2>&1)"; RC=$?
t no-fleet-status-is-0 0 "$RC"
t no-fleet-status-reads-no-examples 0 "$(grep -c 'examples' <<<"$OUT" || true)"
SV_ME=crew bash "$CLI" init --fleet main >/dev/null 2>&1
t the-account-makes-the-first-fleet 1 "$([ -f "$CREW_DATA_DIR/fleets/main/fleet.roster" ] && echo 1 || echo 0)"
OUT="$(SV_ME=crew bash "$CLI" up --dry-run 2>&1)"; RC=$?
t as-the-account-it-reads-the-service-index 1 "$(grep -c '^up --dry-run: 0 would be created' <<<"$OUT")"

# --- teardown -------------------------------------------------------------------------------
: >"$SV_LOG"
OUT="$(CREW_SERVICE_ASSUME_ROOT=1 bash "$CLI" service teardown 2>&1)"; RC=$?
t teardown-exits-0 0 "$RC"
t teardown-stops-every-unit 7 "$(calls '^systemctl disable --now crew-')"
t teardown-removes-the-units 0 "$(find "$CREW_SYSTEMD_DIR" -name 'crew-*' -type f | grep -c . || true)"
t teardown-stops-before-revoking 1 "$(awk '/^systemctl disable/{d=NR} /^box revoke/{r=NR} END{print (d && r && d < r) ? 1 : 0}' "$SV_LOG")"
t teardown-revokes-the-grant "box revoke crew" "$(grep '^box revoke' "$SV_LOG")"
t teardown-removes-the-rule 0 "$([ -e "$CREW_SUDOERS_DIR/crew" ] && echo 1 || echo 0)"
t teardown-removes-service-conf 0 "$([ -e "$CREW_ETC_DIR/service.conf" ] && echo 1 || echo 0)"
t teardown-keeps-the-data 1 "$([ -f "$CREW_DATA_DIR/fleets/main/fleet.roster" ] && echo 1 || echo 0)"
t teardown-keeps-the-account 0 "$(calls '^userdel')"
OUT="$(bash "$CLI" --fleet main hire x 2>&1)"; RC=$?
t no-service-an-index-fixture-still-reads 0 "$(grep -c 'not in its group' <<<"$OUT")"
CREW_SERVICE_ASSUME_ROOT=1 bash "$CLI" service setup --cli "$CLI" --no-caps >/dev/null 2>&1
: >"$SV_LOG"
OUT="$(CREW_SERVICE_ASSUME_ROOT=1 bash "$CLI" service teardown --purge 2>&1)"; RC=$?
t teardown-purge-revokes-with-purge "box revoke crew --purge" "$(grep '^box revoke' "$SV_LOG")"
t teardown-purge-removes-account-and-group "userdel crew|groupdel crew" "$(grep -E '^(userdel|groupdel) ' "$SV_LOG" | paste -sd'|' -)"
t teardown-purge-removes-the-data 0 "$([ -e "$CREW_DATA_DIR" ] && echo 1 || echo 0)"

# --- a host with no service acts on nothing --------------------------------------------------
OUT="$(unset CREW_DATA_DIR; CREW_DATA_DIR="$TMP/nowhere" bash "$CLI" hire x 2>&1)"; RC=$?
t no-service-acting-verb-refuses 1 "$RC"
t no-service-names-service-setup 1 "$(grep -c 'sudo crew service setup' <<<"$OUT")"

suite_finish
