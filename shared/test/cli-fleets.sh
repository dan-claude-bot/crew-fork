#!/usr/bin/env bash
# shared/test/cli-fleets.sh — several fleets on one host (#814) and the
# one-member `crew up <box>` the floor's Create runs (#815), offline.
#
# The host is a shim: `box` answers a fixed inventory and logs every call, `gh`
# answers one board. Two fleet definitions sit where the CLI looks for them —
# two fleets in the service's index (`dev` and `lf`, under a fixture data dir)
# (~/.config/crew/fleets/lf) — and every row reads what the CLI printed and
# which box calls it made.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=shared/test/lib.sh
source "$HERE/lib.sh"
CLI="$ROOT/cli/crew"
# shellcheck source=shared/lib/platform.sh
source "$ROOT/shared/lib/platform.sh"
export CREW_PLATFORM_BOX_MIN
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG
unset CREW_FLEET CREW_FLEETS_DIR CREW_ROSTER CREW_FLOOR_STORE CREW_FLEET_WALK
# Empty at the start, as every suite's is; the fleets below are made in it.
export XDG_CONFIG_HOME="$TMP/xdg-empty"
export CREW_HOST_STATE_DIR="$TMP/hoststate"
SHIM="$TMP/shim"; STATE="$TMP/state"
mkdir -p "$XDG_CONFIG_HOME" "$SHIM" "$STATE"
export CF_STATE="$STATE"

# The host: alpha and beta (the dev fleet's) and floor1 exist; floor2 does
# not. A box's state is <box>.state (running when absent).
cat >"$SHIM/box" <<'EOF'
#!/usr/bin/env bash
set -u
cmd="${1:-}"; shift || true
printf '%s %s\n' "$cmd" "${1:-}" >>"$CF_STATE/calls"
boxes="alpha beta floor1 ${CF_EXTRA_BOXES:-}"
state_of() { cat "$CF_STATE/$1.state" 2>/dev/null || echo running; }
case "$cmd" in
  --version|-V) printf 'box %s (/opt/box/versions/%s)\n' "$CREW_PLATFORM_BOX_MIN" "$CREW_PLATFORM_BOX_MIN" ;;
  list)
    if [ "${1:-}" = --json ]; then
      printf '['; sep=""
      for n in $boxes; do printf '%s{"name":"%s","state":"%s"}' "$sep" "$n" "$(state_of "$n")"; sep=,; done
      printf ']\n'
    else printf 'NAME\n'; printf '%s\n' $boxes; fi ;;
  info)
    case " $boxes " in *" $1 "*) printf '[{"name":"%s","status":"%s"}]\n' "$1" "$(state_of "$1")" ;; *) exit 1 ;; esac ;;
  start) echo running >"$CF_STATE/$1.state" ;;
  exec) exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$SHIM/box"
cat >"$SHIM/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "issue list") printf 'I 14 2026-10-23T08:00:00Z needs-triage -\n' ;;
  "pr list") : ;;
  "api graphql") : ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$SHIM/gh"
export PATH="$SHIM:$PATH"
crew() { bash "$CLI" "$@"; }
capture() { OUT="$(crew "$@" 2>&1)"; RC=$?; }
calls() { grep -c "^$1" "$STATE/calls" 2>/dev/null || true; }
FLEETS="$TMP/data/fleets"
export CREW_DATA_DIR="$TMP/data" CREW_ETC_DIR="$TMP/etc"

# --- init --fleet: a new, EMPTY fleet in the index ----------------------------
capture init --fleet lf
t init-fleet-exits-0 0 "$RC"
t init-fleet-names-the-directory 1 "$(grep -c "initialized fleet 'lf': $FLEETS/lf (no members yet)" <<<"$OUT")"
t init-fleet-roster-has-no-member 0 "$(grep -cvE '^[[:space:]]*(#|$)' "$FLEETS/lf/fleet.roster")"
t init-fleet-roster-keeps-the-header 1 "$([ -s "$FLEETS/lf/fleet.roster" ] && echo 1 || echo 0)"
t init-fleet-repos-is-the-shipped-empty-one "$(cat "$ROOT/examples/repos.txt")" "$(cat "$FLEETS/lf/repos.txt")"
cf_have=0; for cf_f in fleet.conf repos.txt notify-repos.txt doctrine.conf; do [ ! -f "$FLEETS/lf/$cf_f" ] || cf_have=$((cf_have + 1)); done
t init-fleet-carries-the-whole-definition 4 "$cf_have"
capture init --fleet lf
t init-fleet-refuses-an-existing-fleet 1 "$RC"
t init-fleet-refusal-names-it 1 "$(grep -c "refusing to overwrite existing fleet 'lf'" <<<"$OUT")"
capture init --fleet Bad_Id
t init-fleet-bad-id-is-2 2 "$RC"
capture init --fleet ok "$TMP/somewhere"
t init-fleet-takes-no-directory 2 "$RC"
capture --fleet
t fleet-flag-needs-a-value 2 "$RC"

