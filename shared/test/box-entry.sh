#!/usr/bin/env bash
# shellcheck disable=SC2016  # the single-quoted scripts run in the child shells this suite starts
# shared/test/box-entry.sh — the one door into a box (#792), offline.
#
# box 0.11.0 enters a box as ROOT unless `--user NAME` names someone, and
# creates no users. crew reads the host's box version once, and every
# agent-side call goes through box_in: `box exec --user <agent> <box> -- …` on
# 0.11.0 and later, today's `box exec <box> -- …` before it, and a refusal
# when the version cannot be read. This suite drives the library, the mint,
# every CLI verb that enters a box, and the floor's Python door against a stub
# `box` that records every argv and answers `--version` per case.
#
# THE GUARD THAT MATTERS IS THE ARGV GREP. Each verb below is run in both
# modes, and every `box exec` it issued is read back: in user mode each one
# must carry `--user` and the agent the roster names for THAT box, in stamp
# mode none may. A verb that issued no exec at all fails its row too, so a
# verb that silently stopped reaching the box cannot pass as compliant.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=shared/test/lib.sh
source "$HERE/lib.sh"
CLI="$ROOT/cli/crew"
TMP="$(mktemp -d)"
trap '[ -n "${BE_KEEP:-}" ] || rm -rf "$TMP"' EXIT
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG
unset CREW_ROSTER
unset CREW_FLOOR_STORE CREW_MODEL_PRICES
export XDG_CONFIG_HOME="$TMP/xdg-empty"
mkdir -p "$XDG_CONFIG_HOME"

CONF="$TMP/conf"; SHIM="$TMP/shim"; STATE="$TMP/state"
mkdir -p "$CONF" "$SHIM" "$STATE"
cp "$ROOT/examples/fleet.conf" "$ROOT/examples/repos.txt" \
  "$ROOT/examples/notify-repos.txt" "$ROOT/examples/doctrine.conf" "$CONF/"
# Two boxes on two different agents, so "the agent of THAT box" is checkable,
# and a third that is in the roster but not on the host, for the mint. The
# host also carries `stranger`, on no roster row, for the ad-hoc hire.
cat >"$CONF/fleet.roster" <<'EOF'
alpha claude builder
beta  codex  reviewer
gamma claude triage
EOF

# The stub `box`. BE_BOX_VERSION is what `--version` reports (empty: nothing at
# all). Every exec is recorded as the words BEFORE `--`, which is exactly the
# part of the argv this issue is about. In user mode the stub behaves as box
# 0.11.0 does: a --user the guest lacks (here: anyone but the roster's agent)
# refuses with 2. BE_ROOT_RC fails the converge door.
cat >"$SHIM/box" <<'EOF'
#!/usr/bin/env bash
set -u
S="$BE_STATE"
cmd="${1:-}"; shift || true
case "$cmd" in
  --version|-V)
    printf 'version\n' >>"$S/calls"
    [ -z "${BE_BOX_VERSION:-}" ] || printf 'box %s (/opt/box/versions/%s)\n' "$BE_BOX_VERSION" "$BE_BOX_VERSION"
    ;;
  list)
    printf 'list\n' >>"$S/calls"
    if [ "${1:-}" = --json ]; then
      printf '[{"name":"alpha","status":"Running"},{"name":"beta","status":"Running"},{"name":"stranger","status":"Running"}]\n'
    else
      printf 'NAME\nalpha\nbeta\nstranger\n'
    fi
    ;;
  info)
    printf 'info %s\n' "${1:-}" >>"$S/calls"
    case "${1:-}" in
      alpha|beta|stranger) printf '[{"name":"%s","status":"Running"}]\n' "$1" ;;
      *) printf '[]\n' ;;
    esac
    ;;
  exec)
    pre=()
    while [ $# -gt 0 ] && [ "$1" != -- ]; do pre+=("$1"); shift; done
    shift || true
    printf 'exec %s\n' "${pre[*]}" >>"$S/execs"
    cat >/dev/null 2>&1 || true
    if [ "${pre[0]:-}" = --user ]; then
      want="$(awk -v n="${pre[2]:-}" '$1 == n { print $2; exit }' "$BE_ROSTER")"
      [ -n "${pre[1]:-}" ] && [ "${pre[1]}" = "$want" ] \
        || { echo "box: no user '${pre[1]:-}' in ${pre[2]:-}" >&2; exit 2; }
    fi
    script="${*: -1}"
    case "$script" in
      *'gh auth status'*) exit 0 ;;
      *bot_cli_probe*) exit 0 ;;
    esac
    exit 0
    ;;
  new)
    printf 'new %s\n' "$*" >>"$S/calls"
    ;;
  root)
    printf 'root %s\n' "${1:-}" >>"$S/calls"
    cat >/dev/null
    exit "${BE_ROOT_RC:-0}"
    ;;
  *)
    printf '%s %s\n' "$cmd" "$*" >>"$S/calls"
    ;;
