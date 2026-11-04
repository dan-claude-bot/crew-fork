#!/usr/bin/env bash
# shared/test/boot-gate.sh — standalone subject suite for shared/bin/duty.sh's
# once-per-boot gate (#609).
#
# Its own suite rather than a section of a neighbour's: the subject is
# shared/bin/duty.sh, and shared/test/common/ mirrors shared/lib/common/
# one-for-one (#507), so a boot-gate section in common/identity.sh would be the
# layout that split existed to end. #457 set the precedent for a new subject —
# its own suite, registered in SUITES in lib.sh.
#
# duty.sh is a script and not a sourceable module, so the gate is EXTRACTED
# from it by awk and run, exactly as common/identity.sh drives duty.sh's
# identity refusal block. A test-side copy of the block would pass against a
# reverted fix; this cannot.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=shared/test/lib.sh
source "$HERE/lib.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG
export XDG_CONFIG_HOME="$TMP/xdg-empty"
mkdir -p "$XDG_CONFIG_HOME"
export DUTY_DIR="$TMP"
export HOME="${HOME:-$TMP}"

DUTYSH="$SHARED/bin/duty.sh"

# The gate reads the kernel's boot id directly, so the fixture cannot choose
# it — it derives the same value the same way instead, and asserts against the
# eight characters the line is specified to carry.
BOOT_ID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"
BOOT8="${BOOT_ID:0:8}"

# --- the gate, extracted from production and driven -------------------------
# The range is the boot-id read through the branch's closing `fi`. If duty.sh
# ever stops carrying that block the extraction goes empty and every
# behavioural case below reds, which is the direction we want: a guard that
# cannot notice its subject left is not a guard.
GATE="$TMP/gate-block.sh"
awk '
  /^boot_id="\$\(cat \/proc\/sys\/kernel\/random\/boot_id/ { keep = 1 }
  keep { print }
  keep && /^fi$/ { exit }
' "$DUTYSH" >"$GATE"
t gate-block-extracted found \
  "$(grep -q 'boot check' "$GATE" && echo found || echo MISSING)"
# A here-string, not `tail | grep -q`: under pipefail that shape reds on the
# producer's SIGPIPE when grep exits early, and #449's guard reds on writing it
# at all.
t gate-block-is-the-whole-branch found \
  "$(grep -qx 'fi' <<<"$(tail -1 "$GATE")" && echo found || echo MISSING)"

# run_gate <dir> <probe-rc> -> the gate's stdout, i.e. what reaches duty.log
#
# Only the gate's two real dependencies are stubbed: `gh auth status` and
# bot_cli_probe are the round-trips it exists to pay, and a suite that made
# them is a suite nobody can run offline. log() and warn() are NOT stubbed —
# they are the subject. alert() is captured rather than curled.
run_gate() {  # run_gate <dir> <probe-rc>
  local dir="$1" probe_rc="$2" runner="$TMP/run-gate.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -uo pipefail'
    # shellcheck disable=SC2016  # writing literal fixture source
    printf '%s\n' 'source "$SHARED/lib/common.sh"'
    # shellcheck disable=SC2016  # writing literal fixture source
    printf '%s\n' 'alert() { printf "%s\n" "$*" >>"$DUTY_DIR/alerts"; }'
    printf '%s\n' 'hostname() { printf fixture; }'
    # The classifier report is a neighbour on this path with its own suite
    # (conf.sh) and its own once-per-boot marker; stubbed so a case here reds
    # for the boot gate's reason and never for its.
    printf '%s\n' 'report_profile_classifier_gaps() { :; }'
    printf '%s\n' "gh() { return $probe_rc; }"
    printf '%s\n' "bot_cli_probe() { return $probe_rc; }"
    cat "$GATE"
  } >"$runner"
  DUTY_DIR="$dir" WORK_DIR="$dir/work" TREES_DIR="$dir/trees" SHARED="$SHARED" \
    bash "$runner" 2>/dev/null
}

mk_dir() {  # mk_dir <name> -> a scratch DUTY_DIR
  local d="$TMP/$1"
  mkdir -p "$d/work"
  printf '%s' "$d"
}

# Count the EMISSION lines, matched on the two shapes and not on the "boot
# gate: " prefix: the degraded path's own `WARN: boot gate: auth probe failed`
# shares that prefix, and a counter that swept it in would read the degraded
# case as two boot lines and hide a genuine double-emission behind the noise.
# `log` stamps every line, so every assertion matches after the timestamp.
BOOT_SHAPES='boot gate: (new boot id|first tick on this box)'
boot_lines() { grep -cE "$BOOT_SHAPES" <<<"${1:-}" || true; }

