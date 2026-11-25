# shellcheck shell=bash
# drill/rehearsal-armed-self.sh — the round makes its own armed, ticking,
# clock-skewed box for the app-armed pass (#789, operator ruling: option 1).
#
# The agreement criterion (#494, drill/agreement.sh) counts a box only when it
# is armed, its last tick is fresh, and the host-minus-box clock delta is
# larger than the probe's own uncertainty. A drill's boxes are disarmed by
# design (rehearsal_disarm_cron) and a VM's clock is synced by chrony, so no
# round could ever present one, and the leg read INCOMPLETE on every round.
# Rather than relax the criterion, the round supplies the condition, for the
# length of one pass, on one of its own boxes:
#
#   1. ARM its cron with the line install.sh --arm-cron writes. The box's
#      repos.txt names its own sandbox only (drill/rehearsal.sh), so a */5
#      tick inside the window works nothing but that sandbox.
#   2. SKEW its clock: chrony stopped and the clock moved ARMED_SELF_SKEW_S
#      ahead, as root through `box incus … exec` (the tenant has no sudo — box
#      #177 — and root is the host's, by its Incus socket).
#   3. TICK it once, explicitly, so the tick is fresh on the skewed clock.
#
# and then puts back what it changed, whatever the pass did: cron disarmed
# (the same filter rehearsal_disarm_cron applies) once it was armed; the clock
# set to the host's and chrony started once it was moved; and each read back.
#
# The transport is `box` (ARMED_SELF_BOX_CMD overrides it, for a suite's stub).
# armed_self_prepare runs in the CALLER's shell, never in `$(…)`: the stage it
# reached (ARMED_SELF_STAGE) is what armed_self_restore undoes, so a box the
# round never touched is not "restored" into a state it was never in.

ARMED_SELF_SKEW_S="${ARMED_SELF_SKEW_S:-120}"
# The restored clock must agree with the host's within this many seconds.
ARMED_SELF_RESYNC_TOLERANCE_S="${ARMED_SELF_RESYNC_TOLERANCE_S:-5}"
ARMED_SELF_STAGE=0   # 0 untouched · 1 cron armed · 2 clock moved
# shellcheck disable=SC2034  # the caller's to read: what prepare did, or why not
ARMED_SELF_WHY=""

armed_self_box() { "${ARMED_SELF_BOX_CMD:-box}" "$@"; }
# As the agent (#792): box_in's door, unless a fixture supplies the transport.
armed_self_bx() {
  if [ -n "${ARMED_SELF_BOX_CMD:-}" ] || ! declare -F box_in >/dev/null; then
    armed_self_box exec "$1" -- bash -lc "$2" </dev/null
  else
    box_in "$1" -- bash -lc "$2" </dev/null
  fi
}
armed_self_root() { armed_self_box incus "$1" -- exec "{}" -- bash -c "$2" </dev/null 2>/dev/null; }

# armed_self_clock_delta BOX — host minus box, in whole seconds; nothing when
# the box did not answer a number.
armed_self_clock_delta() {
  local before after guest
  before="$(date +%s)"
  guest="$(armed_self_bx "$1" 'date +%s' 2>/dev/null | tr -d '\r' | tail -1)"
  after="$(date +%s)"
  case "$guest" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$(( (before + after) / 2 - guest ))"
}

# armed_self_cron_armed BOX — rc 0 when the box's crontab carries the tick.
armed_self_cron_armed() {
  # shellcheck disable=SC2016  # $HOME expands in the box
  armed_self_bx "$1" 'out=$(crontab -l 2>/dev/null); grep -qF "$HOME/duty/bin/tick.sh" <<<"$out"' >/dev/null 2>&1
}