esac
EOF
chmod +x "$SHIM/box"
export BE_STATE="$STATE" BE_ROSTER="$CONF/fleet.roster"

reset_state() { rm -f "$STATE/calls" "$STATE/execs"; : >"$STATE/calls"; : >"$STATE/execs"; }
execs() { cat "$STATE/execs" 2>/dev/null; }
version_reads() { grep -c '^version$' "$STATE/calls" 2>/dev/null || true; }

# --- 1. the version table ------------------------------------------------
# shellcheck source=shared/lib/box-entry.sh
source "$ROOT/shared/lib/box-entry.sh"
for row in 0.10.0:stamp 0.10.1:stamp 0.10.1-dev:stamp 0.9.9:stamp \
           0.11.0:user 0.11.0-rc1:user 0.11.0-dev:user 0.11.3:user 0.12.0:user 1.0.0:user; do
  t "box-entry-mode-of-${row%%:*}" "${row##*:}" "$(box_entry_mode_of "${row%%:*}")"
done
for junk in "" unknown 0.11 v0.11.0 "0.11.0 extra"; do
  box_entry_mode_of "$junk" >/dev/null; rc=$?
  t "box-entry-mode-of-refuses-'$junk'" 2 "$rc"
done

# --- 2. the library, in this shell ----------------------------------------
# lib_case VERSION — a fresh process with the stub first on PATH and the
# roster in CREW_ROSTER, so the library resolves agents the operator's way.
lib_case() { # VERSION SCRIPT
  reset_state
  BE_BOX_VERSION="$1" PATH="$SHIM:$PATH" CREW_ROSTER="$CONF/fleet.roster" \
    bash -c "source '$ROOT/shared/lib/box-entry.sh'; $2" 2>&1 </dev/null
}

out="$(lib_case 0.10.1 'box_in alpha -- true; box_in beta -- true; box_in alpha -- true')"
t lib-stamp-argv-is-today-s "exec alpha
exec beta
exec alpha" "$(execs)"
t lib-reads-the-version-once-per-process 1 "$(version_reads)"

out="$(lib_case 0.11.0 'box_in alpha -- true; box_in beta -- true; box_in alpha -- true')"
t lib-user-argv-names-each-box-s-agent "exec --user claude alpha
exec --user codex beta
exec --user claude alpha" "$(execs)"
t lib-user-reads-the-version-once 1 "$(version_reads)"

out="$(lib_case 0.11.0-rc1 'box_in alpha -- true')"
t lib-rc-is-user-mode "exec --user claude alpha" "$(execs)"

out="$(lib_case "" 'box_in alpha -- true; echo "rc=$?"')"
t lib-unreadable-refuses-rc2 1 "$(grep -cx 'rc=2' <<<"$out")"
t lib-unreadable-names-box-version 1 "$(grep -c "'box --version' answered 'nothing'" <<<"$out")"
t lib-unreadable-enters-nothing "" "$(execs)"