# --- 1. .boot-id absent: the first-tick shape, and no restart claim ----------
D="$(mk_dir first-tick)"
out="$(run_gate "$D" 0)"
t first-tick-emits-one-line 1 "$(boot_lines "$out")"
t first-tick-names-the-first-tick-shape found \
  "$(grep -q "boot gate: first tick on this box (boot id $BOOT8)" <<<"$out" \
    && echo found || echo MISSING)"
t first-tick-claims-no-restart clean \
  "$(grep -q 'restarted' <<<"$out" && echo CLAIMED || echo clean)"
# The line is a log line like any other: one line, stamped, and nothing in it
# that probe.sh's `tr -d '\r'` would eat or that would split it into two
# records on the way to the floor's log view.
t first-tick-is-exactly-one-record 1 "$(grep -cE "$BOOT_SHAPES" <<<"$out" || true)"
t first-tick-carries-no-carriage-return clean \
  "$(grep -q $'\r' <<<"$out" && echo CR || echo clean)"
t first-tick-line-is-timestamped found \
  "$(grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z boot gate: ' <<<"$out" \
    && echo found || echo MISSING)"

# ...and the marker it just wrote silences the next tick within the same boot.
out2="$(run_gate "$D" 0)"
t second-tick-same-boot-is-silent 0 "$(boot_lines "$out2")"

# --- 2. .boot-id differs: the restart shape ---------------------------------
D="$(mk_dir restarted)"
printf 'e3b0c442-98fc-1c14-9afb-f4c8996fb924\n' >"$D/.boot-id"
out="$(run_gate "$D" 0)"
t restart-emits-one-line 1 "$(boot_lines "$out")"
t restart-names-the-restart-shape found \
  "$(grep -q "boot gate: new boot id $BOOT8 — the box restarted since the last tick" <<<"$out" \
    && echo found || echo MISSING)"
t restart-does-not-use-the-first-tick-shape clean \
  "$(grep -q 'first tick on this box' <<<"$out" && echo WRONG-SHAPE || echo clean)"
out2="$(run_gate "$D" 0)"
t restart-next-tick-same-boot-is-silent 0 "$(boot_lines "$out2")"

# --- 3. .boot-id matches: nothing at all ------------------------------------
D="$(mk_dir matched)"
printf '%s\n' "$BOOT_ID" >"$D/.boot-id"
out="$(run_gate "$D" 0)"
t matching-boot-id-is-silent 0 "$(boot_lines "$out")"

# MUST-FAIL: a patch that infers "rebooted" from a gap in duty.log rather than
# from boot_id. Ticks are five minutes apart and a reboot fits between two of
# them — the incident this issue closes did exactly that and left the log
# looking continuous. A stale duty.log and a stale marker mtime change nothing:
# the boot id is the only evidence, and it matches.
D="$(mk_dir matched-stale-log)"
printf '%s\n' "$BOOT_ID" >"$D/.boot-id"
{
  echo "2026-08-30T17:25:48Z post-once: verified on heavy-duty/box#256"
  echo "2026-08-30T17:30:42Z duty tick skipped: previous run still holds the lock"
} >"$D/duty.log"
touch -d '2026-08-30T17:30:42Z' "$D/duty.log" "$D/.boot-id" 2>/dev/null || true
out="$(run_gate "$D" 0)"
t stale-log-with-matching-boot-id-is-silent 0 "$(boot_lines "$out")"

# --- 4. an EMPTY marker is not a restart ------------------------------------
# What a truncated write leaves behind — and the incident that produced this
# issue corrupted two log files, so the shape is not hypothetical. The restart
# shape asserts that a previous boot id DIFFERED; with no bytes there is no
# such id, so the claim has no evidence and the box gets the first-tick shape.
D="$(mk_dir empty-marker)"
: >"$D/.boot-id"
out="$(run_gate "$D" 0)"
t empty-marker-emits-one-line 1 "$(boot_lines "$out")"
t empty-marker-claims-no-restart clean \
  "$(grep -q 'restarted' <<<"$out" && echo CLAIMED || echo clean)"
t empty-marker-uses-the-first-tick-shape found \
  "$(grep -q 'boot gate: first tick on this box' <<<"$out" && echo found || echo MISSING)"

# --- 5. the failing gate reports BOTH facts ---------------------------------
# MUST-FAIL: a patch that emits the line only on the success branch. The boot a
# degraded box just took is the one most worth reporting, and the operator who
# reads the degraded warn needs the line above it to say why the box is here.
D="$(mk_dir degraded)"
printf 'e3b0c442-98fc-1c14-9afb-f4c8996fb924\n' >"$D/.boot-id"
out="$(run_gate "$D" 1)"
t degraded-still-emits-the-boot-line 1 "$(boot_lines "$out")"
t degraded-emits-the-restart-shape found \
  "$(grep -q "boot gate: new boot id $BOOT8" <<<"$out" && echo found || echo MISSING)"
t degraded-still-warns found \
  "$(grep -q 'WARN: boot gate: auth probe failed' <<<"$out" && echo found || echo MISSING)"