# --- one fleet on the host is selected; the caller's home is never read (#822) ----
printf 'floor1 claude triage\nfloor2 claude triage\n' >>"$FLEETS/lf/fleet.roster"
mkdir -p "$XDG_CONFIG_HOME/crew"; cp "$ROOT"/examples/{fleet.conf,repos.txt} "$XDG_CONFIG_HOME/crew/"
printf 'homeonly claude builder\n' >"$XDG_CONFIG_HOME/crew/fleet.roster"
capture up --dry-run
t one-fleet-host-resolves-it 1 "$(grep -c '^floor1: WOULD' <<<"$OUT")"
t one-fleet-host-is-not-the-examples 0 "$(grep -c 'NO operator fleet definition' <<<"$OUT")"
t the-callers-home-config-is-never-read 0 "$(grep -c '^homeonly' <<<"$OUT")"
capture init
t plain-init-needs-a-directory 2 "$RC"
t plain-init-names-the-fleet-form 1 "$(grep -c 'crew init --fleet <id>' <<<"$OUT")"

# --- a second fleet: dev, with alpha and beta --------------------------------------
capture init --fleet dev
printf 'alpha claude builder\nbeta codex reviewer\n' >>"$FLEETS/dev/fleet.roster"

# --- selection: --fleet anywhere, --fleet=, CREW_FLEET ----------------------------
capture up --dry-run
t several-fleets-and-none-named-is-2 2 "$RC"
t several-fleets-are-named 1 "$(grep -c '2 fleets on this host (dev lf): name one with --fleet <id>' <<<"$OUT")"
capture --fleet dev up --dry-run
t fleet-dev-is-dev 1 "$(grep -c '^alpha: ' <<<"$OUT")"
t fleet-dev-reads-no-lf-member 0 "$(grep -c '^floor' <<<"$OUT")"
capture --fleet lf up --dry-run
t fleet-before-the-verb-selects-it "2 0" "$(grep -oE '^floor[12]: ' <<<"$OUT" | sort -u | grep -c .) $(grep -c '^alpha' <<<"$OUT")"
capture up --dry-run --fleet lf
t fleet-after-the-verb-selects-it 2 "$(grep -oE '^floor[12]: ' <<<"$OUT" | sort -u | grep -c .)"
capture up --dry-run --fleet=lf
t fleet-equals-form-selects-it 2 "$(grep -oE '^floor[12]: ' <<<"$OUT" | sort -u | grep -c .)"
OUT="$(CREW_FLEET=lf bash "$CLI" up --dry-run 2>&1)"
t crew-fleet-env-selects-it 2 "$(grep -oE '^floor[12]: ' <<<"$OUT" | sort -u | grep -c .)"
OUT="$(CREW_FLEET=lf bash "$CLI" --fleet dev up --dry-run 2>&1)"
t fleet-flag-beats-the-env 1 "$(grep -c '^alpha: ' <<<"$OUT")"
capture --fleet nope up --dry-run
t unknown-fleet-is-1 1 "$RC"
t unknown-fleet-says-how-to-make-it 1 "$(grep -c "no fleet 'nope' in $FLEETS .*crew init --fleet nope" <<<"$OUT")"
capture --fleet NOPE up --dry-run
t invalid-fleet-id-is-2 2 "$RC"

# --- crew up <box>: one member, and only it ---------------------------------------
capture --fleet lf up floor2 --dry-run
t up-box-plans-that-member "1 1" "$(grep -c '^floor2: WOULD create' <<<"$OUT") $(grep -c '^floor2: WOULD hire' <<<"$OUT")"
t up-box-plans-no-other-member 0 "$(grep -c '^floor1' <<<"$OUT")"
t up-box-summary-counts-one 1 "$(grep -c '^up --dry-run: 1 would be created, 0 started, 1 hired$' <<<"$OUT")"
capture --fleet lf up --dry-run floor2
t up-box-in-either-order 1 "$(grep -c '^floor2: WOULD create' <<<"$OUT")"
capture --fleet lf up alpha --dry-run
t up-box-refuses-a-non-member 1 "$RC"
t up-box-refusal-names-the-roster 1 "$(grep -c "'alpha' is not a member of this fleet's roster" <<<"$OUT")"
capture --fleet lf up floor1 floor2
t up-box-takes-one-member 2 "$RC"
echo stopped >"$STATE/floor1.state"; : >"$STATE/calls"
capture --fleet lf up floor1
t up-box-starts-only-that-member "1 0 0" "$(calls 'start floor1') $(calls 'start alpha') $(calls 'new ')"
t up-box-off-roster-list-names-the-owning-fleet 1 "$(grep -cx '  alpha  (fleet dev)' <<<"$OUT")"
rm -f "$STATE/floor1.state"