out="$(lib_case 0.11.0 'box_in stranger -- true; echo "rc=$?"')"
t lib-user-no-roster-row-refuses 1 "$(grep -cx 'rc=2' <<<"$out")"
t lib-user-no-roster-row-says-why 1 "$(grep -c 'stranger has no roster row naming its agent' <<<"$out")"
t lib-user-no-roster-row-enters-nothing "" "$(execs)"

out="$(lib_case 0.10.1 'box_in stranger -- true; echo "rc=$?"')"
t lib-stamp-off-roster-is-today-s "exec stranger" "$(execs)"

out="$(lib_case 0.11.0 'box_entry_bind stranger kimi; box_in stranger -- true')"
t lib-a-binding-names-an-off-roster-agent "exec --user kimi stranger" "$(execs)"
out="$(lib_case 0.11.0 'box_entry_bind alpha grok; box_in alpha -- true')"
t lib-a-binding-wins-over-the-roster "exec --user grok alpha" "$(execs)"

out="$(lib_case 0.11.0 'box_entry_mark_unconverged alpha; box_in alpha -- true; echo "rc=$?"; box_entry_mark_converged alpha; box_in alpha -- true')"
t lib-unconverged-refuses 1 "$(grep -cx 'rc=2' <<<"$out")"
t lib-unconverged-says-not-converged-yet 1 "$(grep -c 'alpha is not converged yet' <<<"$out")"
t lib-unconverged-then-converged-enters-once "exec --user claude alpha" "$(execs)"

# Sourcing the library again (platform.sh, version-skew.sh and box-mint.sh
# each do) must keep the reading, the bindings and a mint in progress.
out="$(lib_case 0.11.0 "box_entry_bind stranger kimi; box_entry_mark_unconverged alpha; box_in beta -- true
  source '$ROOT/shared/lib/box-entry.sh'; box_in stranger -- true; box_in alpha -- true; echo \"rc=\$?\"")"
t lib-resourcing-keeps-the-state "exec --user codex beta
exec --user kimi stranger" "$(execs)"
t lib-resourcing-keeps-the-unconverged-mark 1 "$(grep -cx 'rc=2' <<<"$out")"
t lib-resourcing-does-not-reread 1 "$(version_reads)"

# box_in_argv for the wrapped callers (timeout, time).
out="$(lib_case 0.11.0 'box_in_argv beta -- bash -lc "x y"; printf "%s|" "${BOX_IN_ARGV[@]}"')"
t lib-argv-for-wrappers "box|exec|--user|codex|beta|--|bash|-lc|x y|" "$out"

# Hints.
t lib-hint-user "box shell --user codex beta" "$(lib_case 0.11.0 'box_shell_hint beta')"
t lib-hint-user-explicit-agent "box shell --user kimi beta" "$(lib_case 0.11.0 'box_shell_hint beta kimi')"
t lib-hint-user-off-roster "box shell --user <agent> stranger" "$(lib_case 0.11.0 'box_shell_hint stranger')"
t lib-hint-stamp "box shell beta" "$(lib_case 0.10.1 'box_shell_hint beta')"
t lib-hint-unreadable-is-the-safe-form "box shell --user codex beta" "$(lib_case "" 'box_shell_hint beta')"
t lib-exec-hint-user "box exec --user claude alpha -- rm -f x" "$(lib_case 0.11.0 'box_exec_hint alpha -- rm -f x')"
t lib-exec-hint-stamp "box exec alpha -- rm -f x" "$(lib_case 0.10.1 'box_exec_hint alpha -- rm -f x')"

# --- 3. the mint ------------------------------------------------------------
mint_case() { # VERSION [ROOT_RC]
  reset_state
  BE_BOX_VERSION="$1" BE_ROOT_RC="${2:-0}" PATH="$SHIM:$PATH" CREW_ROSTER="$CONF/fleet.roster" \
    bash -c "source '$ROOT/shared/lib/box-mint.sh'
      box_mint_fresh gamma claude 4 8GiB 60GiB; echo \"mint=\$?\"
      box_in gamma -- true; echo \"in=\$?\"" 2>&1 </dev/null
}
out="$(mint_case 0.10.1)"
t mint-stamp-keeps-user "new --name gamma --user claude --cpu 4 --memory 8GiB --disk 60GiB" "$(grep '^new ' "$STATE/calls")"
t mint-stamp-converges-through-root 1 "$(grep -cx 'root gamma' "$STATE/calls")"
t mint-stamp-enters-as-today "exec gamma" "$(execs)"