# The boot line comes FIRST: the cause reads above the consequence, which is
# the whole reason this issue puts it in duty.log rather than in a quieter file.
t degraded-boot-line-precedes-the-warn ordered \
  "$(awk '/boot gate: new boot id/ { seen = 1 }
          /WARN: boot gate: auth probe failed/ { print seen ? "ordered" : "WARN-FIRST"; exit }' \
     <<<"$out")"
# ...and the marker stays unwritten, so the next tick re-checks (and re-reports).
t degraded-leaves-the-marker-unwritten 'e3b0c442-98fc-1c14-9afb-f4c8996fb924' \
  "$(cat "$D/.boot-id")"
out2="$(run_gate "$D" 1)"
t degraded-next-tick-reports-again 1 "$(boot_lines "$out2")"

# --- 6. boot-check.log is unchanged -----------------------------------------
# This adds a line to the stream operators read; it does not move or duplicate
# the boot check. The boot line must not appear in boot-check.log, and the
# block's own record must still be there, once per run of the gate.
D="$(mk_dir boot-check)"
run_gate "$D" 0 >/dev/null
t boot-check-log-still-written 1 \
  "$(grep -c '^== boot check ' "$D/boot-check.log" || true)"
t boot-check-log-does-not-carry-the-boot-line 0 \
  "$(grep -cE "$BOOT_SHAPES" "$D/boot-check.log" || true)"
t boot-check-log-keeps-the-df-line 1 \
  "$(grep -c 'cli probe: ' "$D/boot-check.log" || true)"

# --- 7. the line reaches the operator with no floor-side change -------------
# The criterion is that it needs none: probe.sh tails duty.log and `crew status`
# and the floor's log view read that tail. Asserted by crossing the boundary
# rather than by reasoning about it, because "it is just a log line" is exactly
# what would be said about a line that `tr -d '\r'` split or the tail dropped.
D="$(mk_dir probe-reach)"
printf 'crew@fixture\n' >"$D/VERSION"
run_gate "$D" 0 >"$D/duty.log"
PROBE_OUT="$(DUTY_DIR="$D" bash "$ROOT/fleet-floor/server/probe.sh" </dev/null 2>/dev/null)"
PROBE_LOG="$(awk '/^::logstart$/ { keep = 1; next } /^::logend$/ { exit } keep' <<<"$PROBE_OUT")"
t boot-line-survives-the-probe-tail 1 "$(boot_lines "$PROBE_LOG")"
t boot-line-is-whole-through-the-probe found \
  "$(grep -q "boot gate: first tick on this box (boot id $BOOT8)" <<<"$PROBE_LOG" \
    && echo found || echo MISSING)"
# It must ride the log stream, not become a ::key of its own: probe.sh's
# contract is one key per emitted field, and a boot line that reached the
# floor as a phantom key would be a floor-side change by another name.
t boot-line-adds-no-probe-key 0 \
  "$(grep -cE '^::boot' <<<"$PROBE_OUT" || true)"

# The 600-line tail is the reach limit the criterion names. One line per boot
# cannot be pushed out by its own emissions, but it must survive a busy tick's
# worth of traffic beneath it.
D="$(mk_dir probe-tail-depth)"
printf 'crew@fixture\n' >"$D/VERSION"
run_gate "$D" 0 >"$D/duty.log"
for _i in $(seq 1 500); do
  echo "2026-09-01T09:00:00Z duty tick skipped: previous run still holds the lock"
done >>"$D/duty.log"
# A here-string again, not `probe.sh | awk`: the awk below exits at ::logend
# and would SIGPIPE the producer under pipefail — #449's flake, in the shape
# the guard does not scan for because the early-exiting consumer is awk.
PROBE_OUT="$(DUTY_DIR="$D" bash "$ROOT/fleet-floor/server/probe.sh" </dev/null 2>/dev/null)"
PROBE_LOG="$(awk '/^::logstart$/ { keep = 1; next } /^::logend$/ { exit } keep' <<<"$PROBE_OUT")"
t boot-line-survives-500-lines-of-traffic 1 "$(boot_lines "$PROBE_LOG")"