# armed_self_prepare BOX — arm, skew, tick. rc 0 with the box presenting the
# state; rc 1 otherwise. ARMED_SELF_WHY says which, ARMED_SELF_STAGE how far.
armed_self_prepare() {
  local box="$1" delta
  ARMED_SELF_STAGE=0 ARMED_SELF_WHY=""
  # shellcheck disable=SC2016  # $HOME and the crontab pipe expand in the box
  armed_self_bx "$box" '{ crontab -l 2>/dev/null | grep -vF "$HOME/duty/bin/tick.sh" || true; echo "*/5 * * * * $HOME/duty/bin/tick.sh"; } | crontab -' >/dev/null 2>&1 || true
  # Read back rather than trusted: the write's rc says nothing about the table.
  if ! armed_self_cron_armed "$box"; then
    ARMED_SELF_WHY="could not arm $box's cron"; return 1
  fi
  ARMED_SELF_STAGE=1
  armed_self_root "$box" "{ systemctl stop chrony 2>/dev/null || systemctl stop chronyd 2>/dev/null || true; } && date -s @\$(( \$(date +%s) + $ARMED_SELF_SKEW_S )) >/dev/null" || true
  # Anything the root call reached may have moved the clock: undone either way.
  ARMED_SELF_STAGE=2
  delta="$(armed_self_clock_delta "$box")"
  case "$delta" in
    -*) [ "${delta#-}" -ge $((ARMED_SELF_SKEW_S / 2)) ] \
          || { ARMED_SELF_WHY="$box's clock did not move (host minus box: ${delta}s)"; return 1; } ;;
    *) ARMED_SELF_WHY="$box's clock did not move as root (box incus $box -- exec {} -- …; host minus box: ${delta:-unread}s)"; return 1 ;;
  esac
  # shellcheck disable=SC2016  # $HOME expands in the box
  if ! armed_self_bx "$box" '"$HOME"/duty/bin/tick.sh' >/dev/null 2>&1; then
    ARMED_SELF_WHY="$box's explicit tick did not run"; return 1
  fi
  # shellcheck disable=SC2034  # read by the caller (rehearsal-all.sh)
  ARMED_SELF_WHY="$(printf '%s armed, clock %+ds, ticked' "$box" "$((-delta))")"
}

# armed_self_restore BOX — undo what ARMED_SELF_STAGE says was done, and read
# each back. Prints one line; rc 1 names what did not come back.
armed_self_restore() {
  local box="$1" bad="" delta=""
  if [ "$ARMED_SELF_STAGE" -eq 0 ]; then
    echo "$box untouched: nothing to restore"; return 0
  fi
  # shellcheck disable=SC2016  # $HOME and the crontab pipe expand in the box
  armed_self_bx "$box" 'tmp=$(mktemp); crontab -l 2>/dev/null | grep -vF "$HOME/duty/bin/tick.sh" >"$tmp" || true; crontab "$tmp"; rc=$?; rm -f "$tmp"; exit $rc' >/dev/null 2>&1 || true
  if armed_self_cron_armed "$box"; then
    bad="${bad}${bad:+; }its cron is STILL armed"
  fi
  if [ "$ARMED_SELF_STAGE" -ge 2 ]; then
    # Set to the HOST's clock, not "back by the skew": whatever prepare got
    # to, the host's time is the one the box must end on; chrony keeps it.
    armed_self_root "$box" "date -s @$(date +%s) >/dev/null; systemctl start chrony 2>/dev/null || systemctl start chronyd 2>/dev/null || true" || true
    delta="$(armed_self_clock_delta "$box")"
    if [ -z "$delta" ] || [ "${delta#-}" -gt "$ARMED_SELF_RESYNC_TOLERANCE_S" ]; then
      if [ -n "$delta" ]; then
        bad="${bad}${bad:+; }its clock is ${delta}s off the host's"
      else
        bad="${bad}${bad:+; }its clock could not be read"
      fi
    fi
  fi
  if [ -n "$bad" ]; then
    echo "$box was NOT fully restored: $bad — repair: box incus $box -- exec {} -- bash -c 'systemctl start chrony; chronyc -a makestep', and remove the tick.sh line from its crontab (box exec $box -- crontab -e)"
    return 1
  fi
  ARMED_SELF_STAGE=0
  echo "$box restored: cron disarmed${delta:+, clock back on the host clock (host minus box: ${delta}s)}"
}