out="$(mint_case 0.11.0)"
t mint-user-names-no-user "new --name gamma --cpu 4 --memory 8GiB --disk 60GiB" "$(grep '^new ' "$STATE/calls")"
t mint-user-converges-through-root 1 "$(grep -cx 'root gamma' "$STATE/calls")"
t mint-user-ok 1 "$(grep -cx 'mint=0' <<<"$out")"
t mint-user-converged-box-is-entered-as-its-agent "exec --user claude gamma" "$(execs)"

out="$(mint_case 0.11.0 1)"
t mint-user-converge-failure-fails-the-mint 1 "$(grep -cx 'mint=1' <<<"$out")"
t mint-user-before-convergence-refuses 1 "$(grep -cx 'in=2' <<<"$out")"
t mint-user-before-convergence-says-so 1 "$(grep -c 'gamma is not converged yet' <<<"$out")"
t mint-user-before-convergence-enters-nothing "" "$(execs)"

out="$(mint_case "")"
t mint-unreadable-refuses 1 "$(grep -cx 'mint=2' <<<"$out")"
t mint-unreadable-creates-nothing 0 "$(grep -c '^new ' "$STATE/calls")"

# --- 4. the CLI, verb by verb, in both modes --------------------------------
run_crew() { # VERSION ARGS... — stdin is the caller's
  local version="$1"; shift
  BE_BOX_VERSION="$version" CREW_CONFIG_DIR="$CONF" CREW_HOST_STATE_DIR="$TMP/host-state" \
    CREW_FLOOR_STORE="$TMP/store.sqlite" PATH="$SHIM:$PATH" bash "$CLI" "$@"
}

# check_execs MODE NAME — every recorded exec is the right shape for MODE,
# and there was at least one.
check_execs() { # MODE NAME
  local mode="$1" name="$2" lines bad
  lines="$(execs)"
  t "cli-$name-$mode-reached-a-box" yes "$([ -n "$lines" ] && echo yes || echo "no (nothing exec'd)")"
  if [ "$mode" = user ]; then
    bad="$(grep -vxE 'exec --user (claude alpha|codex beta|claude gamma)' <<<"$lines" || true)"
  else
    bad="$(grep -vxE 'exec (alpha|beta|gamma)' <<<"$lines" || true)"
  fi
  t "cli-$name-$mode-every-exec-is-$mode-shaped" "" "$bad"
}

verb_case() { # NAME ARGS... (stdin /dev/null)
  local name="$1" mode version; shift
  for mode in stamp user; do
    case "$mode" in stamp) version=0.10.1 ;; user) version=0.11.0 ;; esac
    reset_state
    run_crew "$version" "$@" </dev/null >"$TMP/out-$name-$mode" 2>&1
    check_execs "$mode" "$name"
  done
}

verb_case status status
verb_case restart restart alpha
verb_case reset-cut reset --cut alpha
verb_case reset-restore reset alpha
verb_case drain drain alpha
verb_case pause pause alpha
verb_case resume resume beta
verb_case hire hire alpha --force
verb_case upgrade upgrade alpha
verb_case tick tick

# login takes its secret on stdin.
for mode in stamp user; do
  case "$mode" in stamp) version=0.10.1 ;; user) version=0.11.0 ;; esac
  reset_state
  printf 'ghp_fixture\n' | run_crew "$version" login beta gh >"$TMP/out-login-$mode" 2>&1
  check_execs "$mode" login
done

# The version is read ONCE per crew process, however many boxes it enters.
reset_state
run_crew 0.11.0 status </dev/null >/dev/null 2>&1
t cli-status-reads-the-version-once 1 "$(version_reads)"
t cli-status-enters-more-than-once yes "$([ "$(execs | wc -l)" -gt 1 ] && echo yes || echo no)"