# --- 8. wiring: the emission is inside the branch, above everything else -----
# Static, because the behavioural cases above would all still pass if the line
# were emitted from a second site the gate does not own. These are the
# assertions that make MOVING the fix red.
emit_ln="$(grep -n 'boot gate: first tick on this box' "$DUTYSH" | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016  # match the literal boot marker read in duty.sh
branch_ln="$(grep -n 'if \[ "\$(cat "\$DUTY_DIR/.boot-id"' "$DUTYSH" | head -1 | cut -d: -f1)"
check_ln="$(grep -n '"== boot check ' "$DUTYSH" | head -1 | cut -d: -f1)"
warn_ln="$(grep -n 'boot gate: auth probe failed' "$DUTYSH" | head -1 | cut -d: -f1)"
if [ -n "$emit_ln" ] && [ -n "$branch_ln" ] && [ -n "$check_ln" ] \
    && [ "$branch_ln" -lt "$emit_ln" ] && [ "$emit_ln" -lt "$check_ln" ]; then
  r1=inside
else
  r1="MISPLACED(branch=$branch_ln emit=$emit_ln check=$check_ln)"
fi
t emission-is-inside-the-branch-above-the-boot-check inside "$r1"
if [ -n "$emit_ln" ] && [ -n "$warn_ln" ] && [ "$emit_ln" -lt "$warn_ln" ]; then
  r1=above
else
  r1="BELOW(emit=$emit_ln warn=$warn_ln)"
fi
t emission-is-above-the-success-failure-branch above "$r1"
# Exactly one site per shape. A second emitter is how "one line per boot"
# quietly becomes two.
t restart-shape-has-one-emitter 1 \
  "$(grep -c 'the box restarted since the last tick' "$DUTYSH" || true)"
t first-tick-shape-has-one-emitter 1 \
  "$(grep -c 'boot gate: first tick on this box' "$DUTYSH" || true)"

# --- the memory gate (#761, #763 round 3) -----------------------------------
# Extracted the same way: the `.memory-pending` branch, from its `if` through
# its `fi`, run with the real log/warn and a scratch DUTY_DIR. The gate is a
# `exit 0` on hold, so the runner's rc is the verdict and its stdout the line.
MGATE="$TMP/memory-gate.sh"
awk '
  /^if \[ -e "\$DUTY_DIR\/\.memory-pending" \]; then$/ { keep = 1 }
  keep { print }
  keep && /^fi$/ { exit }
' "$DUTYSH" >"$MGATE"
t memory-gate-extracted found "$(grep -q 'duty tick skipped: .memory-pending stands' "$MGATE" && echo found || echo MISSING)"
run_mgate() {  # run_mgate <dir> [GRACE] -> stdout; $TMP/mgate.rc carries the rc
  local dir="$1" runner="$TMP/run-mgate.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -uo pipefail'
    # shellcheck disable=SC2016  # writing literal fixture source
    printf '%s\n' 'source "$SHARED/lib/common.sh"'
    cat "$MGATE"
    printf '%s\n' 'echo RAN'
  } >"$runner"
  # Called inside a command substitution, so the rc goes through a file.
  out="$(DUTY_DIR="$dir" WORK_DIR="$dir/work" SHARED="$SHARED" MEMORY_PENDING_GRACE_S="${2:-1800}" bash "$runner" 2>&1)"
  printf '%s\n' "$?" >"$TMP/mgate.rc"
  printf '%s' "$out"
}
D="$(mk_dir memory-pending)"
touch "$D/.memory-pending"
out="$(run_mgate "$D")"
t memory-gate-a-standing-marker-skips-the-tick 1 "$(grep -c 'duty tick skipped: .memory-pending stands' <<<"$out")"
t memory-gate-the-skip-is-exit-0-and-runs-nothing "0 0" "$(cat "$TMP/mgate.rc") $(grep -c '^RAN$' <<<"$out")"
t memory-gate-the-skip-keeps-the-marker present "$([ -e "$D/.memory-pending" ] && echo present || echo absent)"
# The grace counts from the marker, not from boot: a marker touched a moment
# ago on a box up for hours (the cut's own touch) is NOT expired by a grace the
# uptime already exceeds. This box has certainly been up more than two seconds.
out="$(run_mgate "$D" 2)"
t memory-gate-a-fresh-marker-is-not-aged-by-the-uptime 1 "$(grep -c 'duty tick skipped' <<<"$out")"
t memory-gate-the-fresh-marker-is-kept present "$([ -e "$D/.memory-pending" ] && echo present || echo absent)"
# A marker the checkpoint carried in predates the boot, so it ages with the
# uptime — and past the grace the box says so once and runs without it.
touch -d '2026-01-01T00:00:00Z' "$D/.memory-pending"
out="$(run_mgate "$D" 1)"
t memory-gate-a-carried-marker-past-the-grace-runs 1 "$(grep -c '^RAN$' <<<"$out")"
t memory-gate-the-expiry-is-said-once-as-a-warning 1 "$(grep -c 'WARN: memory restore did not arrive within 1s; this box runs without its ledgers from here' <<<"$out")"
t memory-gate-the-expired-marker-is-lifted absent "$([ -e "$D/.memory-pending" ] && echo present || echo absent)"
out="$(run_mgate "$D" 1)"
t memory-gate-without-the-marker-nothing-is-said "1 0" "$(grep -c '^RAN$' <<<"$out") $(grep -c 'memory' <<<"$out")"

suite_finish