# --- a box belongs to exactly one fleet --------------------------------------------
printf 'alpha claude builder\n' >>"$FLEETS/lf/fleet.roster"
capture --fleet lf up --dry-run
t foreign-box-dry-run-would-refuse 1 "$(grep -c "^alpha: WOULD REFUSE — fleet 'dev' on this host already lists it" <<<"$OUT")"
t foreign-box-dry-run-plans-nothing-for-it 0 "$(grep -c '^alpha: WOULD hire' <<<"$OUT")"
: >"$STATE/calls"
capture --fleet lf up alpha
t foreign-box-up-is-1 1 "$RC"
t foreign-box-up-says-refused 1 "$(grep -c "^alpha: REFUSED — fleet 'dev' on this host already lists it" <<<"$OUT")"
t foreign-box-up-touches-nothing "0 0" "$(calls 'start alpha') $(calls 'new alpha')"
capture --fleet lf hire alpha
t foreign-box-hire-is-1 1 "$RC"
t foreign-box-hire-names-the-fleet 1 "$(grep -c "crew hire refuses alpha: fleet 'dev' on this host already lists it" <<<"$OUT")"
capture --fleet lf hire-all
t foreign-box-hire-all-refuses-it 1 "$(grep -c "^alpha: REFUSED — fleet 'dev'" <<<"$OUT")"
# Symmetric: once a hand edit puts a box in two rosters, NEITHER fleet may hire
# it — the dev fleet is refused naming lf, as lf was refused naming it.
capture --fleet dev hire alpha
t two-rosters-refuse-from-both-sides 1 "$(grep -c "crew hire refuses alpha: fleet 'lf' on this host already lists it" <<<"$OUT")"
sed -i '/^alpha /d' "$FLEETS/lf/fleet.roster"

# --- the host schedule walks every fleet --------------------------------------------
capture tick --dry-run
t walk-tick-visits-the-dev-fleet 1 "$(grep -c "^== fleet dev ($FLEETS/dev)$" <<<"$OUT")"
t walk-tick-visits-the-index-fleet 1 "$(grep -c "^== fleet lf ($FLEETS/lf)$" <<<"$OUT")"
t walk-tick-runs-one-tick-per-fleet 2 "$(grep -c '^tick: started' <<<"$OUT")"
capture --fleet lf tick --dry-run
t an-explicit-fleet-is-not-walked 0 "$(grep -c '^== fleet' <<<"$OUT")"
OUT="$(CREW_CONFIG_DIR="$FLEETS/lf" bash "$CLI" tick --dry-run 2>&1)"
t an-explicit-config-dir-is-not-walked 0 "$(grep -c '^== fleet' <<<"$OUT")"
capture restart nosuchbox
t restart-without-all-is-not-walked 0 "$(grep -c '^== fleet' <<<"$OUT")"
echo 'HOST_SCHEDULE=off' >>"$FLEETS/dev/fleet.conf"
capture tick --dry-run
t walk-skips-a-fleet-off-the-schedule 1 "$(grep -c '^== fleet dev: off the host schedule (HOST_SCHEDULE=off in ' <<<"$OUT")"
t walk-off-the-schedule-runs-no-tick-there 1 "$(grep -c '^tick: started' <<<"$OUT")"
capture --fleet dev tick --dry-run
t an-explicit-fleet-runs-even-off-the-schedule 1 "$(grep -c '^tick: started' <<<"$OUT")"
sed -i '/^HOST_SCHEDULE=off$/d' "$FLEETS/dev/fleet.conf"

# --- the host-wide running cap -------------------------------------------------------
# alpha and beta (dev) run; lf's triage member floor1 is stopped and the
# board gives triage a reason to wake. The host cap defaults to the fleet cap
# (2): floor1 is held by the host, not by its own fleet (0 of 2 running there).
echo o/r >"$FLEETS/lf/repos.txt"
echo stopped >"$STATE/floor1.state"
sed -i '/^floor2 /d' "$FLEETS/lf/fleet.roster"
capture --fleet lf tick --dry-run
t host-line-counts-the-other-fleets 1 "$(grep -c '^  host: 0 running in this fleet, 2 in the host.s other fleets (host cap 2)$' <<<"$OUT")"
t host-cap-holds-the-member 1 "$(grep -c '^  floor1: held — host cap: 2 of 2 boxes running across the host.s fleets; why=' <<<"$OUT")"
echo 'HOST_MAX_RUNNING=3' >>"$FLEETS/lf/fleet.conf"
capture --fleet lf tick --dry-run
t host-cap-raised-starts-it 1 "$(grep -c '^  floor1: starting why=' <<<"$OUT")"
t host-cap-raised-is-said 1 "$(grep -c '(host cap 3)$' <<<"$OUT")"
echo paused >"$TMP/p"; mkdir -p "$FLEETS/dev/store/paused"; : >"$FLEETS/dev/store/paused/alpha"
sed -i '/^HOST_MAX_RUNNING=3$/d' "$FLEETS/lf/fleet.conf"
capture --fleet lf tick --dry-run
# A box another fleet's operator holds counts while it still holds its memory
# — running, as this fleet's own count reads it (#898) — and not once stopped.
t host-cap-a-held-box-elsewhere-still-running-counts 1 "$(grep -c '2 in the host.s other fleets (host cap 2)$' <<<"$OUT")"
echo stopped >"$STATE/alpha.state"
capture --fleet lf tick --dry-run
t host-cap-a-held-box-elsewhere-once-stopped-does-not-count 1 "$(grep -c '1 in the host.s other fleets (host cap 2)$' <<<"$OUT")"
rm -f "$STATE/alpha.state"

suite_finish