# Unreadable: crew refuses with 2 and enters nothing.
reset_state
out="$(run_crew "" status </dev/null 2>&1)"; rc=$?
t cli-unreadable-status-exits-2 2 "$rc"
t cli-unreadable-names-box-version 1 "$(grep -c "'box --version'" <<<"$out")"
t cli-unreadable-enters-nothing "" "$(execs)"
reset_state
out="$(run_crew "" new gamma </dev/null 2>&1)"; rc=$?
t cli-unreadable-new-exits-2 2 "$rc"
t cli-unreadable-new-creates-nothing 0 "$(grep -c '^new ' "$STATE/calls")"

# The mint through the CLI.
reset_state
run_crew 0.11.0 new gamma </dev/null >"$TMP/out-new-user" 2>&1
t cli-new-user-names-no-user "new --name gamma --cpu 2 --memory 4GiB --disk 40GiB" \
  "$(grep '^new ' "$STATE/calls" | sed -E 's/--cpu [0-9]+ --memory [0-9A-Za-z]+ --disk [0-9A-Za-z]+/--cpu 2 --memory 4GiB --disk 40GiB/')"
t cli-new-user-hint-names-the-agent 1 "$(grep -c 'box shell --user claude gamma' "$TMP/out-new-user")"
reset_state
run_crew 0.10.1 new gamma </dev/null >"$TMP/out-new-stamp" 2>&1
t cli-new-stamp-keeps-user 1 "$(grep -c '^new --name gamma --user claude ' "$STATE/calls")"
t cli-new-stamp-hint-is-today-s 1 "$(grep -c 'box shell gamma,' "$TMP/out-new-stamp")"

# An ad-hoc hire names its agent with --agent; the door uses it.
reset_state
run_crew 0.11.0 hire stranger --agent kimi --role builder </dev/null >"$TMP/out-adhoc" 2>&1
# (The hire's foreign-actor check also reads the roster boxes' identities, each
# as its own agent.)
t cli-adhoc-hire-reached-the-box yes "$(grep -qx 'exec --user kimi stranger' <<<"$(execs)" && echo yes || echo no)"
t cli-adhoc-hire-enters-as-the-given-agent "" \
  "$(execs | grep -vxE 'exec --user (kimi stranger|claude alpha|codex beta)' || true)"

# The CLI spells no `box exec` of its own: every site is the door.
cli_code="$(grep -vE '^[[:space:]]*#' "$CLI" | sed -e :a -e '/\\$/N; s/\\\n//; ta')"
t cli-spells-no-box-exec 0 "$(grep -cE '(^|[;&|({[:space:]])box exec ' <<<"$cli_code" | tr -d ' ' || true)"

# Nor does any host-side library or drill script, outside the door itself.
# (Guest-side modules run INSIDE a box and never call `box`.)
# Any spelling: quoted or not, through a variable holding the transport, or
# armed-self's own transport function.
host_sources=("$ROOT/shared/lib/platform.sh" "$ROOT/shared/lib/version-skew.sh" \
  "$ROOT/shared/lib/box-mint.sh" "$ROOT/shared/lib/host/"*.sh "$ROOT"/drill/*.sh "$ROOT/install.sh" \
  "$ROOT"/shared/bin/* "$ROOT"/dist/*.sh)
stray=""
for f in "${host_sources[@]}"; do
  code="$(grep -vE '^[[:space:]]*#' "$f")"
  if grep -qE '(^|[^[:alnum:]_-])box[[:space:]]+exec([[:space:]]|$)|"\$\{?[A-Za-z_]*BOX[A-Za-z_]*\}?" exec |armed_self_box exec' <<<"$code"; then
    stray="$stray ${f#"$ROOT"/}"
  fi
done
t host-sources-spell-no-box-exec "" "$stray"

# --- 5. the floor's door ----------------------------------------------------
floor_py() { # VERSION SCRIPT
  reset_state
  BE_BOX_VERSION="$1" PATH="$SHIM:$PATH" CREW_CONFIG_DIR="$CONF" CREW_FLOOR_ROSTER="$CONF/fleet.roster" \
    PYTHONPATH="$ROOT/fleet-floor/server" python3 -c "$2" 2>&1 </dev/null
}
FLOOR_DRIVE='
import floor
from floor.fleet import Fleet
from floor.actions import do_command
f = Fleet(60)
f.ping_once()
snap = f.poll_once()
for u in snap["units"]:
    print("unit-shell %s=%s" % (u.get("box"), u.get("shell")))
do_command(f, {"action": "pause", "box": "alpha"})
do_command(f, {"action": "resume", "box": "beta"})
from floor.ping import box_shell_command
print("shell=" + box_shell_command("beta", "codex"))
'
for mode in stamp user; do
  case "$mode" in stamp) version=0.10.1 ;; user) version=0.11.0 ;; esac
  out="$(floor_py "$version" "$FLOOR_DRIVE")"
  t "floor-ping-and-actions-$mode-pinged-both" 2 "$(grep -cE '^exec (--user [a-z]+ )?(alpha|beta)$' <<<"$(execs | sort -u)")"
  check_execs "$mode" floor
  case "$mode" in
    stamp) t floor-shell-command-stamp "shell=box shell beta" "$(grep '^shell=' <<<"$out")"
           t floor-snapshot-carries-the-shell-stamp "unit-shell alpha=box shell alpha
unit-shell beta=box shell beta
unit-shell gamma=box shell gamma" "$(grep '^unit-shell ' <<<"$out" | sort)" ;;
    user)  t floor-shell-command-user "shell=box shell --user codex beta" "$(grep '^shell=' <<<"$out")"
           t floor-snapshot-carries-the-shell-user "unit-shell alpha=box shell --user claude alpha
unit-shell beta=box shell --user codex beta
unit-shell gamma=box shell --user claude gamma" "$(grep '^unit-shell ' <<<"$out" | sort)" ;;
  esac
done
out="$(floor_py 0.11.0 '
from floor.ping import ping_box, box_in, BoxEntryRefused
ok, ms, err, facts = ping_box("alpha", "")
print("ok=%s err=%s" % (ok, err))
try:
    box_in("alpha", "", ["true"]); print("argv")
except BoxEntryRefused as e:
    print("refused")
')"
t floor-user-no-agent-ping-fails 1 "$(grep -c '^ok=False err=alpha has no roster row naming its agent' <<<"$out")"
t floor-user-no-agent-refuses 1 "$(grep -cx 'refused' <<<"$out")"
t floor-user-no-agent-enters-nothing "" "$(execs)"
out="$(floor_py "" '
from floor.ping import box_entry_mode, BoxEntryRefused
try:
    box_entry_mode(); print("mode")
except BoxEntryRefused as e:
    print("refused: %s" % e)
')"
t floor-unreadable-refuses 1 "$(grep -c "^refused: cannot read this host's box version" <<<"$out")"
out="$(floor_py 0.11.0 '
from floor import ping
ping.box_entry_mode(); ping.box_entry_mode(); ping.box_in("alpha", "claude", ["true"])
print("argv=" + " ".join(ping.box_in("beta", "codex", ["true"])))
')"
t floor-reads-the-version-once 1 "$(version_reads)"
t floor-user-argv "argv=box exec --user codex beta -- true" "$(grep '^argv=' <<<"$out")"

# The floor's Python spells `box exec` only inside the door.
floor_stray="$(grep -rnE '"box", *"exec"' "$ROOT/fleet-floor/server" --include='*.py' | grep -v 'floor/ping.py' || true)"
t floor-spells-no-box-exec-outside-the-door "" "$floor_stray"
# …and the page copies the collector's line instead of spelling one.
t floor-page-copies-the-collector-s-shell 1 "$(grep -c 'var c=d.shell||' "$ROOT/fleet-floor/src/app.js")"

suite_finish
